--[[
    SBLoveFramework -- playback
    ------------------------------------------------------------------
    Plays an arbitrary AnimSequence on a Stellar Blade character.

    THE MECHANISM (established by probes P1-P8, see docs/09-playback-solved.md)

    Stellar Blade's characters cannot be animated through any normal route:

      - UE montages       Eve's anim graph contains no AnimNode_Slot at all, so
                          a montage is created and then silently discarded.
      - CustomAnim nodes  present and injectable, but gated by an alpha the
                          event graph rewrites every frame from native C++ that
                          has no UProperty. Unwinnable without a hook.
      - PlayAnimation     works, and crashes the game, because single-node mode
                          disables the anim blueprint that physics, cloth, IK
                          and facial all depend on.
      - ActorPlayCustom*  not on ASBCharacter.

    What DOES work is swapping the sequence pointer on a node the graph is
    already playing:

        node.Sequence = myAnim

    Measured: hand-bone travel 2.1 units idle -> 171623 units swapped.

    FINDING THE NODE

    Which node is live depends on the character's state, so it is found, never
    hardcoded. FAnimNode_AssetPlayerBase gives the detector:

        BlendWeight              > 0    the graph is using this node
        InternalTimeAccumulator  moving the node is genuinely running

    Both are required. In testing, two nodes had full weight but only one had an
    advancing accumulator; the frozen one would have been the wrong choice.

    ASSET LIFETIME

    LoadAsset returns an object that UE garbage collects within seconds because
    nothing references it. The fix is structural rather than a cache: load the
    asset and assign it to a node in the same breath, at which point the anim
    instance holds the reference and it stays alive. Never load ahead of time.

    RESTORE

    Every swap records the original pointer and puts it back. A character left
    with a foreign sequence on an idle node stays broken until level reload.
--]]

local Playback = {}

--- Every asset-player node on CH_P_EVE_01_AnimBP_New_C. Derived offline from
--- research/CXXHeaderDump/CH_P_EVE_01_AnimBP_New.hpp by selecting properties
--- whose type descends from FAnimNode_AssetPlayerBase. Other characters have
--- different graphs; DiscoverNodes below falls back to probing these names and
--- keeping whatever resolves.
Playback.NODES = {
    "AnimGraphNode_SequencePlayer_33",
    "AnimGraphNode_RandomPlayer",
    "AnimGraphNode_SequencePlayer_32",
    "AnimGraphNode_SequencePlayer_31",
    "AnimGraphNode_SequencePlayer_30",
    "AnimGraphNode_SequencePlayer_29",
    "SBAnimGraphNode_SequenceBlendedPlayer_8",
    "SBAnimGraphNode_BlendSpacePlayer_16",
    "AnimGraphNode_SequencePlayer_28",
    "SBAnimGraphNode_BlendSpacePlayer_15",
    "SBAnimGraphNode_BlendSpacePlayer_14",
    "SBAnimGraphNode_SequenceBlendedPlayer_7",
    "AnimGraphNode_SequencePlayer_27",
    "AnimGraphNode_SequencePlayer_26",
    "SBAnimGraphNode_SequenceBlendedPlayer_6",
    "SBAnimGraphNode_CustomBlendSpacePlayer",
    "AnimGraphNode_SequencePlayer_25",
    "AnimGraphNode_SequencePlayer_24",
    "AnimGraphNode_SequencePlayer_23",
    "AnimGraphNode_SequencePlayer_22",
    "SBAnimGraphNode_SequenceBlendedPlayer_5",
    "SBAnimGraphNode_SequenceBlendedPlayer_4",
    "SBAnimGraphNode_SequenceBlendedPlayer_3",
    "SBAnimGraphNode_BlendSpacePlayer_13",
    "AnimGraphNode_SequencePlayer_21",
    "AnimGraphNode_SequencePlayer_20",
    "AnimGraphNode_SequencePlayer_19",
    "AnimGraphNode_SequencePlayer_18",
    "SBAnimGraphNode_BlendSpacePlayer_12",
    "AnimGraphNode_SequencePlayer_17",
    "AnimGraphNode_SequencePlayer_16",
    "SBAnimGraphNode_BlendSpacePlayer_11",
    "AnimGraphNode_SequencePlayer_15",
    "AnimGraphNode_SequencePlayer_14",
    "AnimGraphNode_SequencePlayer_13",
    "AnimGraphNode_SequencePlayer_12",
    "AnimGraphNode_SequencePlayer_11",
    "AnimGraphNode_SequencePlayer_10",
    "AnimGraphNode_SequencePlayer_9",
    "AnimGraphNode_SequencePlayer_8",
    "SBAnimGraphNode_BlendSpacePlayer_10",
    "SBAnimGraphNode_BlendSpacePlayer_9",
    "AnimGraphNode_BlendSpacePlayer_15",
    "AnimGraphNode_BlendSpacePlayer_14",
    "AnimGraphNode_BlendSpacePlayer_13",
    "AnimGraphNode_SequencePlayer_7",
    "AnimGraphNode_SequencePlayer_6",
    "AnimGraphNode_BlendSpacePlayer_12",
    "AnimGraphNode_BlendSpacePlayer_11",
    "AnimGraphNode_BlendSpacePlayer_10",
    "AnimGraphNode_SequencePlayer_5",
    "AnimGraphNode_SequencePlayer_4",
    "AnimGraphNode_BlendSpacePlayer_9",
    "AnimGraphNode_BlendSpacePlayer_8",
    "AnimGraphNode_BlendSpacePlayer_7",
    "AnimGraphNode_BlendSpacePlayer_6",
    "AnimGraphNode_BlendSpacePlayer_5",
    "SBAnimGraphNode_BlendSpacePlayer_8",
    "SBAnimGraphNode_BlendSpacePlayer_7",
    "SBAnimGraphNode_BlendSpacePlayer_6",
    "AnimGraphNode_SequencePlayer_3",
    "AnimGraphNode_SequencePlayer_2",
    "SBAnimGraphNode_SBSequencePlayer_1",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_4",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_3",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_2",
    "SBAnimGraphNode_BlendSpacePlayer_5",
    "SBAnimGraphNode_BlendSpacePlayer_4",
    "SBAnimGraphNode_BlendSpacePlayer_3",
    "AnimGraphNode_SequencePlayer_1",
    "SBAnimGraphNode_SBSequencePlayer",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_1",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer",
    "AnimGraphNode_BlendSpacePlayer_4",
    "SBAnimGraphNode_BlendSpacePlayer_2",
    "SBAnimGraphNode_BlendSpacePlayer_1",
    "AnimGraphNode_BlendSpacePlayer_3",
    "AnimGraphNode_BlendSpacePlayer_2",
    "AnimGraphNode_BlendSpacePlayer_1",
    "AnimGraphNode_BlendSpacePlayer",
    "SBAnimGraphNode_SBMotionPlayer",
    "SBAnimGraphNode_BlendSpacePlayer",
    "AnimGraphNode_SequencePlayer",
    "SBAnimGraphNode_SequenceBlendedPlayer_2",
    "SBAnimGraphNode_SequenceBlendedPlayer_1",
    "SBAnimGraphNode_SequenceBlendedPlayer",}

-- ------------------------------------------------------------------ helpers

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function IsLive(object)
    if not object then return false end
    return Try(function() return object:IsValid() end) == true
end

local function FullName(object)
    return Try(function() return object:GetFullName() end) or "<unnamed>"
end

Playback.Try, Playback.IsLive, Playback.FullName = Try, IsLive, FullName

-- ------------------------------------------------------------------- actors

--- ESBMesh_Body. Face is 1, see ESBSkelMeshSlot in SB_enums.hpp.
local MESH_BODY = 0

function Playback.GetMesh(actor, slot)
    if not IsLive(actor) then return nil end
    local mesh = Try(function()
        return actor:GetSBSkeletalMeshComponent(slot or MESH_BODY) end)
    return IsLive(mesh) and mesh or nil
end

function Playback.GetAnimInstance(actor, slot)
    local mesh = Playback.GetMesh(actor, slot)
    if not mesh then return nil end
    local instance = Try(function() return mesh:GetAnimInstance() end)
    return IsLive(instance) and instance or nil
end

-- -------------------------------------------------------------- node access

--- Node property names that actually resolve on this anim instance. Cached per
--- instance, because the scan is the expensive part and the answer is stable
--- for as long as the instance lives.
local discovered = setmetatable({}, { __mode = "k" })

function Playback.DiscoverNodes(instance)
    if not IsLive(instance) then return {} end
    local cached = discovered[instance]
    if cached then return cached end

    local present = {}
    for _, prop in ipairs(Playback.NODES) do
        if Try(function() return instance[prop] end) ~= nil then
            present[#present + 1] = prop
        end
    end
    discovered[instance] = present
    return present
end

--- One reading of every node's play state.
function Playback.Sample(instance)
    local snapshot = {}
    for _, prop in ipairs(Playback.DiscoverNodes(instance)) do
        local node = Try(function() return instance[prop] end)
        if node ~= nil then
            snapshot[prop] = {
                weight   = Try(function() return node.BlendWeight end) or 0.0,
                time     = Try(function() return node.InternalTimeAccumulator end),
                sequence = Try(function() return node.Sequence end),
            }
        end
    end
    return snapshot
end

--- EAdditiveAnimationType. AAT_None means an absolute, full-body pose.
--- Anything else is a delta layered on top of a base pose.
Playback.ADDITIVE_NONE = 0

--- Additive-ness of an AnimSequence, or nil if unreadable.
---
--- This matters more than anything else about node choice. The first successful
--- swap in development put a full-body jog into CH_P_EVE_09_AccIdle, which
--- lives under /Animation/Additive/. Absolute bone transforms got added on top
--- of the base pose and the character deformed violently: the measured hand
--- travel was 171623 units where idle was 2.1. The skeleton moved, so it read
--- as success, and it was garbage.
---
--- The rule is that additive-ness of the replacement must match the node.
function Playback.AdditiveTypeOf(sequence)
    if not IsLive(sequence) then return nil end
    return Try(function() return sequence.AdditiveAnimType end)
end

function Playback.IsAbsolute(sequence)
    return Playback.AdditiveTypeOf(sequence) == Playback.ADDITIVE_NONE
end

--- Nodes that are genuinely driving the skeleton, best first.
---
--- Needs two samples taken at least a frame apart. Weight alone is not enough:
--- a node can hold full weight while frozen, and swapping into one of those
--- changes nothing. The advancing accumulator is what separates them.
---
--- Only nodes that already carry a sequence are returned, since the swap is a
--- pointer overwrite and a node with no sequence is not playing one. Note that
--- Eve's base pose while idle comes from BlendSpace nodes, which take
--- BlendSpace assets rather than sequences, so they are deliberately not
--- candidates here.
---
--- opts.absoluteOnly restricts the result to nodes currently playing a
--- non-additive sequence, which is what a full-body scene animation needs.
function Playback.FindLive(before, after, opts)
    opts = opts or {}
    local minWeight = opts.minWeight or 0.001
    local live = {}

    for prop, b in pairs(after) do
        local a = before[prop]
        if a then
            local moving = type(b.time) == "number" and type(a.time) == "number"
                and math.abs(b.time - a.time) > 0.0001
            if b.weight > minWeight and moving and IsLive(b.sequence) then
                local additive = Playback.AdditiveTypeOf(b.sequence)
                if not opts.absoluteOnly or additive == Playback.ADDITIVE_NONE then
                    live[#live + 1] = {
                        property = prop,
                        weight   = b.weight,
                        delta    = b.time - a.time,
                        sequence = b.sequence,
                        additive = additive,
                        name     = FullName(b.sequence):match("([^%.]+)$"),
                    }
                end
            end
        end
    end

    table.sort(live, function(x, y) return x.weight > y.weight end)
    return live
end

-- ---------------------------------------------------------------- swapping

--- Active swaps, so every one can be undone even if a scene ends abruptly.
--- { [instance] = { [property] = originalSequence } }
local swaps = setmetatable({}, { __mode = "k" })

--- Load and assign in one step.
---
--- Splitting these is the bug that cost two probes: LoadAsset hands back a
--- working object with nothing referencing it, and UE collects it within a few
--- seconds. Assigning it to a node immediately makes the anim instance the
--- owner, which is what keeps it alive. So there is deliberately no preload
--- and no asset cache here.
function Playback.Swap(instance, property, animPath, opts)
    if not IsLive(instance) then return false, "anim instance is gone" end

    local node = Try(function() return instance[property] end)
    if node == nil then return false, "no such node: " .. tostring(property) end

    local anim = Try(StaticFindObject, animPath)
    if not IsLive(anim) and type(LoadAsset) == "function" then
        anim = Try(LoadAsset, animPath)
    end
    if not IsLive(anim) then return false, "could not load " .. tostring(animPath) end

    local original = Try(function() return node.Sequence end)

    -- Refuse a mismatch rather than produce a deformed character. Putting an
    -- absolute animation into an additive node adds absolute bone transforms
    -- onto the base pose, which looks like violent deformation, and putting an
    -- additive one into an absolute node collapses the pose. Callers that
    -- genuinely want to override this can pass opts.force.
    if not (opts and opts.force) and IsLive(original) then
        local want = Playback.AdditiveTypeOf(original)
        local got  = Playback.AdditiveTypeOf(anim)
        if want ~= nil and got ~= nil and want ~= got then
            return false, string.format(
                "additive mismatch: node plays type %s, animation is type %s",
                tostring(want), tostring(got))
        end
    end

    Try(function() node.Sequence = anim end)

    -- Verify by reading back. A write that does not throw proves nothing; that
    -- assumption produced three rounds of false progress during development.
    local after = Try(function() return node.Sequence end)
    if not IsLive(after) or FullName(after) ~= FullName(anim) then
        return false, "write did not take"
    end

    -- Record only the FIRST original for a property, so repeated swaps during a
    -- scene still restore to the true starting sequence rather than to the
    -- previous swap.
    swaps[instance] = swaps[instance] or {}
    if swaps[instance][property] == nil then
        swaps[instance][property] = original or false
    end

    return true
end

--- Swap into the highest-weight live node. The common case.
function Playback.PlayOnLive(instance, live, animPath, opts)
    if not live or #live == 0 then return false, "no live node" end
    return Playback.Swap(instance, live[1].property, animPath, opts)
end

function Playback.Restore(instance)
    local record = swaps[instance]
    if not record then return 0 end

    local restored = 0
    for property, original in pairs(record) do
        if original ~= false and IsLive(original) then
            local node = Try(function() return instance[property] end)
            if node ~= nil then
                Try(function() node.Sequence = original end)
                restored = restored + 1
            end
        end
    end
    swaps[instance] = nil
    return restored
end

function Playback.RestoreAll()
    local total = 0
    for instance in pairs(swaps) do
        if IsLive(instance) then total = total + Playback.Restore(instance) end
    end
    return total
end

function Playback.HasSwaps(instance)
    local record = swaps[instance]
    if not record then return false end
    return next(record) ~= nil
end

-- ------------------------------------------------------------- blend spaces

--[[
    WHY THIS EXISTS

    Sequence swapping cannot drive Eve's body while she is simply standing.
    Scanning every gameplay state showed her base pose comes from BlendSpace
    nodes, and the only live *sequence* nodes at idle are the accessory layer:

        AnimGraphNode_SequencePlayer_25  Eve_Acc_idle_Anim    absolute, w=1.00
        AnimGraphNode_SequencePlayer_26  CH_P_EVE_09_AccIdle  additive, w=1.00

    Eve_Acc_idle_Anim lives in /CH_P_EVE_01/Acc/, a folder with four assets, all
    accessory and Beta-skill animations. It is not the body.

    A BlendSpace is a set of samples blended by input parameters (speed,
    direction). Each sample is an FBlendSample holding a UAnimSequence pointer.
    So if EVERY sample is replaced with the same animation, the blend result is
    that animation no matter where the blend parameters sit, and the character
    plays it while standing, walking or anything else.

    DANGER

    A BlendSpace is a shared asset, not per-instance state. Editing one edits it
    for every user of it, for the rest of the session, and it does not reset on
    its own. Restore is not optional here, so originals are recorded per sample
    index and put back exactly.
--]]

--- { [blendSpace] = { [index] = originalAnimation } }
local bsSwaps = setmetatable({}, { __mode = "k" })

function Playback.GetBlendSpace(node)
    if node == nil then return nil end
    local space = Try(function() return node.BlendSpace end)
    return IsLive(space) and space or nil
end

--- Live BlendSpace nodes, best first. Unlike sequence nodes these have no
--- InternalTimeAccumulator worth trusting, so weight is the signal.
function Playback.FindLiveBlendSpaces(instance, minWeight)
    minWeight = minWeight or 0.001
    local found = {}
    for _, prop in ipairs(Playback.DiscoverNodes(instance)) do
        local node = Try(function() return instance[prop] end)
        local space = Playback.GetBlendSpace(node)
        if space then
            local weight = Try(function() return node.BlendWeight end) or 0.0
            if weight > minWeight then
                found[#found + 1] = {
                    property   = prop,
                    weight     = weight,
                    blendSpace = space,
                    name       = FullName(space):match("([^%.]+)$"),
                }
            end
        end
    end
    table.sort(found, function(x, y) return x.weight > y.weight end)
    return found
end

function Playback.DescribeBlendSpace(space)
    local samples = Try(function() return space.SampleData end)
    local count = Try(function() return samples:GetArrayNum() end)
    if type(count) ~= "number" then count = Try(function() return #samples end) end
    local names = {}
    if type(count) == "number" then
        for i = 1, count do
            local sample = Try(function() return samples[i] end)
            local anim = sample and Try(function() return sample.Animation end)
            names[#names + 1] = IsLive(anim)
                and (FullName(anim):match("([^%.]+)$")) or "-"
        end
    end
    return count, names
end

--- Point every sample of a BlendSpace at one animation.
function Playback.SwapBlendSpace(space, animPath)
    if not IsLive(space) then return false, "blend space is gone" end

    local anim = Try(StaticFindObject, animPath)
    if not IsLive(anim) and type(LoadAsset) == "function" then
        anim = Try(LoadAsset, animPath)
    end
    if not IsLive(anim) then return false, "could not load " .. tostring(animPath) end

    local samples = Try(function() return space.SampleData end)
    if samples == nil then return false, "no SampleData" end

    local count = Try(function() return samples:GetArrayNum() end)
    if type(count) ~= "number" then count = Try(function() return #samples end) end
    if type(count) ~= "number" or count < 1 then return false, "no samples" end

    bsSwaps[space] = bsSwaps[space] or {}
    local record = bsSwaps[space]
    local written = 0

    for i = 1, count do
        local sample = Try(function() return samples[i] end)
        if sample ~= nil then
            if record[i] == nil then
                local original = Try(function() return sample.Animation end)
                record[i] = IsLive(original) and original or false
            end
            Try(function() sample.Animation = anim end)
            local after = Try(function() return sample.Animation end)
            if IsLive(after) and FullName(after) == FullName(anim) then
                written = written + 1
            end
        end
    end

    if written == 0 then return false, "no sample write took" end
    return true, written, count
end

function Playback.RestoreBlendSpace(space)
    local record = bsSwaps[space]
    if not record or not IsLive(space) then return 0 end

    local samples = Try(function() return space.SampleData end)
    local restored = 0
    if samples ~= nil then
        for index, original in pairs(record) do
            if original ~= false and IsLive(original) then
                local sample = Try(function() return samples[index] end)
                if sample ~= nil then
                    Try(function() sample.Animation = original end)
                    restored = restored + 1
                end
            end
        end
    end
    bsSwaps[space] = nil
    return restored
end

function Playback.RestoreAllBlendSpaces()
    local total = 0
    for space in pairs(bsSwaps) do
        total = total + Playback.RestoreBlendSpace(space)
    end
    return total
end

--- Undo everything this module has changed. Call on scene end, on level change,
--- and on mod shutdown.
function Playback.RestoreEverything()
    return Playback.RestoreAll(), Playback.RestoreAllBlendSpaces()
end

return Playback
