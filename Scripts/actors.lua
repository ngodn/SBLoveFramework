--[[
    SBLoveFramework -- actors
    ------------------------------------------------------------------
    Resolving characters, holding them still, and placing them relative to each
    other.

    RESOLUTION

    Classes come from the game's own CharacterAppearanceTable, read offline from
    the shipped paks (see docs/08-character-map.md). That table has 212 rows, so
    any character in the game can be added here without guesswork. The runtime
    class is the asset name with "_C" appended, because these are Blueprint
    generated classes.

    Guessing from the character's name does not work: Orcal's blueprint is
    CH_NPC_XionElder_Blueprint, and Raven's is CH_M_NA_53_Blueprint.

    PLACEMENT

    K2_TeleportTo holds. Measured: +150 requested on X, +150.0 held across three
    samples with 0.0 horizontal drift. The movement component does not fight it,
    so alignment does not need the character neutralised first.

    Vertical is different. In testing a character placed over a gap simply fell,
    accelerating, which an earlier probe misread as the placement being undone.
    Horizontal and vertical drift are different failures and are never collapsed
    into one number here.

    NEUTRALISING

    Placement holding is not the same as the character staying put once the
    player pushes a stick or the AI decides to walk somewhere. Scenes neutralise
    input and AI first, and every change is recorded so it can be undone.

    RESTORE

    Nothing is mutated without a recorded restore. A character left with blocked
    input or a foreign transform stays broken until the level reloads, and the
    player will not connect it to this mod.
--]]

local Actors = {}

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

Actors.Try, Actors.IsLive, Actors.FullName = Try, IsLive, FullName

-- ---------------------------------------------------------------- registry

--- From CharacterAppearanceTable.CharacterAssetPath, "_C" appended.
--- Adam and Lily independently match what CNS hardcodes, which is the control
--- that says this method is right.
Actors.CHARACTERS = {
    Eve        = { player = true },
    Adam       = { class = "CH_NPC_Adam_01_Blueprint_C"  },
    Lily       = { class = "CH_NPC_01_Blueprint_C"       },
    Raven      = { class = "CH_M_NA_53_Blueprint_C"      },
    RavenBeast = { class = "CH_M_NA_42_Blueprint_C"      },
    Tachy      = { class = "CH_NPC_TachyNPC_Blueprint_C" },
    Orcal      = { class = "CH_NPC_XionElder_Blueprint_C"},
    Drone      = { class = "CH_Drone_BP_C"               },
}

--- Raven is a boss, not a standing NPC, so she only exists during her
--- encounters. "Not present" is a normal answer for her and callers should say
--- so rather than treat it as an error.
Actors.ENCOUNTER_ONLY = { Raven = true, RavenBeast = true, Tachy = true }

function Actors.GetPlayerPawn()
    local controller = Try(FindFirstOf, "SBPlayerController")
    if not IsLive(controller) then return nil end
    local pawn = Try(function() return controller.Pawn end)
    if not IsLive(pawn) then
        pawn = Try(function() return controller:K2_GetPawn() end)
    end
    return IsLive(pawn) and pawn or nil
end

--- True only in real gameplay. The main menu builds a fully valid player pawn
--- in a level named Lobby where every check passes and every answer is
--- worthless; three probes were wasted on it before this became a gate rather
--- than a habit.
function Actors.InGameplay()
    local pawn = Actors.GetPlayerPawn()
    if not pawn then return nil, "no player pawn yet" end
    if FullName(pawn):lower():find("lobby", 1, true) then
        return nil, "in Lobby (main menu), waiting for a loaded save"
    end
    return pawn
end

--- Resolve a character by name. Returns actor, or nil plus a reason.
---
--- When several instances exist (streamed duplicates, variants) the nearest to
--- the player is taken, which is what CNS does and is almost always the one the
--- user means.
function Actors.Resolve(name)
    local entry = Actors.CHARACTERS[name]
    if not entry then return nil, "unknown character: " .. tostring(name) end

    if entry.player then
        local pawn = Actors.GetPlayerPawn()
        if not IsLive(pawn) then return nil, "player pawn not available" end
        return pawn
    end

    local list = Try(FindAllOf, entry.class)
    if not list then
        return nil, Actors.ENCOUNTER_ONLY[name]
            and (name .. " is not in the world (boss, encounter only)")
            or  (name .. " is not in the world")
    end

    local player = Actors.GetPlayerPawn()
    local best, bestDistance = nil, math.huge

    for _, candidate in ipairs(list) do
        if IsLive(candidate) then
            local distance = IsLive(player)
                and Try(function() return player:GetDistanceTo(candidate) end)
                or 0
            if type(distance) ~= "number" then distance = 0 end
            if distance < bestDistance then best, bestDistance = candidate, distance end
        end
    end

    if not best then return nil, name .. " found no live instance" end
    return best
end

--- Is this class a humanoid character rather than a creature?
---
--- The content tree splits them cleanly and the class names follow it:
---
---     CH_P_*     player characters      /Art/Character/PC/
---     CH_NPC_*   named and generic NPCs /Art/Character/NPC/
---     CH_M_*     monsters               /Art/Character/Monster/
---
--- Monsters are excluded by default. They satisfy every technical requirement
--- for a scene partner, which is why they were useful while testing, but they
--- are not what this framework is for.
---
--- The exception is deliberate: a few humanoid bosses live under Monster,
--- Raven being CH_M_NA_53. Those are reachable by name through the registry
--- above, which is the right way to ask for one, rather than by sweeping up
--- whatever creature happens to be nearby.
function Actors.IsHumanoidClass(className)
    if type(className) ~= "string" then return false end
    return className:find("^CH_NPC_") ~= nil or className:find("^CH_P_") ~= nil
end

--- Cached per actor. The answer cannot change while an actor lives, and the
--- check was previously being redone for every character on every tick.
local humanoidCache = setmetatable({}, { __mode = "k" })

--- A humanoid rig is large. Eve's skeleton has 182 bones, measured. A drone or
--- a prop has a handful. That single number separates them, and unlike a name
--- it cannot go out of date.
local MIN_HUMANOID_BONES = 30

--- Does this actor have a human skeleton?
---
--- The class-name rule is not enough, and the game says so. CH_NPC_05_Var01
--- passes it and is N_InitDrone: the whole CH_NPC_05 family is drones,
--- N_TumblerDrone, N_DataDrone, N_Digger and friends, all filed under NPC.
--- A name-based filter needs a blacklist that grows forever.
---
--- Asking the skeleton is the real test, and it cannot go stale: a character
--- with a head and hands is a person, whatever its class is called.
---
--- Bone count alone, deliberately.
---
--- An earlier version also probed for named bones with GetBoneIndex, building
--- an FName and calling into the mesh eight times per character per tick. That
--- crashed the game while a save was loading, when meshes are still streaming
--- and are not ready to answer. One integer read is enough to tell a person
--- from a drone, and it costs a fraction as much.
---
--- The mesh must have its SkeletalMesh before anything is asked of it. Without
--- that check the component exists but has nothing behind it, which is exactly
--- the state it is in mid-stream.
function Actors.IsHumanoidActor(actor)
    if not IsLive(actor) then return false end

    local cached = humanoidCache[actor]
    if cached ~= nil then return cached end

    local mesh = Try(function() return actor:GetSBSkeletalMeshComponent(0) end)
    if not IsLive(mesh) then return false end

    -- Not cached: a mesh still streaming will have one shortly, and caching
    -- "no" now would make that permanent.
    local skeletal = Try(function() return mesh.SkeletalMesh end)
    if not IsLive(skeletal) then return false end

    local bones = Try(function() return mesh:GetNumBones() end)
    if type(bones) ~= "number" then return false end

    local humanoid = bones >= MIN_HUMANOID_BONES
    humanoidCache[actor] = humanoid
    return humanoid
end

--- Humanoid characters near the player, nearest first.
---
--- FindAllOf on the C++ base class returns every derived instance, so this sees
--- every character the level has loaded, then filters. The player is excluded,
--- and so are creatures unless opts.includeCreatures is set.
---
--- The named registry above only knows characters worth naming, and those are
--- not loaded everywhere: Adam and Lily live in Xion and story areas. This is
--- how a scene finds a partner the registry does not list, such as a generic
--- Xion citizen.
function Actors.NearbyCharacters(maxDistance, opts)
    maxDistance = maxDistance or 3000.0
    opts = opts or {}

    local player = Actors.GetPlayerPawn()
    if not IsLive(player) then return {} end

    local all = Try(FindAllOf, "SBCharacter")
    if not all then return {} end

    -- Compare by object path, NOT with ~=. UE4SS hands back a distinct Lua
    -- wrapper each time it exposes the same UObject, so identity comparison
    -- silently fails. A first version used ~= and duly offered Eve herself as
    -- a partner, at a distance of 0 cm.
    local playerPath = FullName(player)

    local found = {}
    for _, candidate in ipairs(all) do
        if IsLive(candidate) and FullName(candidate) ~= playerPath then
            local distance = Try(function()
                return player:GetDistanceTo(candidate) end)
            if type(distance) == "number" and distance <= maxDistance then
                local class = Try(function()
                    return candidate:GetClass():GetFName():ToString() end)
                -- Class name first because it is free, then the skeleton,
                -- which is what actually decides. A drone passes the name test
                -- and fails the skeleton test, which is the whole point.
                local humanoid = Actors.IsHumanoidClass(class)
                    and Actors.IsHumanoidActor(candidate)
                if humanoid or opts.includeCreatures then
                    found[#found + 1] = {
                        actor    = candidate,
                        distance = distance,
                        class    = class or "?",
                        humanoid = humanoid,
                    }
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.distance < b.distance end)
    return found
end

--- Every character currently resolvable, for a UI list.
function Actors.Present()
    local found = {}
    for name in pairs(Actors.CHARACTERS) do
        local actor = Actors.Resolve(name)
        if actor then found[#found + 1] = { name = name, actor = actor } end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
    return found
end

-- --------------------------------------------------------------- transforms

function Actors.GetLocation(actor)
    local v = Try(function() return actor:K2_GetActorLocation() end)
    if not v then return nil end
    local x = Try(function() return v.X end)
    if not x then return nil end
    return { X = x, Y = Try(function() return v.Y end),
                    Z = Try(function() return v.Z end) }
end

function Actors.GetRotation(actor)
    local r = Try(function() return actor:K2_GetActorRotation() end)
    if not r then return nil end
    local yaw = Try(function() return r.Yaw end)
    if not yaw then return nil end
    return { Pitch = Try(function() return r.Pitch end) or 0.0,
             Yaw   = yaw,
             Roll  = Try(function() return r.Roll end) or 0.0 }
end

--- Teleport rather than sweep, so the character is not blocked by geometry it
--- would collide with on the way.
function Actors.Place(actor, location, rotation)
    if not IsLive(actor) then return false end
    local target = location or Actors.GetLocation(actor)
    local facing = rotation or Actors.GetRotation(actor)
    if not target or not facing then return false end
    return Try(function() return actor:K2_TeleportTo(target, facing) end) == true
end

-- ---------------------------------------------------------------- alignment

local function Radians(degrees) return degrees * math.pi / 180.0 end

--- Place `partner` relative to `anchor`, in the anchor's own frame.
---
--- offset is {forward, right, up} in centimetres, measured from the anchor.
--- Expressing it in the anchor's frame rather than world space is what lets one
--- authored offset work regardless of which way the pair happens to be facing.
---
--- yaw is the partner's facing relative to the anchor. 180 makes them face each
--- other, 0 makes them face the same way.
---
--- These numbers belong to the animation and come from its addon config. They
--- are not computed: two clips authored separately will never line up from a
--- formula, so whoever made the animation records the offset that fits it.
function Actors.Align(anchor, partner, offset, yaw)
    if not IsLive(anchor) or not IsLive(partner) then return false end

    local origin = Actors.GetLocation(anchor)
    local facing = Actors.GetRotation(anchor)
    if not origin or not facing then return false end

    offset = offset or {}
    local forward = offset.forward or 0.0
    local right   = offset.right   or 0.0
    local up      = offset.up      or 0.0

    local theta = Radians(facing.Yaw)
    local cos, sin = math.cos(theta), math.sin(theta)

    -- UE: +X is forward, +Y is right, yaw is clockwise about Z.
    local target = {
        X = origin.X + forward * cos - right * sin,
        Y = origin.Y + forward * sin + right * cos,
        Z = origin.Z + up,
    }

    local rotation = {
        Pitch = 0.0,
        Yaw   = facing.Yaw + (yaw or 180.0),
        Roll  = 0.0,
    }

    return Actors.Place(partner, target, rotation)
end

--- Uniform scale, for height matching between mismatched characters.
function Actors.SetScale(actor, scale)
    if not IsLive(actor) then return false end
    return Try(function()
        actor:SetActorScale3D({ X = scale, Y = scale, Z = scale })
        return true
    end) ~= nil
end

-- ------------------------------------------------------- capture / restore

--- Everything a scene changes, per actor, so it can all be put back.
local captured = setmetatable({}, { __mode = "k" })

function Actors.Capture(actor)
    if not IsLive(actor) then return nil end
    if captured[actor] then return captured[actor] end

    captured[actor] = {
        location = Actors.GetLocation(actor),
        rotation = Actors.GetRotation(actor),
        ignoringMoveInput = Try(function()
            return actor:IsMoveInputIgnored() end),
    }
    return captured[actor]
end

--- Hold the character still for the duration of a scene.
---
--- Placement alone holds, but nothing stops the player pushing a stick or an AI
--- deciding to walk off. SetIgnoreMoveInput was verified working in an earlier
--- project by reading IsMoveInputIgnored back.
function Actors.Neutralise(actor)
    if not IsLive(actor) then return false end
    Actors.Capture(actor)

    local controller = Try(function() return actor:GetController() end)
    if IsLive(controller) then
        Try(function() controller:SetIgnoreMoveInput(true) end)
        Try(function() controller:SetIgnoreLookInput(true) end)
    end
    Try(function() actor:SetMoveInputBlock(true) end)
    return true
end

function Actors.Release(actor)
    if not IsLive(actor) then return false end
    local controller = Try(function() return actor:GetController() end)
    if IsLive(controller) then
        Try(function() controller:SetIgnoreMoveInput(false) end)
        Try(function() controller:SetIgnoreLookInput(false) end)
    end
    Try(function() actor:SetMoveInputBlock(false) end)
    return true
end

--- Put an actor back exactly as it was found, including where it stood.
function Actors.Restore(actor)
    local state = captured[actor]
    if not state or not IsLive(actor) then return false end

    Actors.Release(actor)
    Actors.SetScale(actor, 1.0)
    if state.location and state.rotation then
        Actors.Place(actor, state.location, state.rotation)
    end

    captured[actor] = nil
    return true
end

function Actors.RestoreAll()
    local count = 0
    for actor in pairs(captured) do
        if IsLive(actor) and Actors.Restore(actor) then count = count + 1 end
    end
    return count
end

return Actors
