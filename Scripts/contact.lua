--[[
    SBLoveFramework -- contact
    ------------------------------------------------------------------
    Collision volumes that displace soft chains, so contact reads as contact
    rather than as two things intersecting.

    THE PROBLEM

    Parameter tuning alone cannot express contact. If one chain is being held
    and its opposite number is hanging free, no single set of numbers describes
    both, and without a collider the contacting geometry simply passes through.

    There are two levels of answer and this module does both.

    1. ASYMMETRIC PARAMETERS  (physics.lua, ApplyToChains)
       Raise stiffness and damping on the constrained side so it moves less,
       leave the free side alone. Cheap, no per-frame cost, and it captures most
       of the read. Use when there is no specific contact point.

    2. DRIVEN COLLIDERS  (this module)
       An actual volume the soft chain cannot enter, which pushes it aside as it
       moves. This is what makes contact look like pressure rather than
       proximity.

    HOW KAWAII PHYSICS EXPRESSES A COLLIDER

        struct FCollisionLimitBase
            FBoneReference DrivingBone         collider follows this bone
            FName          MasterMeshBoneName
            FVector        OffsetLocation      offset from that bone
            FRotator       OffsetRotation
            FVector        Location            or place it directly
            FQuat          Rotation
            bool           bEnable

        struct FSphericalLimit : FCollisionLimitBase   float Radius
        struct FCapsuleLimit   : FCollisionLimitBase   float Radius, Length

    They live in TArrays on the KawaiiPhysics node: SphericalLimits,
    CapsuleLimits, PlanarLimits. TArray growth by index assignment is proven
    (see docs/09-playback-solved.md); `Add` throws, index assignment works.

    SAME ACTOR versus CROSS ACTOR

    DrivingBone is a bone on the SAME skeleton, so it only helps when the
    contact comes from the character's own body. That case is free: bind and
    forget, the engine follows the bone.

    For contact from a PARTNER, no bone reference can span two skeletons. So
    Location is written directly each tick from the partner's bone world
    position. That costs a handful of float writes per tick, which is nothing,
    and it is not a hook.

    RESTORE

    Colliders added here are disabled and their array entries reverted on
    release. The KawaiiPhysics node is live state on a live anim instance, so
    anything left behind persists until the level reloads.
--]]

local Physics = require("physics")

local Contact = {}

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

local function ArrayCount(array)
    if array == nil then return nil end
    local n = Try(function() return array:GetArrayNum() end)
    if type(n) == "number" then return n end
    n = Try(function() return #array end)
    if type(n) == "number" then return n end
    return nil
end

-- ------------------------------------------------------------------- state

--- Colliders this module created or enabled, per anim instance, so they can all
--- be switched off again.
--- { [instance] = { { kind = "capsule", index = n, wasEnabled = bool } } }
local owned = setmetatable({}, { __mode = "k" })

--- Colliders whose Location is driven each tick from another actor's bone.
--- { { instance, kind, index, sourceMesh, sourceBone, offset } }
local driven = {}

local function KawaiiNode(instance)
    if not IsLive(instance) then return nil end
    return Try(function() return instance[Physics.KAWAII_NODE] end)
end

local function LimitArray(node, kind)
    if node == nil then return nil end
    if kind == "capsule" then
        return Try(function() return node.CapsuleLimits end)
    end
    return Try(function() return node.SphericalLimits end)
end

-- -------------------------------------------------------------------- query

--- What collision volumes already exist. Stellar Blade ships some, and reusing
--- one is preferable to growing the array.
function Contact.Describe(instance)
    local node = KawaiiNode(instance)
    if node == nil then return "no KawaiiPhysics node" end

    local lines = {}
    for _, kind in ipairs({ "spherical", "capsule" }) do
        local array = LimitArray(node, kind)
        local count = ArrayCount(array)
        lines[#lines + 1] = string.format("  %-10s limits: %s",
            kind, tostring(count))

        if type(count) == "number" then
            for i = 1, count do
                local limit = Try(function() return array[i] end)
                if limit ~= nil then
                    local bone = Try(function()
                        return limit.DrivingBone.BoneName:ToString() end)
                    lines[#lines + 1] = string.format(
                        "    [%d] bone=%-20s radius=%s enabled=%s", i,
                        tostring(bone or "-"),
                        tostring(Try(function() return limit.Radius end)),
                        tostring(Try(function() return limit.bEnable end)))
                end
            end
        end
    end
    return table.concat(lines, "\n")
end

-- ------------------------------------------------------- same-actor binding

--- Bind a collider to a bone on the character's own skeleton.
---
--- The engine then moves it for free, every frame, with no per-tick cost here.
--- This is the right tool whenever the contact comes from the character's own
--- body rather than a partner's.
---
--- `index` selects which existing limit to take over. Growing the array is
--- possible but reusing a slot is safer, because a resized TArray on a live
--- anim node is a much bigger change than an edited entry.
function Contact.BindToBone(instance, kind, index, boneName, radius, offset)
    local node = KawaiiNode(instance)
    if node == nil then return false, "no KawaiiPhysics node" end

    local array = LimitArray(node, kind)
    local count = ArrayCount(array)
    if type(count) ~= "number" or index < 1 or index > count then
        return false, string.format("no %s limit at index %s (have %s)",
            kind, tostring(index), tostring(count))
    end

    local limit = Try(function() return array[index] end)
    if limit == nil then return false, "limit unreadable" end

    owned[instance] = owned[instance] or {}
    owned[instance][#owned[instance] + 1] = {
        kind = kind, index = index,
        wasEnabled = Try(function() return limit.bEnable end),
    }

    Try(function() limit.DrivingBone.BoneName = FName(boneName) end)
    if radius then Try(function() limit.Radius = radius end) end
    if offset then
        Try(function()
            limit.OffsetLocation = { X = offset.X or 0.0,
                                     Y = offset.Y or 0.0,
                                     Z = offset.Z or 0.0 }
        end)
    end
    Try(function() limit.bEnable = true end)

    -- Verify rather than assume. A write that does not throw proves nothing.
    local bound = Try(function() return limit.DrivingBone.BoneName:ToString() end)
    if bound ~= boneName then
        return false, "bone binding did not take (got " .. tostring(bound) .. ")"
    end
    return true
end

-- ------------------------------------------------------ cross-actor driving

--- Drive a collider from a bone on ANOTHER actor.
---
--- No bone reference can span two skeletons, so the collider's Location is
--- written each tick from the source bone's world position. Register here, then
--- call Contact.Tick() from the host loop.
function Contact.DriveFromActor(instance, kind, index, sourceActor, sourceBone, radius, offset)
    local node = KawaiiNode(instance)
    if node == nil then return false, "no KawaiiPhysics node" end

    local sourceMesh = Try(function()
        return sourceActor:GetSBSkeletalMeshComponent(0) end)
    if not IsLive(sourceMesh) then return false, "source actor has no body mesh" end

    -- Confirm the bone actually resolves before committing to driving it every
    -- tick from a name that does not exist.
    local probe = Try(function()
        return sourceMesh:GetSocketLocation(FName(sourceBone)) end)
    if probe == nil then
        return false, "source bone not found: " .. tostring(sourceBone)
    end

    local array = LimitArray(node, kind)
    local count = ArrayCount(array)
    if type(count) ~= "number" or index < 1 or index > count then
        return false, "no such limit index"
    end

    local limit = Try(function() return array[index] end)
    if limit == nil then return false, "limit unreadable" end

    owned[instance] = owned[instance] or {}
    owned[instance][#owned[instance] + 1] = {
        kind = kind, index = index,
        wasEnabled = Try(function() return limit.bEnable end),
    }

    -- Clear any bone binding, or the engine would fight the driven position.
    Try(function() limit.DrivingBone.BoneName = FName("None") end)
    if radius then Try(function() limit.Radius = radius end) end
    Try(function() limit.bEnable = true end)

    driven[#driven + 1] = {
        instance = instance, kind = kind, index = index,
        mesh = sourceMesh, bone = sourceBone, offset = offset or {},
    }
    return true
end

--- Update every driven collider. Call once per tick from the host.
---
--- Deliberately tiny: a socket read and a vector write per collider. There is
--- no hook here and no reflection scan, so the cost stays flat regardless of
--- how long a scene runs.
function Contact.Tick()
    for i = #driven, 1, -1 do
        local entry = driven[i]
        if not IsLive(entry.instance) or not IsLive(entry.mesh) then
            table.remove(driven, i)
        else
            local node = KawaiiNode(entry.instance)
            local array = node and LimitArray(node, entry.kind)
            local limit = array and Try(function() return array[entry.index] end)
            if limit ~= nil then
                local position = Try(function()
                    return entry.mesh:GetSocketLocation(FName(entry.bone)) end)
                if position ~= nil then
                    Try(function()
                        limit.Location = {
                            X = (Try(function() return position.X end) or 0.0)
                                + (entry.offset.X or 0.0),
                            Y = (Try(function() return position.Y end) or 0.0)
                                + (entry.offset.Y or 0.0),
                            Z = (Try(function() return position.Z end) or 0.0)
                                + (entry.offset.Z or 0.0),
                        }
                    end)
                end
            end
        end
    end
end

-- ------------------------------------------------------------------ release

function Contact.Release(instance)
    local record = owned[instance]
    if not record then return 0 end

    local node = KawaiiNode(instance)
    local restored = 0

    if node ~= nil then
        for _, entry in ipairs(record) do
            local array = LimitArray(node, entry.kind)
            local limit = array and Try(function() return array[entry.index] end)
            if limit ~= nil then
                Try(function() limit.bEnable = entry.wasEnabled == true end)
                restored = restored + 1
            end
        end
    end

    for i = #driven, 1, -1 do
        if driven[i].instance == instance then table.remove(driven, i) end
    end

    owned[instance] = nil
    return restored
end

function Contact.ReleaseAll()
    local total = 0
    for instance in pairs(owned) do
        total = total + Contact.Release(instance)
    end
    driven = {}
    return total
end

return Contact
