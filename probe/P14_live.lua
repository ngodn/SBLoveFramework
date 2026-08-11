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
      reroot <bone>                 re-point the ONE KawaiiPhysics node at
                                    another chain: the only collider we have
      surface <bone> [dx dy dz]     nearest point on HER BODY's physics asset,
                                    so contact follows the loaded mesh instead
                                    of a hardcoded offset (CNS bodies differ)
      idleswap <animPath>           swap ONLY the idle samples of the live
                                    locomotion BlendSpace (keeps walk/run)
      idleunswap                    put those samples back
      jiggle <match> <stiff> <damp>  retune spring chains: the game's own
                                    breast physics, and writes to it persist
      springs                       every spring chain and its live values
      physics                       which physics node drives which bone
      colliders                     KawaiiPhysics collision volumes
      bind <kind> <i> <bone> <r>    bind a volume to a bone: the squish
      unbind                        put borrowed volumes back

    mode:  0 ignore, 1 replace, 2 additive        space: 0 world, 1 component,
                                                         2 parent, 3 bone

    SAFETY

    `clear` runs on unload too. The borrowed ModifyBone node is a foot
    correction the game drives itself, so leaving it repointed means Eve's toe
    correction keeps landing on her forearm for the rest of the session.
--]]

local Actors   = require("actors")
local Playback = require("playback")
local Contact  = require("contact")

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
--- Contact displacement on the SAME node, held by native alongside the
--- rotation. mode 0 (BMM_Ignore) means native skips it entirely, so this costs
--- nothing until a push is actually asked for. Space 1 is component space: a
--- push into flesh is a direction on her body, and bone space would rotate it
--- with the bone -- which for a spring-driven breast bone means the push
--- direction wobbles with the jiggle it is meant to be deforming.
local Push = { x = 0, y = 0, z = 0, mode = 0, space = 1 }

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
    -- Written only when asked for, so the native parser's default of
    -- BMM_Ignore stands and no existing caller silently gains a translation.
    if Push.mode ~= 0 then
        file:write(string.format("push=%.3f %.3f %.3f mode=%d space=%d\n",
            Push.x, Push.y, Push.z, Push.mode, Push.space))
    end
    for off, entry in pairs(Holds) do
        file:write(string.format("hold=0x%X %.4f %d\n", off, entry.value,
            entry.width or 4))
    end
    file:close()
    return true
end

--- Anything borrowed that must be given back on unload. A BlendSpace sample and
--- a KawaiiPhysics collision volume are both SHARED asset state: one left
--- pointing at the wrong animation or the wrong bone stays wrong for the rest
--- of the session, exactly like the borrowed ModifyBone node below.
local Undo = {}

local function Restore()
    for i = #Undo, 1, -1 do
        pcall(Undo[i])
        Undo[i] = nil
    end
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
    Say("reroot <bone> | surface <bone> [dx dy dz] | idleswap <path> | idleunswap | jiggle <match> <stiff> <damp> | springs | physics | colliders | bind <spherical|capsule> <i> <bone> <radius> | unbind")
    Say("pick <NodeName> | bone <BoneName> | pose <p> <y> <r> [mode] [space]")
    Say("push <x> <y> <z> [mode] [space] | modbones | modbone <0-6> <bone> [dx dy dz]")
    Say("alpha <v> | hold <name|0xOFF> <v> | holds | clear | exec <cmd>")
    Say("swap <animPath> | unswap    upper-body custom slot content")
    Say("asset <objectPath>          read an AnimSequence's properties")
    Say("live [minWeight]            BlendSpaces in use and their animations")
    Say("animaddr <objectPath>       address of a loaded AnimSequence")
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

--- at <bone> [bone ...]   several bones, ALL SAMPLED IN THE SAME FRAME
---
--- WHY THIS EXISTS, and it is a correctness fix rather than a convenience:
---
--- `bones <filter>` reads everything it matches inside one command, so those
--- positions are consistent with each other. But a caller needing bones from
--- several different filters had to issue several commands, and each one is a
--- separate round trip that lands on a DIFFERENT FRAME.
---
--- ./magnet was doing exactly that -- up to eight calls for her torso and one
--- more for the arm -- and then computing distances between them. While she
--- stands still that is harmless. While she MOVES it is nonsense: her torso
--- sampled at one moment and her hand at another are metres apart in world
--- space, and the arithmetic cannot tell that from a badly posed arm.
---
--- Measured, from a solve in Matrix_XI: roughly one iteration in three came
--- back with the palm 17 to 31 cm clear of EVERY collision capsule, and misses
--- of 25 to 48 cm on angles that were nearly correct. Those were not bad poses,
--- they were bones from different instants compared against each other. In the
--- Lobby, where she stands still, the same code looked fine.
---
--- The truncation in `bones` is also why this takes a list rather than a wider
--- filter: it stops at 60 matches, and she has far more bones than that.
function Commands.at(...)
    local mesh = Mesh()
    if not IsLive(mesh) then Say("no mesh") return end
    local names = { ... }
    if #names == 0 then Say("usage: at <bone> [bone ...]") return end
    for i, name in ipairs(names) do
        local x, y, z = Where(name)
        Say(string.format("  [%3d] %-28s %s", i - 1, name,
            x and string.format("(%.1f, %.1f, %.1f)", x, y, z) or "unreadable"))
    end
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

--- push <x> <y> <z> [mode] [space]   displace the picked node's bone
---
--- THE DEFORMATION EXPERIMENT. Route 5, and the first one in the right phase of
--- the frame by construction: FAnimNode_ModifyBone is a skeletal control, so it
--- runs INSIDE evaluation, where the four earlier routes all lost their writes.
---
--- The whole test, once a node is picked and pointed at a breast bone:
---
---     pick AnimGraphNode_ModifyBone     free: alpha 0.00 on Bip001-R-Toe0
---     bone Ab-R-Breast
---     push 0 -3 0
---
--- AnimGraphNode_ModifyBone (+0x10408) and AnimGraphNode_ModifyBone_1
--- (+0x10300) are both idle at alpha 0 on toe bones, and both sit immediately
--- before AnimGraphNode_SpringBone_3 (+0x10598), which is her breast physics.
--- A ModifyBone evaluating after that spring adds contact displacement on top
--- of the jiggle instead of fighting it, which is what a squish is.
---
--- WHAT TO WATCH FOR, because "it wrote" is not "it worked": BoneToModify is an
--- FBoneReference whose only UPROPERTY is BoneName, with the resolved index in
--- transient bytes that InitializeBoneReferences fills at cache-bones time.
--- Rerooting KawaiiPhysics failed exactly there -- the write took, persisted,
--- and did nothing. If the breast does not visibly move, the index is cached
--- and the name alone is not enough. LOOK AT HER; do not read this back.
function Commands.push(x, y, z, mode, space)
    Push.x = tonumber(x) or 0
    Push.y = tonumber(y) or 0
    Push.z = tonumber(z) or 0
    -- Asking for a push at all implies wanting it applied, so default the mode
    -- to additive rather than leaving it at the ignore it starts life with.
    Push.mode  = tonumber(mode)  or (Push.mode ~= 0 and Push.mode or 2)
    Push.space = tonumber(space) or Push.space
    local ok, err = PushPose()
    Say(string.format("push (%.2f, %.2f, %.2f) mode %d space %d on %s -> %s",
        Push.x, Push.y, Push.z, Push.mode, Push.space, Picked,
        ok and "handed to native" or tostring(err)))
    Say("  look at her. A write that lands and does nothing looks identical")
    Say("  to one that worked, if you only read the value back.")
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

--- reroot <bone>                  re-point the KawaiiPhysics node at another chain
---
--- THE IDEA: Eve has exactly ONE KawaiiPhysics node and it is the only thing in
--- her graph that can collide. It roots on Ab-TL-HairB01, so it simulates her
--- ponytail. Her breasts are on AnimGraphNode_SpringBone_3, and spring nodes
--- have no collision fields at all.
---
--- KawaiiPhysics simulates every DESCENDANT of RootBone. So pointing it at
--- Dm-R-Breast-Point puts the whole breast chain under a simulator that DOES
--- collide, and a sphere bound to Bip001-R-Hand then deforms it. No new node,
--- no physics engine of our own.
---
--- Cost: one node, one chain. Her hair loses its physics while this is set.
--- `reroot Ab-TL-HairB01` puts it back, and unload does it automatically.
---
--- Rooting high (say Bip001-Spine2) would cover breasts AND hair, but every
--- descendant includes both arms, and physics-driven arms would destroy the
--- pose the magnet just solved. The breast chain alone is the useful target.
local rerootOriginal = nil

function Commands.reroot(bone)
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local node = Try(function() return instance["AnimGraphNode_KawaiiPhysics"] end)
    if node == nil then Say("no KawaiiPhysics node") return end

    local current = Try(function() return node.RootBone.BoneName:ToString() end)
    if not bone then
        Say(string.format("  RootBone is %s   (usage: reroot <bone>)", tostring(current)))
        return
    end
    if rerootOriginal == nil then
        rerootOriginal = current
        Undo[#Undo + 1] = function()
            local i = Instance()
            local n = IsLive(i) and Try(function() return i["AnimGraphNode_KawaiiPhysics"] end)
            if n and rerootOriginal then
                pcall(function() n.RootBone.BoneName = FName(rerootOriginal) end)
            end
        end
    end

    local ok = pcall(function() node.RootBone.BoneName = FName(bone) end)
    local after = Try(function() return node.RootBone.BoneName:ToString() end)
    Say(string.format("  RootBone %s -> %s   %s", tostring(current), tostring(bone),
        (ok and after == bone) and "written" or "WRITE DID NOT TAKE"))
    Say("  KawaiiPhysics is a volatile node; if this reverts it needs re-asserting")
end

--- modbones                        survey every ModifyBone node
--- modbone <n> <bone> [dx dy dz]   retarget node n and push the bone
---
--- ROUTE 5 FOR DEFORMATION, and the first one that is in the right phase of the
--- frame by construction rather than by luck.
---
--- The four routes tried before all failed for the same underlying reason: they
--- wrote bone transforms somewhere that animation EVALUATION later overwrote.
--- UE splits the frame into Update and Evaluate; Update runs the event graph and
--- explicitly does not touch bone transforms, Evaluate produces the pose. So a
--- write from a BlueprintUpdateAnimation hook loses every frame, which on screen
--- is indistinguishable from the write not landing at all.
---
--- FAnimNode_ModifyBone is a skeletal control, so it runs INSIDE Evaluate. The
--- native DLL already drives one of these successfully -- it is how the pose
--- hold works -- so the mechanism is proven on screen, and Translation (0x00D8)
--- sits right beside the Rotation (0x00E4) the DLL already writes.
---
--- Eve has SEVEN of them. That matters: SpringBone_3 is her breast physics, and
--- ModifyBone_1 and ModifyBone both sit next to it in the layout. A ModifyBone
--- that evaluates AFTER the spring can add contact displacement on top of the
--- jiggle instead of fighting it, which is exactly what a squish is.
---
--- WHAT THIS IS TESTING, and why a survey comes before any writing: a node in
--- use by the game cannot be borrowed without breaking whatever it does, and a
--- node at Alpha 0 targeting nothing is free. The survey says which is which.
---
--- THE TRAP THIS IS PROBING FOR: BoneToModify is an FBoneReference, whose only
--- UPROPERTY is BoneName -- the resolved index lives in transient bytes that
--- InitializeBoneReferences fills at cache-bones time. Rerooting KawaiiPhysics
--- failed exactly here: the write took, persisted, and did nothing, because the
--- chain was already cached. So expect writing the NAME alone to do nothing,
--- and treat "written" in the output as meaning the property changed, NOT that
--- the engine noticed.
local MODIFY_NODES = {
    "AnimGraphNode_ModifyBone",   "AnimGraphNode_ModifyBone_1",
    "AnimGraphNode_ModifyBone_2", "AnimGraphNode_ModifyBone_3",
    "AnimGraphNode_ModifyBone_4", "AnimGraphNode_ModifyBone_5",
    "AnimGraphNode_ModifyBone_6",
}

local MODE  = { [0] = "ignore", [1] = "replace", [2] = "additive" }
local SPACE = { [0] = "world", [1] = "component", [2] = "parent", [3] = "bone" }

local function vec(v)
    if v == nil then return "?" end
    return string.format("(%.2f, %.2f, %.2f)",
        Number(Try(function() return v.X end), 0),
        Number(Try(function() return v.Y end), 0),
        Number(Try(function() return v.Z end), 0))
end

local function label(tbl, v)
    local n = Number(v, -1)
    return tbl[n] or ("?" .. tostring(v))
end

function Commands.modbones()
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    Say("  node                        bone                  alpha  t-mode     translation")
    for i, name in ipairs(MODIFY_NODES) do
        local node = Try(function() return instance[name] end)
        if node == nil then
            Say(string.format("  [%d] %-24s MISSING", i - 1, name))
        else
            Say(string.format("  [%d] %-24s %-20s %5.2f  %-9s %s  %s/%s",
                i - 1, name:gsub("AnimGraphNode_", ""),
                tostring(Try(function() return node.BoneToModify.BoneName:ToString() end)),
                Number(Try(function() return node.Alpha end), -1),
                label(MODE, Try(function() return node.TranslationMode end)),
                vec(Try(function() return node.Translation end)),
                label(SPACE, Try(function() return node.TranslationSpace end)),
                label(MODE, Try(function() return node.RotationMode end))))
        end
    end
    Say("  -> a node at alpha 0 targeting an unrelated bone is the one to borrow")
end

function Commands.modbone(which, bone, dx, dy, dz)
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local name = MODIFY_NODES[(tonumber(which) or 0) + 1]
    if not name then Say("usage: modbone <0-6> <bone> [dx dy dz]") return end
    local node = Try(function() return instance[name] end)
    if node == nil then Say("no such node: " .. name) return end

    local before = Try(function() return node.BoneToModify.BoneName:ToString() end)
    if not bone then
        Say(string.format("  %s targets %s", name, tostring(before)))
        return
    end

    -- Restore on unload. Borrowing a node the game is using would otherwise
    -- leave her broken until a restart.
    local originalAlpha = Number(Try(function() return node.Alpha end), 0)
    Undo[#Undo + 1] = function()
        local i = Instance()
        local n = IsLive(i) and Try(function() return i[name] end)
        if n then
            pcall(function()
                n.BoneToModify.BoneName = FName(before)
                n.Alpha = originalAlpha
                n.TranslationMode = 0
            end)
        end
    end

    local x, y, z = tonumber(dx) or 0.0, tonumber(dy) or 0.0, tonumber(dz) or 0.0
    local ok = pcall(function()
        node.BoneToModify.BoneName = FName(bone)
        node.Translation = { X = x, Y = y, Z = z }
        node.TranslationMode  = 2      -- BMM_Additive: displace, do not teleport
        node.TranslationSpace = 1      -- BCS_ComponentSpace
        node.Alpha = 1.0
    end)
    local after = Try(function() return node.BoneToModify.BoneName:ToString() end)
    Say(string.format("  %s: %s -> %s  translate (%.2f, %.2f, %.2f)  %s",
        name, tostring(before), tostring(bone), x, y, z,
        (ok and after == bone) and "written" or "WRITE DID NOT TAKE"))
    Say("  -> WRITTEN ONLY MEANS THE PROPERTY CHANGED. Look at her: if the bone")
    Say("     does not move, the index is cached and the name alone is not enough.")
end

--- surface <bone> [dx] [dy] [dz]   nearest point on HER BODY, from a probe point
---
--- WHY THIS EXISTS: a contact offset like "breast bone + (6,-2,9)" is
--- calibrated to ONE body mesh. Outfit mods -- CNS suits especially -- often
--- bundle their own body, with a different bust shape. A hardcoded offset then
--- puts the hand inside her, or floating off her.
---
--- K2_GetClosestPointOnPhysicsAsset queries the physics asset of the mesh that
--- is ACTUALLY LOADED, so the answer follows whatever body is equipped. It also
--- returns the surface NORMAL, which is the direction to push flesh for a
--- squish, and the owning bone, which says whether the hit is really the breast
--- or a rib.
---
--- The probe point is a bone plus an offset in WORLD axes, defaulting to 25 cm
--- in front of the bone so the query starts outside her and finds the front
--- surface rather than something interior.
---
--- CAVEAT: a physics asset is capsules and spheres, not the render mesh, so
--- this is the collision silhouette rather than the skin. It is still derived
--- from the loaded asset instead of guessed, which is the point. If the asset
--- has no body on the breast the returned bone will say so.
function Commands.surface(bone, dx, dy, dz)
    local mesh = Mesh()
    if not IsLive(mesh) then Say("no mesh") return end
    bone = bone or "Ab-R-Breast"

    local bx, by, bz = Where(bone)
    if not bx then Say("no such bone: " .. tostring(bone)) return end
    local px = bx + (tonumber(dx) or 0.0)
    local py = by + (tonumber(dy) or -25.0)     -- default: out in front of her
    local pz = bz + (tonumber(dz) or 0.0)

    Say(string.format("  probe   (%.1f, %.1f, %.1f)   %s + (%.1f, %.1f, %.1f)",
        px, py, pz, bone, px - bx, py - by, pz - bz))

    -- SELF-DIAGNOSING. UE4SS returns a UFunction's out-parameters as extra
    -- return values, but the exact shape is not documented for this build and
    -- nothing else in this codebase calls one. Guessing the arity costs a game
    -- restart per guess, so capture EVERYTHING and describe it instead.
    local function describe(v)
        local t = type(v)
        if t == "userdata" or t == "table" then
            local x = Try(function() return v.X end)
            if type(x) == "number" then
                return string.format("vector(%.2f, %.2f, %.2f)", x,
                    Number(Try(function() return v.Y end), 0),
                    Number(Try(function() return v.Z end), 0))
            end
            local s = Try(function() return v:ToString() end)
            if s then return "name/obj(" .. tostring(s) .. ")" end
            return t
        end
        return t .. "(" .. tostring(v) .. ")"
    end

    -- UE4SS builds disagree on how a UFunction's out-parameters are passed:
    -- some take only the inputs and return the rest, others want a placeholder
    -- argument per out-param. Guessing costs a game restart each time, so every
    -- convention is tried in ONE pass and the working one reports itself.
    local pos = { X = px, Y = py, Z = pz }
    local zero = { X = 0.0, Y = 0.0, Z = 0.0 }
    local attempts = {
        { "K2 inputs only",      function() return mesh:K2_GetClosestPointOnPhysicsAsset(pos) end },
        { "K2 with out slots",   function() return mesh:K2_GetClosestPointOnPhysicsAsset(pos, zero, zero, FName(""), 0.0) end },
        { "K2 out table",        function() return mesh:K2_GetClosestPointOnPhysicsAsset(pos, {}, {}, {}, {}) end },
        { "Collision inputs",    function() return mesh:GetClosestPointOnCollision(pos, FName(bone)) end },
        { "Collision out slot",  function() return mesh:GetClosestPointOnCollision(pos, zero, FName(bone)) end },
    }
    for _, a in ipairs(attempts) do
        local fn, call = a[1], a[2]
        local packed = table.pack(pcall(call))
        if not packed[1] then
            Say(string.format("  %-20s threw: %s", fn,
                tostring(packed[2]):sub(1, 60)))
        else
            Say(string.format("  %s returned %d value(s):", fn, packed.n - 1))
            for i = 2, packed.n do
                Say(string.format("    [%d] %s", i - 1, describe(packed[i])))
            end
        end
    end
    Say("  -> a vector here is the surface point; the second is the normal.")
end

--- idleswap <animPath> [matchName]   replace only the IDLE samples of the live
---                                   locomotion BlendSpace
---
--- WHY: Proto_Idle is what plays, and it has NO breast tracks -- 139 tracks,
--- not one of them Ab-*-Breast -- so it cannot carry a contact deformation at
--- all. Proto_Idle_Social has all eight (204-211) alongside the arm, and is
--- already loaded, but nothing plays it.
---
--- The live blendspace is IdleRun_BS_Peaceful2D_Roll on
--- SBAnimGraphNode_BlendSpacePlayer_2 at weight 1.00, and its samples 1, 14 and
--- 15 are Proto_Idle while the rest are walk / run / sprint / roll.
---
--- Playback.SwapBlendSpace rewrites EVERY sample, which would make her run and
--- sprint play the idle too. This touches only the samples whose current
--- animation matches, so locomotion survives.
---
--- A BlendSpace is a SHARED asset: originals are recorded here and put back by
--- `idleunswap`, and one left edited stays wrong until the level reloads.
local idleSwapRecord = {}

function Commands.idleswap(path, matchName)
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    if not path then
        Say("usage: idleswap /Game/.../Proto_Idle_Social.Proto_Idle_Social [matchName]")
        return
    end
    matchName = matchName or "Proto_Idle"

    local live = Playback.FindLiveBlendSpaces(instance, 0.05)
    if #live == 0 then Say("no live blend space") return end
    local space = live[1].blendSpace
    Say(string.format("  blend space: %s (weight %.2f)", tostring(live[1].name),
        live[1].weight))

    local anim = Try(function() return StaticFindObject(path) end)
    if not IsLive(anim) and type(LoadAsset) == "function" then
        anim = Try(function() return LoadAsset(path) end)
    end
    if not IsLive(anim) then Say("  could not load " .. path) return end

    local samples = Try(function() return space.SampleData end)
    local count = samples and Try(function() return samples:GetArrayNum() end)
    if type(count) ~= "number" then Say("  no samples") return end

    local swapped = 0
    for i = 1, count do
        local sample = Try(function() return samples[i] end)
        local cur = sample and Try(function() return sample.Animation end)
        local name = IsLive(cur) and Try(function() return cur:GetFullName() end) or ""
        if name:find(matchName, 1, true) then
            if #idleSwapRecord == 0 then
                Undo[#Undo + 1] = function() Commands.idleunswap() end
            end
            idleSwapRecord[#idleSwapRecord + 1] = { space = space, index = i, anim = cur }
            Try(function() sample.Animation = anim end)
            swapped = swapped + 1
        end
    end
    Say(string.format("  swapped %d of %d samples matching '%s'", swapped, count, matchName))
    if swapped == 0 then Say("  nothing matched; run `live` to see sample names") end
end

--- idleunswap                      put the borrowed idle samples back
function Commands.idleunswap()
    local n = 0
    for _, r in ipairs(idleSwapRecord) do
        if IsLive(r.space) then
            local samples = Try(function() return r.space.SampleData end)
            local sample = samples and Try(function() return samples[r.index] end)
            if sample ~= nil and IsLive(r.anim) then
                Try(function() sample.Animation = r.anim end)
                n = n + 1
            end
        end
    end
    idleSwapRecord = {}
    Say(string.format("  restored %d idle sample(s)", n))
end

--- jiggle <match> <stiffness> <damping>   retune spring chains, live
---
--- This is the game's OWN breast physics. AnimGraphNode_SpringBone_3 drives
--- Ab-R-Breast, and the chain lagging behind her torso IS the jiggle.
---
--- Spring nodes are the reliable half of the control surface: 26 of the 27 have
--- no exposed pins, so writes to them PERSIST. KawaiiPhysics does not -- the
--- graph copies it from anim-BP variables every tick and overwrites anything
--- written.
---
--- Scales are relative to the shipped values, captured on first use and put
--- back by `springs restore`, so the relative tuning between chains survives.
---
---   jiggle Breast 0.5 0.6      looser and less damped: more overshoot
---   jiggle R 1.0 1.0           put the right side back
---
--- LOWER stiffness = looser and more sway. LOWER damping = acceleration shows
--- more, so it overshoots further.
function Commands.jiggle(match, stiffness, damping)
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    if not match then
        Say("usage: jiggle <bone-substring|L|R> <stiffnessScale> <dampingScale>")
        return
    end
    local Physics = require("physics")
    local ok, n = Physics.ApplyToChains(instance, match, {
        Stiffness = tonumber(stiffness) or 1.0,
        Damping   = tonumber(damping)   or 1.0,
    })
    Say(ok and string.format("  scaled %s field(s) on chains matching '%s'",
                             tostring(n), match)
           or string.format("  failed: %s", tostring(n)))
    if ok and n == 0 then
        Say("  nothing matched -- chain bones are named like Ab-R-Breast")
    end
end

--- springs                        every chain, its bone, and its live values
function Commands.springs()
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local Physics = require("physics")
    Say(Physics.Describe(instance))
end

--- physics                        which node drives which bone
---
--- THE QUESTION THIS ANSWERS: can the breast be squished by collision at all?
---
--- Only FAnimNode_KawaiiPhysics carries SphericalLimits / CapsuleLimits /
--- PlanarLimits. FAnimNode_SpringBone has no collision fields whatsoever --
--- just the bone, a displacement clamp and velocity history. So a chain on a
--- spring node CANNOT be pushed aside by a collider, no matter what is bound.
---
--- Eve has 27 spring chains and exactly ONE KawaiiPhysics node, and she has
--- very large ponytails. If that one node roots on hair, contact deformation of
--- the breast needs a different mechanism entirely.
function Commands.physics()
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end

    local node = Try(function() return instance["AnimGraphNode_KawaiiPhysics"] end)
    local root = node and Try(function() return node.RootBone.BoneName:ToString() end)
    Say(string.format("  KawaiiPhysics root: %s   (the only node that can collide)",
        tostring(root or "?")))

    local Physics = require("physics")
    for _, entry in ipairs(Physics.MapChains(instance) or {}) do
        Say(string.format("  spring %-28s -> %s", entry.property, entry.bone))
    end
end

--- colliders                      list the KawaiiPhysics collision volumes
---
--- The squish does not have to be animated. KawaiiPhysics already pushes its
--- chain out of any collision volume, every frame, so binding a volume to the
--- HAND makes the breast deform on contact for free. Displacing the breast bone
--- by hand would fight the physics rather than use it.
function Commands.colliders()
    local inst = Instance()
    if not IsLive(inst) then Say("no anim instance") return end
    Say(Contact.Describe(inst))
end

--- bind <kind> <index> <bone> <radius> [ox] [oy] [oz]
---
--- Take over an EXISTING collision limit rather than growing the array: a
--- resized TArray on a live anim node is a far bigger change than an edited
--- entry, and the game already ships several volumes.
---
---   bind spherical 1 Bip001-R-Hand 7
function Commands.bind(kind, index, bone, radius, ox, oy, oz)
    local inst = Instance()
    if not IsLive(inst) then Say("no anim instance") return end
    if not (kind and index and bone and radius) then
        Say("usage: bind <spherical|capsule> <index> <bone> <radius> [ox oy oz]")
        return
    end
    local off = { X = tonumber(ox) or 0.0, Y = tonumber(oy) or 0.0, Z = tonumber(oz) or 0.0 }
    local ok, err = Contact.BindToBone(inst, kind, tonumber(index), bone,
                                       tonumber(radius), off)
    Say(ok and string.format("  bound %s limit %s to %s, radius %s",
                             kind, index, bone, radius)
           or string.format("  bind failed: %s", tostring(err)))
end

--- unbind                          put every borrowed collision volume back
---
--- Same reason `clear` exists: a volume left bound to the wrong bone stays
--- wrong for the rest of the session, and these are shared anim-node state.
function Commands.unbind()
    local inst = Instance()
    if not IsLive(inst) then Say("no anim instance") return end
    local n = Contact.Release(inst)
    Say(string.format("  released %s collision volume(s)", tostring(n or 0)))
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

--- asset <objectPath>   read an AnimSequence's properties from the running game
---
--- The point is pak overrides. If a mod pak replaces an asset, the game loads
--- OUR file, and a property we deliberately changed reads back changed. That
--- answers "did the pak mount" separately from "does the animation look
--- different", which otherwise look identical when the asset is one the game
--- never plays.
---
--- LoadAsset is safe on an AnimSequence. It is NOT safe on a character
--- Blueprint, which crashed the game twice earlier in this project.
function Commands.asset(path)
    if not path then
        Say("usage: asset /Game/Art/Character/PC/CH_P_EVE_01/Animation/Name.Name")
        return
    end
    local object = Try(StaticFindObject, path)
    if not IsLive(object) then
        Try(LoadAsset, path)
        object = Try(StaticFindObject, path)
    end
    if not IsLive(object) then
        Say("not found or not loaded: " .. path)
        return
    end

    Say("found " .. path)
    for _, prop in ipairs({ "SequenceLength", "NumFrames", "RateScale" }) do
        local value = Try(function() return object[prop] end)
        Say(string.format("  %-16s %s", prop, tostring(value)))
    end
end

--- live [minWeight]   which BlendSpaces are actually driving her, and what
--- animations their samples point at.
---
--- This is how to find the animation the game really plays. Editing Proto_Walk
--- changed nothing on screen because it is a prototype asset nothing uses; the
--- pak was loading correctly the whole time. The samples of a live BlendSpace
--- name the animations that are genuinely in use.
function Commands.live(minWeight)
    local instance = Instance()
    if not IsLive(instance) then Say("no anim instance") return end
    local floor = tonumber(minWeight) or 0.05

    local found = 0
    for _, prop in ipairs(Playback.DiscoverNodes(instance)) do
        local node = Try(function() return instance[prop] end)
        if node ~= nil then
            local weight = Number(Try(function() return node.BlendWeight end), 0)
            if weight >= floor then
                local space = Playback.GetBlendSpace(node)
                local seq   = Try(function() return node.Sequence end)

                if IsLive(space) then
                    found = found + 1
                    Say(string.format("%s  weight %.2f  BlendSpace %s", prop, weight,
                        tostring(Try(function() return space:GetFullName() end))))
                    local samples = Try(function() return space.SampleData end)
                    if samples then
                        for i = 1, 18 do
                            local anim = Try(function() return samples[i].Animation end)
                            if IsLive(anim) then
                                Say("    sample " .. i .. ": " ..
                                    tostring(Try(function() return anim:GetFullName() end)))
                            end
                        end
                    end
                elseif IsLive(seq) then
                    found = found + 1
                    Say(string.format("%s  weight %.2f  Sequence %s", prop, weight,
                        tostring(Try(function() return seq:GetFullName() end))))
                end
            end
        end
    end
    if found == 0 then Say("nothing live above weight " .. floor) end
end

--- animaddr <objectPath>   address of a loaded AnimSequence
---
--- Only Lua can resolve a UObject by path, and only native can write into the
--- compressed buffer it owns. This hands the address across so an animation can
--- be edited in memory, which removes the repack-and-restart cycle entirely.
function Commands.animaddr(path)
    if not path then Say("usage: animaddr <objectPath>") return end
    local object = Try(StaticFindObject, path)
    if not IsLive(object) then
        Try(LoadAsset, path)
        object = Try(StaticFindObject, path)
    end
    if not IsLive(object) then Say("not loaded: " .. path) return end
    local addr = Try(function() return object:GetAddress() end)
    if not addr then Say("GetAddress failed") return end
    Say(string.format("object=0x%X", addr))
    Say(string.format("  %s", path))
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
