--[[
    SBLoveFramework -- win the CustomAnimAlpha race (P12)
    ------------------------------------------------------------------
    THE RACE, AND WHY IT WAS UNWINNABLE IN LUA

    Probe P8 established the loop that killed the CustomAnimNode route:

        1. the anim blueprint's event graph sets CustomAnimAlpha = 0
        2. the graph evaluates, sees 0, ignores the CustomAnim node
        3. a Lua timer writes 1.0          <- always too late
        4. repeat, every frame

    P6 had read the alpha back as 1.0 and called it success. It was only 1.0
    between the write and the next update. At evaluation it was always 0. That
    mistake is the reason this probe measures the NODE, not the value it wrote.

    Winning needs the write ordered after the event graph, which needs a hook,
    and in Lua a hook costs 1-3 fps because UE4SS switches on global
    ProcessInternal interception. So the route was abandoned.

    SBLoveNative now hooks ProcessEvent natively and re-asserts the alpha after
    the original returns. This checks whether that worked.

    WHAT IS MEASURED, AND WHY NOT THE ALPHA

    Reading CustomAnimAlpha back proves nothing: that is exactly the reading
    that fooled P6. A value of 1.0 between the graph's write and ours is
    indistinguishable from a value of 1.0 that survives evaluation.

    The node's BlendWeight is the honest signal. The graph sets it from the
    alpha at evaluation time, so:

        BlendWeight stays 0     the graph still sees 0, we are still losing
        BlendWeight rises       the graph saw our value, the race is won

    Both readings are reported, because their disagreement is the whole story
    and seeing them side by side is what makes the result legible.

    Output: ue4ss/SBLoveFramework_probe.txt, plus ue4ss/SBLove_anim.txt for
    the native side.
--]]

local Actors   = require("actors")
local Playback = require("playback")

local OutputFile  = "ue4ss/SBLoveFramework_probe.txt"
local AnimFile    = "ue4ss/SBLove_anim.txt"
local POLL_MS     = 500

--- CustomAnimAlpha's offset inside UCH_P_EVE_01_AnimBP_New_C, from
--- research/CXXHeaderDump/CH_P_EVE_01_AnimBP_New.hpp:345. Per-class, so it is
--- checked against the class name before being handed to native code: writing
--- 0x11330 into a different class would corrupt whatever lives there.
local EVE_ANIM_CLASS  = "CH_P_EVE_01_AnimBP_New_C"
local ALPHA_OFFSET    = 0x11330

--- Which node the alpha gates is NOT assumed.
---
--- Eve's AnimBP has no node called CustomAnim at all. Grepping
--- CH_P_EVE_01_AnimBP_New.hpp for node types returns SequencePlayer,
--- BlendSpacePlayer, BlendListByBool, ApplyAdditive and one
--- SBAnimGraphNode_CustomBlendSpacePlayer, and nothing named CustomAnim. So
--- CustomAnimAlpha is a variable feeding some blend, not a node's own name.
---
--- Guessing a name here would have measured a node that does not exist and
--- reported "weight never rose", which reads exactly like the hook failing.
--- Instead every node is sampled before and after, and the one whose weight
--- actually moves is the answer, whatever it turns out to be called.

-- --------------------------------------------------------------------- io

local handle = io.open(OutputFile, "w")

local function Out(line)
    line = tostring(line)
    print("[SBLove/P12] " .. line .. "\n")
    if handle then handle:write(line, "\n") handle:flush() end
end

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function IsLive(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function Number(value, fallback)
    if type(value) == "number" then return value end
    return fallback
end

-- ------------------------------------------------------------------ state

local Step, Ticks = "wait", 0
local Instance, ClassName = nil, nil
local Best = { weight = 0.0, node = nil, was = 0.0, now = 0.0 }
local Baseline, Latest = {}, {}

--- Snapshot every node's weight. Playback.DiscoverNodes already knows the 85
--- node properties on this graph, so this reuses proven code rather than
--- guessing which one matters.
local function Weights(instance)
    local out = {}
    for _, prop in ipairs(Playback.DiscoverNodes(instance)) do
        local node = Try(function() return instance[prop] end)
        if node ~= nil then
            local weight = Number(Try(function() return node.BlendWeight end), nil)
            if weight then out[prop] = weight end
        end
    end
    return out
end

--- Nodes whose weight moved between two snapshots, largest change first. The
--- change is the signal; an absolute weight says nothing, because plenty of
--- nodes sit at 1.0 permanently.
local function Changed(before, after)
    local rows = {}
    for prop, now in pairs(after) do
        local was = before[prop]
        if was ~= nil and math.abs(now - was) > 0.01 then
            rows[#rows + 1] = { prop = prop, was = was, now = now,
                                delta = math.abs(now - was) }
        end
    end
    table.sort(rows, function(a, b) return a.delta > b.delta end)
    return rows
end

-- ------------------------------------------------- procedural posing recon

--- The skeleton's bone names, for driving an arm procedurally.
---
--- Not guessed. physics.lua records the naming as "Bip001-R-Hand", a 3ds Max
--- Biped convention, but the exact spelling of every joint in the chain
--- matters: FBoneReference silently does nothing if the name does not resolve,
--- which would look identical to the hook failing.
local function ReportBones(pawn)
    local mesh = Playback.GetMesh(pawn, 0)
    if not IsLive(mesh) then
        Out("  no skeletal mesh, cannot list bones")
        return
    end

    local count = Number(Try(function() return mesh:GetNumBones() end), 0)
    Out("")
    Out(string.format("skeleton: %d bones", count))

    -- Only the ones a hand-to-chest pose needs, out of several hundred.
    local wanted = { "Hand", "Forearm", "UpperArm", "Clavicle", "Spine", "Neck" }
    local shown = 0
    for i = 0, count - 1 do
        local name = Try(function() return mesh:GetBoneName(i):ToString() end)
        if name then
            for _, part in ipairs(wanted) do
                if name:find(part) then
                    Out(string.format("  [%3d] %s", i, name))
                    shown = shown + 1
                    break
                end
            end
        end
        if shown >= 40 then break end
    end
    if shown == 0 then
        Out("  none matched Hand/Forearm/UpperArm/Clavicle/Spine/Neck.")
        Out("  The naming differs from what physics.lua recorded; dump all")
        Out("  bone names before writing any FBoneReference.")
    end
end

--- Which ModifyBone nodes exist and which are free.
---
--- Eve's AnimBP declares seven. A node the game already drives cannot be
--- borrowed without breaking whatever it does, so the ones with an empty
--- BoneToModify and Alpha 0 are the candidates.
local MODIFY_BONE_NODES = {
    "AnimGraphNode_ModifyBone",   "AnimGraphNode_ModifyBone_1",
    "AnimGraphNode_ModifyBone_2", "AnimGraphNode_ModifyBone_3",
    "AnimGraphNode_ModifyBone_4", "AnimGraphNode_ModifyBone_5",
    "AnimGraphNode_ModifyBone_6",
}

local function ReportModifyBones(instance)
    Out("")
    Out("ModifyBone nodes (candidates for procedural posing):")
    for _, name in ipairs(MODIFY_BONE_NODES) do
        local node = Try(function() return instance[name] end)
        if node == nil then
            Out(string.format("  %-28s absent", name))
        else
            local alpha = Number(Try(function() return node.Alpha end), nil)
            local bone = Try(function()
                return node.BoneToModify.BoneName:ToString() end)
            Out(string.format("  %-28s alpha %s  bone %s", name,
                alpha and string.format("%.2f", alpha) or "n/a",
                (bone and bone ~= "" and bone ~= "None") and bone or "<unset>"))
        end
    end
end

local function Handoff()
    local file = io.open(AnimFile, "w")
    if not file then
        Out("  could not write " .. AnimFile)
        return false
    end
    file:write(string.format("instance=0x%X offset=0x%X value=1.0\n",
        Instance, ALPHA_OFFSET))
    file:close()
    Out(string.format("  wrote %s", AnimFile))
    Out(string.format("    instance=0x%X offset=0x%X", Instance, ALPHA_OFFSET))
    return true
end

local function Tick()
    if Step == "finished" then return end

    if Step == "wait" then
        if not Actors.InGameplay() then
            if Ticks % 10 == 0 then Out("waiting for gameplay (not the menu)") end
            Ticks = Ticks + 1
            return
        end

        local pawn = Actors.GetPlayerPawn()
        local instance = Playback.GetAnimInstance(pawn, 0)
        if not IsLive(instance) then
            Out("no anim instance on the player pawn yet")
            return
        end

        ClassName = Try(function() return instance:GetClass():GetFName():ToString() end)
        local address = Try(function() return instance:GetAddress() end)

        Out("")
        Out("anim instance found")
        Out("  class:   " .. tostring(ClassName))
        Out(string.format("  address: 0x%X", address or 0))

        -- The offset belongs to one specific class. Handing it over for any
        -- other class would be a blind write into a different layout.
        if ClassName ~= EVE_ANIM_CLASS then
            Out("")
            Out("  CLASS MISMATCH -- expected " .. EVE_ANIM_CLASS)
            Out("  CustomAnimAlpha sits at a different offset in every AnimBP,")
            Out("  so handing 0x11330 to this class would be a blind write.")
            Out("  Look up this class in research/CXXHeaderDump and update")
            Out("  ALPHA_OFFSET before rerunning.")
            Out("")
            Out("ALL DONE -- you can quit.")
            Step = "finished"
            return
        end

        if not address then
            Out("  GetAddress failed, nothing to hand over")
            Step = "finished"
            return
        end
        Instance = address

        Out("")
        -- Read-only reconnaissance for procedural posing. Folded in here
        -- because it costs nothing and saves a separate run.
        ReportBones(pawn)
        ReportModifyBones(instance)

        Out("baseline: sampling every node's weight")
        Baseline = Weights(instance)
        local count = 0
        for _ in pairs(Baseline) do count = count + 1 end
        Out(string.format("  %d nodes report a BlendWeight", count))

        Out("")
        Out("handing the address to SBLoveNative")
        if not Handoff() then Step = "finished" return end

        Out("")
        Out("watching for the node to come alive (30 seconds)")
        Step, Ticks = "watch", 0
        return
    end

    if Step == "watch" then
        local pawn = Actors.GetPlayerPawn()
        local instance = Playback.GetAnimInstance(pawn, 0)
        if IsLive(instance) then
            local alpha = Number(Try(function()
                return instance.CustomAnimAlpha end), nil)

            Latest = Weights(instance)
            for _, row in ipairs(Changed(Baseline, Latest)) do
                if row.delta > Best.weight then
                    Best.weight, Best.node = row.delta, row.prop
                    Best.was, Best.now = row.was, row.now
                end
            end

            if Ticks % 6 == 0 then
                Out(string.format("  alpha %s   biggest node change %.3f%s",
                    alpha and string.format("%.3f", alpha) or "n/a",
                    Best.weight,
                    Best.node and (" (" .. Best.node .. ")") or ""))
            end
        end

        Ticks = Ticks + 1
        if Ticks >= 60 then
            Out("")
            Out("################ RESULT ################")
            if Best.weight > 0.01 then
                Out(string.format("  A node responded: %s", Best.node))
                Out(string.format("    weight %.3f -> %.3f", Best.was, Best.now))
                Out("  The graph evaluated with our alpha, so the write is")
                Out("  landing after the event graph. This is the route P8")
                Out("  had to abandon because Lua could not order the write.")
            else
                Out("  Node weight never rose above 0.")
                Out("")
                Out("  Read the native log before concluding anything:")
                Out("    ue4ss/Mods/SBLoveNative/SBLoveNative.txt")
                Out("  If it reports no alpha writes, the hook never matched")
                Out("  this object and the problem is the handoff, not the")
                Out("  ordering. If it reports many writes and the weight is")
                Out("  still 0, the alpha is not what gates this node.")
            end
            Out("")
            Out("ALL DONE -- you can quit.")
            Step = "finished"
        end
        return
    end
end

Out("SBLoveFramework P12 -- can a native hook win the CustomAnimAlpha race?")
Out("Load a save, stand still. About 40 seconds.")
Out("")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)
