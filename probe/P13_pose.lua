--[[
    SBLoveFramework -- procedural limb posing (P13)
    ------------------------------------------------------------------
    WHAT THIS IS FOR

    Posing Eve's arm without authoring an animation. A custom AnimSequence
    would need the UE 4.26 editor, which is the wall the whole authoring
    pipeline ran into. A ModifyBone node needs nothing but the running game.

    It is also the better instrument for this job. A baked clip is fixed; a
    ModifyBone rotation is a live parameter, so which arm, how far, and how
    much can all change at runtime -- and the physics layer keeps reacting to
    the result, which is the difference between a hand resting on a surface and
    a hand that is actually displacing it.

    HOW THE WORK IS SPLIT

        Lua      sets BoneToModify, because that is an FName
        native   holds Alpha and Rotation every frame

    The split is not arbitrary. A ModifyBone node's fields are exposed pins,
    and the anim graph re-copies exposed pins every frame -- that is what
    physics.lua found when its writes kept reverting. So the numbers have to be
    re-asserted after the graph runs, which needs the ProcessEvent hook, which
    is native. The bone name only has to be set once, so it stays in Lua where
    constructing an FName is free.

    WHAT IS MEASURED

    The hand's world position, sampled before and after.

    Not the node's fields: reading back a value we just wrote is how P6 fooled
    itself into thinking it had won this exact race. If the forearm really
    rotates, the hand it carries moves in world space, and that cannot be
    faked by a write the graph ignores.

    A control runs first, because standing still is not perfectly still --
    breathing idles move the hand a little on their own.

    THE TARGET

    Bip001-R-Forearm, additive, in bone space. Additive rather than Replace
    because Replace would snap the bone to an absolute orientation and a wrong
    guess would look like a broken limb. Additive from wherever the animation
    already has it is both safer and easier to read.

    Output: ue4ss/SBLoveFramework_probe.txt, plus ue4ss/SBLove_anim.txt.
--]]

local Actors   = require("actors")
local Playback = require("playback")

local OutputFile = "ue4ss/SBLoveFramework_probe.txt"
local AnimFile   = "ue4ss/SBLove_anim.txt"
local POLL_MS    = 500

local EVE_ANIM_CLASS = "CH_P_EVE_01_AnimBP_New_C"
local ALPHA_OFFSET   = 0x11330

--- AnimGraphNode_ModifyBone's offset inside UCH_P_EVE_01_AnimBP_New_C, from
--- CH_P_EVE_01_AnimBP_New.hpp:277. P12 found this node idle at alpha 0.00 on
--- Bip001-R-Toe0, while the other five sit at alpha 1.00 driving props and the
--- drone. Borrowing one of those would break whatever it does.
local MODIFY_NODE        = "AnimGraphNode_ModifyBone"
local MODIFY_NODE_OFFSET = 0x10408

local TARGET_BONE  = "Bip001-R-Forearm"
local MEASURE_BONE = "Bip001-R-Hand"

--- 45 degrees is large enough to be unmistakable in a position measurement and
--- small enough not to look like the arm snapped.
local POSE = { pitch = 0.0, yaw = 0.0, roll = 45.0, mode = 2, space = 3 }

-- --------------------------------------------------------------------- io

local handle = io.open(OutputFile, "w")

local function Out(line)
    line = tostring(line)
    print("[SBLove/P13] " .. line .. "\n")
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

-- ------------------------------------------------------------- measurement

--- Where a bone is, in world space. This is the honest signal: it is produced
--- by the animation system after evaluation, so it cannot report a write the
--- graph ignored.
local function BoneLocation(pawn, boneName)
    local mesh = Playback.GetMesh(pawn, 0)
    if not IsLive(mesh) then return nil end
    -- GetBoneLocationByName, not GetBoneLocation. The first attempt guessed
    -- the name, got nil, and reported "nothing to measure" -- the third time
    -- this session an assumed API name has masqueraded as a real finding.
    local location = Try(function()
        return mesh:GetBoneLocationByName(FName(boneName), 0) end)
    if not location then return nil end
    return {
        x = Number(location.X, 0.0),
        y = Number(location.Y, 0.0),
        z = Number(location.Z, 0.0),
    }
end

local function Distance(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ------------------------------------------------------------------ state

local Step, Ticks = "wait", 0
local Instance, NodeAddress = nil, nil
--- What the borrowed node pointed at before we took it. This node is not
--- really idle: the game drives its alpha during play, which is why repointing
--- it alone was enough to visibly move Eve's arm. Left unrestored, her toe
--- correction keeps landing on her forearm until the level reloads.
local OriginalBone = nil

local Anchor      = nil     -- first measured hand position
local NaturalDrift = 0.0    -- how far it wanders on its own
local PosedDrift   = 0.0    -- how far it moves once the pose is held

local function Handoff()
    local file = io.open(AnimFile, "w")
    if not file then
        Out("  could not write " .. AnimFile)
        return false
    end
    file:write(string.format("instance=0x%X offset=0x%X value=1.0\n",
        Instance, ALPHA_OFFSET))
    file:write(string.format(
        "pose=0x%X pitch=%.1f yaw=%.1f roll=%.1f mode=%d space=%d\n",
        NodeAddress, POSE.pitch, POSE.yaw, POSE.roll, POSE.mode, POSE.space))
    file:close()
    return true
end

--- Put the borrowed node back. Skipping this leaves Eve's toe correction
--- driving her forearm for the rest of the session.
function Restore()
    if not OriginalBone or OriginalBone == "" then return end
    local pawn = Actors.GetPlayerPawn()
    local instance = Playback.GetAnimInstance(pawn, 0)
    if not IsLive(instance) then return end
    local node = Try(function() return instance[MODIFY_NODE] end)
    if node == nil then return end
    local ok = pcall(function()
        node.BoneToModify.BoneName = FName(OriginalBone)
    end)
    Out(string.format("restored %s -> %s (%s)", MODIFY_NODE, OriginalBone,
        ok and "ok" or "FAILED"))
    OriginalBone = nil
end

local function Tick()
    if Step == "finished" then return end
    local pawn = Actors.GetPlayerPawn()

    if Step == "wait" then
        if not Actors.InGameplay() then
            if Ticks % 10 == 0 then Out("waiting for gameplay (not the menu)") end
            Ticks = Ticks + 1
            return
        end

        local instance = Playback.GetAnimInstance(pawn, 0)
        if not IsLive(instance) then
            Out("no anim instance yet")
            return
        end

        local className = Try(function()
            return instance:GetClass():GetFName():ToString() end)
        if className ~= EVE_ANIM_CLASS then
            Out("class is " .. tostring(className) .. ", expected " .. EVE_ANIM_CLASS)
            Out("Node and property offsets belong to that one class, so this")
            Out("would be a blind write into a different layout.")
            Step = "finished"
            return
        end

        Instance = Try(function() return instance:GetAddress() end)
        if not Instance then
            Out("GetAddress failed")
            Step = "finished"
            return
        end
        NodeAddress = Instance + MODIFY_NODE_OFFSET

        Out("")
        Out("anim instance 0x" .. string.format("%X", Instance))
        Out(string.format("  %s at +0x%X -> 0x%X",
            MODIFY_NODE, MODIFY_NODE_OFFSET, NodeAddress))

        -- Confirm the node really is the idle one before borrowing it.
        local node = Try(function() return instance[MODIFY_NODE] end)
        local alpha = node and Number(Try(function() return node.Alpha end), nil)
        local bone = node and Try(function()
            return node.BoneToModify.BoneName:ToString() end)
        Out(string.format("  currently: alpha %s, bone %s",
            alpha and string.format("%.2f", alpha) or "n/a", tostring(bone)))

        if alpha and alpha > 0.01 then
            Out("")
            Out("  This node is ACTIVE. Borrowing it would break whatever it")
            Out("  drives. Pick another with alpha 0 from P12's list.")
            Step = "finished"
            return
        end

        OriginalBone = bone
        -- The one thing Lua does: point the node at the bone we want.
        local ok = pcall(function()
            node.BoneToModify.BoneName = FName(TARGET_BONE)
        end)
        Out(string.format("  set BoneToModify = %s -> %s", TARGET_BONE,
            ok and "ok" or "FAILED"))
        if not ok then Step = "finished" return end

        Anchor = BoneLocation(pawn, MEASURE_BONE)
        if Anchor then
            Out(string.format("  %s at (%.1f, %.1f, %.1f)", MEASURE_BONE,
                Anchor.x, Anchor.y, Anchor.z))
        else
            -- Not fatal. The last run aborted here and so never handed the
            -- pose over, which meant the thing being tested never ran at all.
            -- A broken instrument should not cancel the experiment.
            Out("  cannot read " .. MEASURE_BONE .. ", continuing without")
            Out("  numeric proof; the visible result still counts.")
        end

        Out("")
        Out("CONTROL: 8 seconds of natural drift, pose not yet requested")
        Step, Ticks = "control", 0
        return
    end

    if Step == "control" then
        local now = BoneLocation(pawn, MEASURE_BONE)
        local drift = Distance(Anchor, now)
        if drift and drift > NaturalDrift then NaturalDrift = drift end
        if not Anchor then Anchor = now end

        Ticks = Ticks + 1
        if Ticks < 16 then return end

        Out(string.format("  natural drift: %.2f cm (breathing idles)",
            NaturalDrift))
        Out("  anything at or below this proves nothing.")
        Out("")
        Out(string.format("requesting pose: %s roll %+.0f deg, additive, bone space",
            TARGET_BONE, POSE.roll))
        if not Handoff() then Step = "finished" return end
        Out("  handed to SBLoveNative, which holds it after every ProcessEvent")
        Out("")
        Out("watching " .. MEASURE_BONE .. " for 20 seconds")
        Step, Ticks = "posed", 0
        return
    end

    if Step == "posed" then
        local now = BoneLocation(pawn, MEASURE_BONE)
        local drift = Distance(Anchor, now)
        if drift and drift > PosedDrift then PosedDrift = drift end

        if Ticks % 8 == 0 and drift then
            Out(string.format("  %s moved %.2f cm from where it started",
                MEASURE_BONE, drift))
        end

        Ticks = Ticks + 1
        if Ticks < 40 then return end

        Out("")
        Out("################ RESULT ################")
        Out(string.format("  natural drift: %.2f cm", NaturalDrift))
        Out(string.format("  posed drift:   %.2f cm", PosedDrift))
        Out("")
        if PosedDrift > NaturalDrift * 2.0 + 1.0 then
            Out("  THE BONE MOVED. A ModifyBone node, held against the graph")
            Out("  by the native hook, poses Eve's arm with no authored")
            Out("  animation and no editor.")
            Out("")
            Out("  Next: tune pitch/yaw/roll on the arm chain for a real pose,")
            Out("  and let the physics layer respond to the contact.")
        else
            Out("  No movement beyond the noise floor. Check the native log:")
            Out("    ue4ss/Mods/SBLoveNative/SBLoveNative.txt")
            Out("  If pose writes are 0 the handoff failed. If they are")
            Out("  climbing and the bone still did not move, then either the")
            Out("  bone name did not resolve, or this node is not connected")
            Out("  into the graph's output at all -- a node can exist and be")
            Out("  evaluated by nothing.")
        end
        Restore()
        Out("")
        Out("ALL DONE -- you can quit.")
        Step = "finished"
        return
    end
end

Out("SBLoveFramework P13 -- pose Eve's arm with no authored animation")
Out("Load a save, stand still, do not move. About 35 seconds.")
Out("")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)

-- Also restore if the mod is unloaded or the game leaves gameplay mid-run,
-- so a quit partway through does not leave the node hijacked.
pcall(RegisterOnUnloadCallback or function() end, function()
    Try(Restore)
end)
