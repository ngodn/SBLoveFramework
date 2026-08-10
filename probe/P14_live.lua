--[[
    SBLoveFramework -- live console (P14)
    ------------------------------------------------------------------
    WHY THIS EXISTS

    Every experiment so far has cost a game restart. Write a probe, install it,
    launch, load a save, wait, read a log, find the instrument was broken,
    repeat. Three separate measurement bugs this session were each a full cycle,
    and two of them reported a broken instrument as a real finding.

    This replaces that with a loop that runs while the game is running.

        write  ue4ss/SBLove_cmd.txt      one line: <seq> <command> <args>
        read   ue4ss/SBLove_out.txt      the result, tagged with that seq

    The sequence number is what makes it reliable. Polling file contents alone
    cannot tell a repeated command from a stale read, and a stale read is
    exactly the failure that wastes a cycle. A command runs when its seq
    differs from the last one executed, so the same command can be sent twice
    and will run twice.

    RegisterKeyBind is not used. It does not fire under Proton, which is why
    this project drives everything from files.

    COMMANDS

      help                          list these
      status                        pawn, anim instance, picked node
      bones <substring>             matching bone names and world positions
      where <bone>                  one bone's world position
      nodes [minweight]             anim graph nodes and their blend weights
      get <property>                read a property off the anim instance
      pick <NodeName>               choose which ModifyBone node to drive
      bone <BoneName>               point the picked node at a bone
      pose <pitch> <yaw> <roll> [mode] [space]
                                    hold a rotation, via the native hook
      alpha <value>                 hold a different alpha on the node
      clear                         restore the node and drop the pose
      exec <console command>        run a game console command

    mode:  0 ignore, 1 replace, 2 additive        space: 0 world, 1 component,
                                                         2 parent, 3 bone

    SAFETY

    `clear` runs on unload too. The borrowed ModifyBone node is a foot
    correction the game drives itself, so leaving it repointed means Eve's toe
    correction keeps landing on her forearm for the rest of the session.
--]]

local Actors   = require("actors")
local Playback = require("playback")

local CmdFile  = "ue4ss/SBLove_cmd.txt"
local OutFile  = "ue4ss/SBLove_out.txt"
local AnimFile = "ue4ss/SBLove_anim.txt"
local POLL_MS  = 250

local EVE_ANIM_CLASS = "CH_P_EVE_01_AnimBP_New_C"
local ALPHA_OFFSET   = 0x11330

--- ModifyBone nodes and their offsets in UCH_P_EVE_01_AnimBP_New_C. P12 found
--- only the two toe nodes idle; the rest drive props and the drone.
local NODES = {
    AnimGraphNode_ModifyBone   = 0x10408,
    AnimGraphNode_ModifyBone_1 = 0x10300,
    AnimGraphNode_ModifyBone_2 = 0x8518,
    AnimGraphNode_ModifyBone_3 = 0x41B8,
    AnimGraphNode_ModifyBone_4 = 0x1180,
    AnimGraphNode_ModifyBone_5 = 0x1078,
    AnimGraphNode_ModifyBone_6 = 0x0F70,
}

-- --------------------------------------------------------------------- io

local Lines = {}

local function Say(line)
    Lines[#Lines + 1] = tostring(line)
end

local function Flush(seq)
    local file = io.open(OutFile, "w")
    if not file then return end
    file:write("seq=", tostring(seq), "\n")
    for _, line in ipairs(Lines) do file:write(line, "\n") end
    file:close()
    Lines = {}
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

local Picked      = "AnimGraphNode_ModifyBone"
local OriginalBone = nil
local Pose = { pitch = 0, yaw = 0, roll = 0, mode = 2, space = 3, alpha = 1.0 }

--- Floats to re-assert after every ProcessEvent, as offset -> value.
---
--- Writing an anim node's pin does not stick: the graph copies its exposed
--- pins from anim-BP variables just before evaluating, so a pin write lands in
--- the window between and is gone before it matters. The variable is the thing
--- worth holding. Which variable feeds which node is not in the dump, so it
--- has to be found by trying them, which is what this is for.
--- offset -> { value, width }. Width 1 means a single byte, which anim-BP
--- bools are: Enable_R_Hand at +0x11191 sits directly against Enable_L_Hand at
--- +0x11192, so a 4-byte write over one clobbers three neighbours.
local Holds = {}

local function Instance()
    local pawn = Actors.GetPlayerPawn()
    if not IsLive(pawn) then return nil, nil end
    local instance = Playback.GetAnimInstance(pawn, 0)
    if not IsLive(instance) then return nil, pawn end
    return instance, pawn
end

local function Mesh()
    local _, pawn = Instance()
    if not pawn then return nil end
    return Playback.GetMesh(pawn, 0)
end

--- GetSocketLocation, inherited from USceneComponent, where a socket name
--- falls back to a bone name. GetBoneLocation does not exist and
--- GetBoneLocationByName is on UPoseableMeshComponent, not on the skeletal
--- mesh Eve has; both returned nil and read as "the bone did not move".
local function Where(boneName)
    local mesh = Mesh()
    if not IsLive(mesh) then return nil end
    local v = Try(function() return mesh:GetSocketLocation(FName(boneName)) end)
    if not v then return nil end
    return Number(v.X, 0), Number(v.Y, 0), Number(v.Z, 0)
end

--- Rewrite the handoff. Native polls this file and re-applies on change, so
--- this is what makes a pose retunable without a restart.
local function PushPose()
    local instance = Instance()
    if not IsLive(instance) then return false, "no anim instance" end
    local address = Try(function() return instance:GetAddress() end)
    if not address then return false, "GetAddress failed" end
    local offset = NODES[Picked]
    if not offset then return false, "unknown node " .. Picked end

    local file = io.open(AnimFile, "w")
    if not file then return false, "cannot write " .. AnimFile end
    file:write(string.format("instance=0x%X offset=0x%X value=1.0\n",
        address, ALPHA_OFFSET))
    file:write(string.format(
        "pose=0x%X pitch=%.2f yaw=%.2f roll=%.2f mode=%d space=%d\n",
        address + offset, Pose.pitch, Pose.yaw, Pose.roll, Pose.mode, Pose.space))
    for off, entry in pairs(Holds) do
        file:write(string.format("hold=0x%X %.4f %d\n", off, entry.value,
            entry.width or 4))
    end
    file:close()
    return true
end

local function Restore()
    if OriginalBone and OriginalBone ~= "" then
        local instance = Instance()
        if IsLive(instance) then
            local node = Try(function() return instance[Picked] end)
            if node ~= nil then
                pcall(function()
                    node.BoneToModify.BoneName = FName(OriginalBone)
                end)
            end
        end
        OriginalBone = nil
    end
    local file = io.open(AnimFile, "w")
    if file then file:write("cleared\n") file:close() end
end

-- --------------------------------------------------------------- commands

local Commands = {}

function Commands.help()
    Say("status | bones <sub> | where <bone> | nodes [minweight] | get <prop>")
    Say("pick <NodeName> | bone <BoneName> | pose <p> <y> <r> [mode] [space]")
    Say("alpha <v> | hold <name|0xOFF> <v> | holds | clear | exec <cmd>")
    Say("swap <animPath> | unswap    upper-body custom slot content")
    Say("holdb <name> <0|1> | holdv <name> <x> <y> <z> | grope [side up fwd]")
    Say("mode: 0 ignore 1 replace 2 additive   space: 0 world 1 comp 2 parent 3 bone")
end

function Commands.status()
    local instance, pawn = Instance()
    Say("in gameplay: " .. tostring(Actors.InGameplay()))
    Say("pawn: " .. tostring(pawn and Try(function() return pawn:GetFullName() end)))
    if not IsLive(instance) then Say("no anim instance") return end

    local class = Try(function()
        return instance:GetClass():GetFName():ToString() end)
    local address = Try(function() return instance:GetAddress() end)
    Say(string.format("anim instance: 0x%X  class %s", address or 0,
        tostring(class)))
    if class ~= EVE_ANIM_CLASS then
        Say("WARNING: node offsets belong to " .. EVE_ANIM_CLASS ..
            ", writes would be blind here")
    end

    Say("picked node: " .. Picked)
    for name, offset in pairs(NODES) do
        local node = Try(function() return instance[name] end)
        if node ~= nil then
            local alpha = Number(Try(function() return node.Alpha end), nil)
            local bone = Try(function()
                return node.BoneToModify.BoneName:ToString() end)
            Say(string.format("  %-28s +0x%05X alpha %s bone %s",
                name, offset,
                alpha and string.format("%.2f", alpha) or "n/a",
                tostring(bone)))
        end
    end
    Say(string.format("pose held: pitch %.1f yaw %.1f roll %.1f mode %d space %d",
        Pose.pitch, Pose.yaw, Pose.roll, Pose.mode, Pose.space))
end

function Commands.bones(filter)
    local mesh = Mesh()
    if not IsLive(mesh) then Say("no mesh") return end
    local count = Number(Try(function() return mesh:GetNumBones() end), 0)
    Say(string.format("%d bones", count))
    local shown = 0
    for i = 0, count - 1 do
        local name = Try(function() return mesh:GetBoneName(i):ToString() end)
        if name and (not filter or name:lower():find(filter:lower(), 1, true)) then
            local x, y, z = Where(name)
            Say(string.format("  [%3d] %-28s %s", i, name,
                x and string.format("(%.1f, %.1f, %.1f)", x, y, z) or ""))
            shown = shown + 1
            if shown >= 60 then Say("  ...truncated") break end
        end
    end
    if shown == 0 then Say("  nothing matched") end
end

function Commands.where(bone)
    if not bone then Say("usage: where <bone>") return end
    local x, y, z = Where(bone)
    if not x then Say(bone .. ": unreadable") return end
    Say(string.format("%s (%.2f, %.2f, %.2f)", bone, x, y, z))
end

function Commands.nodes(minweight)
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local floor = tonumber(minweight) or 0.01
    local rows = {}
    for _, prop in ipairs(Playback.DiscoverNodes(instance)) do
        local node = Try(function() return instance[prop] end)
        if node ~= nil then
            local w = Number(Try(function() return node.BlendWeight end), nil)
            if w and w >= floor then rows[#rows + 1] = { prop = prop, w = w } end
        end
    end
    table.sort(rows, function(a, b) return a.w > b.w end)
    Say(string.format("%d nodes at weight >= %.2f", #rows, floor))
    for i = 1, math.min(#rows, 40) do
        Say(string.format("  %-40s %.3f", rows[i].prop, rows[i].w))
    end
end

function Commands.get(prop)
    if not prop then Say("usage: get <property>") return end
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local value = Try(function() return instance[prop] end)
    Say(string.format("%s = %s", prop, tostring(value)))
end

function Commands.pick(name)
    if not name or not NODES[name] then
        Say("usage: pick <NodeName>")
        for key in pairs(NODES) do Say("  " .. key) end
        return
    end
    Restore()
    Picked = name
    Say("picked " .. name)
end

function Commands.bone(name)
    if not name then Say("usage: bone <BoneName>") return end
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local node = Try(function() return instance[Picked] end)
    if node == nil then Say("node " .. Picked .. " not found") return end

    if not OriginalBone then
        OriginalBone = Try(function()
            return node.BoneToModify.BoneName:ToString() end)
    end
    local ok = pcall(function()
        node.BoneToModify.BoneName = FName(name)
    end)
    Say(string.format("%s -> %s (%s), was %s", Picked, name,
        ok and "ok" or "FAILED", tostring(OriginalBone)))
end

function Commands.pose(pitch, yaw, roll, mode, space)
    Pose.pitch = tonumber(pitch) or 0
    Pose.yaw   = tonumber(yaw)   or 0
    Pose.roll  = tonumber(roll)  or 0
    Pose.mode  = tonumber(mode)  or Pose.mode
    Pose.space = tonumber(space) or Pose.space
    local ok, err = PushPose()
    Say(string.format("pose pitch %.1f yaw %.1f roll %.1f mode %d space %d -> %s",
        Pose.pitch, Pose.yaw, Pose.roll, Pose.mode, Pose.space,
        ok and "handed to native" or tostring(err)))
end

function Commands.alpha(value)
    Pose.alpha = tonumber(value) or 1.0
    local ok, err = PushPose()
    Say(string.format("alpha %.2f -> %s", Pose.alpha,
        ok and "handed to native" or tostring(err)))
end

--- hold <hexoffset> <value>   re-assert a float on the anim instance
---
--- Offsets come from research/CXXHeaderDump/CH_P_EVE_01_AnimBP_New.hpp. Named
--- shortcuts cover the ones worth trying first; anything else can be given as
--- a raw offset, because the point is to find which variable actually drives a
--- node and that is not documented anywhere.
local NAMED = {
    ikalpharight        = 0x113AC,
    enablerhand         = 0x11191,
    enablelhand         = 0x11192,
    righthitloc         = 0x113FC,
    lefthitloc          = 0x11408,
    lookatlocation      = 0x1141C,
    tpshandsocket       = 0x112D8,
    targetsocketloc     = 0x11198,
    ikalphaleft         = 0x113A8,
    handikright         = 0x11CBC,   -- EventMoveIKAlpha_Hand_R
    handikleft          = 0x11CB8,   -- EventMoveIKAlpha_Hand_L
    footikright         = 0x11CC4,
    footikleft          = 0x11CC0,
    eventmoveik         = 0x11C20,
    customanimalpha     = 0x11330,
    customanimalpha2    = 0x11338,
    customanimadditive  = 0x1133C,
    customanimupper     = 0x11378,
    toermove            = 0x11180,
    toelmove            = 0x1117C,
    fullbodyik          = 0x11D38,
}

function Commands.hold(what, value)
    if not what then
        Say("usage: hold <name|0xOFFSET> <value>   (hold none  to drop all)")
        local names = {}
        for k in pairs(NAMED) do names[#names + 1] = k end
        table.sort(names)
        for _, k in ipairs(names) do
            Say(string.format("  %-20s +0x%05X", k, NAMED[k]))
        end
        return
    end
    if what:lower() == "none" then
        Holds = {}
        local ok, err = PushPose()
        Say("all holds dropped -> " .. (ok and "ok" or tostring(err)))
        return
    end

    local offset = NAMED[what:lower()] or tonumber(what)
    if not offset then Say("unknown: " .. what) return end
    Holds[offset] = { value = tonumber(value) or 1.0, width = 4 }
    local ok, err = PushPose()
    Say(string.format("hold +0x%X = %.3f -> %s", offset, Holds[offset].value,
        ok and "handed to native" or tostring(err)))
end

--- holdb <offset> <0|1>   hold a single byte, for anim-BP bools
function Commands.holdb(what, value)
    if not what then Say("usage: holdb <name|0xOFFSET> <0|1>") return end
    local offset = NAMED[what:lower()] or tonumber(what)
    if not offset then Say("unknown: " .. what) return end
    Holds[offset] = { value = tonumber(value) or 1.0, width = 1 }
    local ok, err = PushPose()
    Say(string.format("holdb +0x%X = %d -> %s", offset,
        Holds[offset].value ~= 0 and 1 or 0,
        ok and "handed to native" or tostring(err)))
end

--- holdv <offset> <x> <y> <z>   an FVector is three consecutive floats, so
--- this needs no new native support.
function Commands.holdv(what, x, y, z)
    if not what or not z then Say("usage: holdv <name|0xOFFSET> <x> <y> <z>") return end
    local offset = NAMED[what:lower()] or tonumber(what)
    if not offset then Say("unknown: " .. what) return end
    Holds[offset]     = { value = tonumber(x) or 0, width = 4 }
    Holds[offset + 4] = { value = tonumber(y) or 0, width = 4 }
    Holds[offset + 8] = { value = tonumber(z) or 0, width = 4 }
    local ok, err = PushPose()
    Say(string.format("holdv +0x%X = (%.1f, %.1f, %.1f) -> %s", offset,
        tonumber(x), tonumber(y), tonumber(z),
        ok and "handed to native" or tostring(err)))
end

--- grope [side] [up] [forward]   aim the hand IK at her own chest
---
--- The ControlRig gated by Enable_R_Hand takes a WORLD position in
--- RightHitLoc, which is how the game puts a hand on a wall or ledge. Feeding
--- it a point on her own chest is the same operation with a different target.
---
--- The target is computed from Bip001-Spine2 rather than hardcoded, because a
--- world position is only meaningful relative to where she is standing.
function Commands.grope(side, up, forward)
    local sx, sy, sz = Where("Bip001-Spine2")
    if not sx then Say("cannot read Bip001-Spine2") return end

    local dside    = tonumber(side)    or 8.0
    local dup      = tonumber(up)      or 6.0
    local dforward = tonumber(forward) or 12.0

    -- Offsets are applied in world axes, which is only correct while she faces
    -- a fixed direction. Good enough to find the pose; a real scene has to
    -- build this in her own frame.
    local tx = sx + dforward
    local ty = sy + dside
    local tz = sz + dup

    Holds[0x11191] = { value = 1.0, width = 1 }          -- Enable_R_Hand
    Holds[0x113FC] = { value = tx, width = 4 }           -- RightHitLoc.X
    Holds[0x11400] = { value = ty, width = 4 }
    Holds[0x11404] = { value = tz, width = 4 }
    local ok, err = PushPose()

    Say(string.format("spine2 (%.1f, %.1f, %.1f)", sx, sy, sz))
    Say(string.format("target (%.1f, %.1f, %.1f)  side %+.1f up %+.1f fwd %+.1f",
        tx, ty, tz, dside, dup, dforward))
    Say("Enable_R_Hand held, RightHitLoc held -> " ..
        (ok and "handed to native" or tostring(err)))
    Say("if the hand does not move, this rig is not the one that places hands")
end

function Commands.holds()
    local n = 0
    for off, entry in pairs(Holds) do
        Say(string.format("  +0x%05X = %.3f (%s)", off, entry.value,
            (entry.width == 1) and "byte" or "float"))
        n = n + 1
    end
    if n == 0 then Say("  nothing held") end
end

--- swap <animObjectPath>   put an animation into the upper-body custom slot
---
--- CustomAnimAlpha_Upper gates that slot, and holding it at 1.0 moves the hand
--- a repeatable 4.0 cm. Only 4 cm because the slot is EMPTY, so the graph
--- blends toward almost the pose it already had. Content is the missing half.
---
--- SBAnimGraphNode_CustomBlendSpacePlayer is the slot's player. A BlendSpace is
--- a shared asset, so its samples are captured before the first write and
--- restored by unswap; one left edited stays wrong until the level reloads.
local CUSTOM_BS_NODE = "SBAnimGraphNode_CustomBlendSpacePlayer"

function Commands.swap(path)
    if not path then
        Say("usage: swap /Game/Art/Character/PC/CH_P_EVE_01/Animation/Name.Name")
        Say("       unswap   to put the BlendSpace back")
        return
    end
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end

    local node = Try(function() return instance[CUSTOM_BS_NODE] end)
    if node == nil then Say(CUSTOM_BS_NODE .. " not found") return end

    local space = Playback.GetBlendSpace(node)
    if not IsLive(space) then
        Say("node has no BlendSpace assigned; nothing to swap into")
        return
    end

    local ok, err = Playback.SwapBlendSpace(space, path)
    Say(string.format("swap %s -> %s", path, ok and "ok" or tostring(err)))
    if ok then
        Say("hold customanimupper 1.0 to blend it in, then measure")
    end
end

function Commands.unswap()
    local restored = Playback.RestoreAllBlendSpaces()
    Say(string.format("restored %s BlendSpace(s)", tostring(restored)))
end

function Commands.clear()
    Holds = {}
    Try(Playback.RestoreAllBlendSpaces)
    Restore()
    Say("node restored, pose and holds dropped")
end

function Commands.exec(...)
    local command = table.concat({ ... }, " ")
    if command == "" then Say("usage: exec <console command>") return end
    local controller = Try(FindFirstOf, "SBPlayerController")
        or Try(FindFirstOf, "PlayerController")
    local kismet = Try(StaticFindObject,
        "/Script/Engine.Default__KismetSystemLibrary")
    if not IsLive(controller) or not IsLive(kismet) then
        Say("no controller or kismet library")
        return
    end
    local world = Try(function() return controller:GetWorld() end)
    local ok = pcall(function()
        kismet:ExecuteConsoleCommand(world, command, controller)
    end)
    -- The return value is worthless: ConsoleCommand reports true for commands
    -- that do not exist. Only an observed change means anything.
    Say(string.format("sent '%s' (%s). The return value proves nothing; "
        .. "measure the effect.", command, ok and "no error" or "threw"))
end

-- ------------------------------------------------------------------- loop

local LastSeq = nil

local function Tick()
    local file = io.open(CmdFile, "r")
    if not file then return end
    local line = file:read("*l")
    file:close()
    if not line or line == "" then return end

    local seq, rest = line:match("^(%S+)%s*(.*)$")
    if not seq or seq == LastSeq then return end
    LastSeq = seq

    local parts = {}
    for word in (rest or ""):gmatch("%S+") do parts[#parts + 1] = word end
    local name = table.remove(parts, 1)

    if not name then Flush(seq) return end
    local handler = Commands[name:lower()]
    if not handler then
        Say("unknown command: " .. name)
        Commands.help()
    else
        local ok, err = pcall(handler, table.unpack(parts))
        if not ok then Say("command threw: " .. tostring(err)) end
    end
    Flush(seq)
end

local boot = io.open(OutFile, "w")
if boot then
    boot:write("seq=boot\nSBLove live console ready\n")
    boot:write("write '<seq> <command>' to ue4ss/SBLove_cmd.txt\n")
    boot:close()
end

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)

pcall(RegisterOnUnloadCallback or function() end, function()
    Try(Restore)
end)
