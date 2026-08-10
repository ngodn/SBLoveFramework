--[[
    SBLoveFramework -- summoning
    ------------------------------------------------------------------
    Bringing a character into the world on demand, rather than depending on who
    happens to be standing nearby.

    WHY THIS MATTERS

    The framework is meant to be a mode you enter, not something that only works
    where the cast happens to be. Adam and Lily live in Xion and story areas,
    Raven exists only during her encounter, and a dungeon may hold nobody but
    Eve. Without summoning, most scenes are unplayable most of the time.

    THE GAME'S OWN SPAWNER

    Stellar Blade ships one, on its cheat manager:

        void SBCreateCharacter(FName inCharacterAlias,
                               float RelativeLocX, float RelativeLocY,
                               float RelativeLocZ, float RelativeRotYaw)

    The alias is a row name from CharacterTable, which has 212 of them:
    N_Lily, N_Adam, M_Raven, N_TachyNPC and so on. See docs/character-map.md.

    This is far better than a raw SpawnActor, because it is what the game itself
    uses. All the Stellar Blade specific setup that a bare spawn would miss,
    meshes, anim blueprint, stats, collision, comes along for free.

    WILL IT ACTUALLY WORK?

    Unknown, and worth being careful about. A previous project found that
    USBCheatManager functions are present and callable and do nothing, because
    their bodies are stripped from the shipping build; SBPlayerUseSkill was
    tested and was inert.

    Two reasons to test anyway rather than assume:

      - that was one function, and generalising from one function to a whole
        class is exactly the mistake that cost that project hours.
      - CheatManagerEnablerMod is installed and enabled here, which exists
        precisely to make the cheat manager reachable.

    So this reports honestly which of "not found", "call threw", "call returned
    but nothing appeared" and "character appeared" actually happened. Those are
    four different outcomes and only the last one is success.

    THE FALLBACK

    UGameplayStatics::BeginDeferredActorSpawnFromClass plus FinishSpawningActor
    are ordinary UFunctions and can spawn a Blueprint class directly. That skips
    the game's own initialisation, so it is second choice, but it does not
    depend on the cheat manager being live.
--]]

local Actors = require("actors")

local Summon = {}

local Try, IsLive, FullName = Actors.Try, Actors.IsLive, Actors.FullName

--- Characters spawned by this module, so they can be removed again.
local summoned = {}

function Summon.Tracked() return summoned end

-- ------------------------------------------------------------------ manager

function Summon.CheatManager()
    local manager = Try(FindFirstOf, "SBCheatManager")
    if IsLive(manager) then return manager end

    -- Some builds only create it on demand, hanging off the player controller.
    local controller = Try(FindFirstOf, "SBPlayerController")
    if IsLive(controller) then
        local fromController = Try(function() return controller.CheatManager end)
        if IsLive(fromController) then return fromController end
    end
    return nil
end

-- ------------------------------------------------------------------- summon

--- Count characters of a class, so "did anything appear" can be answered by
--- comparing before and after rather than by trusting the call.
local function CountOf(className)
    local list = Try(FindAllOf, className)
    if not list then return 0 end
    local count = 0
    for _, entry in ipairs(list) do
        if IsLive(entry) then count = count + 1 end
    end
    return count
end

--- Bring a character in near the player.
---
--- `alias` is a CharacterTable row name (N_Lily, N_Adam, M_Raven).
--- `expectClass` is the Blueprint class it should produce, used to verify that
--- something actually arrived. Without it the result is unverifiable and the
--- caller would be trusting a function that returns nothing.
---
--- Returns actor, or nil plus a reason that distinguishes the failure modes.
function Summon.Character(alias, expectClass, offset)
    offset = offset or {}
    local forward = offset.forward or 200.0
    local right   = offset.right   or 0.0
    local up      = offset.up      or 0.0
    local yaw     = offset.yaw     or 180.0

    local manager = Summon.CheatManager()
    if not manager then
        return nil, "no cheat manager (is CheatManagerEnablerMod enabled?)"
    end

    local before = expectClass and CountOf(expectClass) or nil

    local ok, err = pcall(function()
        manager:SBCreateCharacter(FName(alias), forward, right, up, yaw)
    end)
    if not ok then
        return nil, "SBCreateCharacter threw: " .. tostring(err)
    end

    if not expectClass then
        return nil, "called, but no expected class given so nothing was verified"
    end

    -- The spawn is not necessarily complete when the call returns, so the
    -- caller polls. Reporting "called" as success here is exactly the kind of
    -- self-reported signal that has misled this project repeatedly.
    return true, { alias = alias, class = expectClass, before = before,
                   yaw = yaw }
end

--- Did a pending summon arrive? Call on later ticks after Summon.Character.
function Summon.Collect(pending)
    if type(pending) ~= "table" then return nil, "no pending summon" end

    local now = CountOf(pending.class)
    if now <= (pending.before or 0) then
        return nil, string.format("%s: still %d instance(s) of %s, unchanged",
            pending.alias, now, pending.class)
    end

    -- Take the nearest, which is the one just placed relative to the player.
    local list = Try(FindAllOf, pending.class)
    local player = Actors.GetPlayerPawn()
    local best, bestDistance = nil, math.huge
    for _, candidate in ipairs(list or {}) do
        if IsLive(candidate) then
            local distance = IsLive(player)
                and Try(function() return player:GetDistanceTo(candidate) end) or 0
            if type(distance) == "number" and distance < bestDistance then
                best, bestDistance = candidate, distance
            end
        end
    end

    if not best then return nil, pending.alias .. ": count rose but no live actor" end

    summoned[#summoned + 1] = { actor = best, alias = pending.alias }
    return best, bestDistance
end

-- ------------------------------------------------------- engine spawn route

--[[
    SBCreateCharacter is dead. Tested in game: the call does not throw and
    exactly zero instances appear, verified by counting before and after. That
    is the second USBCheatManager function measured inert, after SBPlayerUseSkill
    in a previous project, so the stripped-bodies conclusion now looks like a
    property of the whole class rather than a one-off.

    This route does not touch the cheat manager. BeginDeferredActorSpawnFromClass
    and FinishSpawningActor are ordinary UFunctions on UGameplayStatics, which
    is a UBlueprintFunctionLibrary, so they are called on its CDO.

    Deferred spawn is used rather than the one-shot form because it splits
    construction from registration: the actor exists between the two calls, so
    it can be positioned before it is made live. That avoids a character
    appearing at the origin for a frame and then teleporting.

    The trade against SBCreateCharacter is real. This skips whatever Stellar
    Blade specific setup the game's own spawner would have done, so a character
    produced this way may be missing state that only the game knows to apply.
    Whether that matters is measured, not assumed: the caller checks the
    spawned actor has a body mesh and an anim instance before treating it as
    usable.
--]]

local function GameplayStatics()
    local cdo = Try(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if IsLive(cdo) then return cdo end
    return nil
end

--- Load a Blueprint generated class from its asset path.
--- The runtime class is the asset name with "_C" appended.
function Summon.LoadClass(assetPath)
    local classPath = assetPath .. "_C"
    local class = Try(StaticFindObject, classPath)
    if IsLive(class) then return class end

    -- Loading the asset registers its generated class.
    if type(LoadAsset) == "function" then
        Try(LoadAsset, assetPath)
        class = Try(StaticFindObject, classPath)
        if IsLive(class) then return class end
    end
    return nil, "class not found: " .. classPath
end

--- Spawn a Blueprint character near the player through the engine.
---
--- `assetPath` is the Blueprint asset, without "_C":
---   /Game/Art/Character/NPC/CH_NPC_01/Blueprints/CH_NPC_01_Blueprint
function Summon.SpawnClass(assetPath, offset)
    offset = offset or {}

    local statics = GameplayStatics()
    if not statics then return nil, "UGameplayStatics CDO not found" end

    local class, classError = Summon.LoadClass(assetPath)
    if not class then return nil, classError end

    local player = Actors.GetPlayerPawn()
    if not IsLive(player) then return nil, "no player pawn" end

    local origin = Actors.GetLocation(player)
    local facing = Actors.GetRotation(player)
    if not origin or not facing then return nil, "player transform unreadable" end

    -- Place in the player's own frame, same convention as Actors.Align.
    local theta = (facing.Yaw or 0.0) * math.pi / 180.0
    local cos, sin = math.cos(theta), math.sin(theta)
    local forward = offset.forward or 200.0
    local right   = offset.right   or 0.0

    local transform = {
        Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = {
            X = origin.X + forward * cos - right * sin,
            Y = origin.Y + forward * sin + right * cos,
            Z = origin.Z + (offset.up or 0.0),
        },
        Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    -- 2 = AlwaysSpawn. Anything else risks the spawn being refused because a
    -- character-sized capsule overlaps geometry, which is common indoors and
    -- would look like the whole route failing.
    local actor = Try(function()
        return statics:BeginDeferredActorSpawnFromClass(
            player, class, transform, 2, nil)
    end)
    if not IsLive(actor) then return nil, "deferred spawn returned nothing" end

    local finished = Try(function()
        return statics:FinishSpawningActor(actor, transform)
    end)
    local spawned = IsLive(finished) and finished or actor
    if not IsLive(spawned) then return nil, "FinishSpawningActor produced nothing" end

    summoned[#summoned + 1] = { actor = spawned, alias = assetPath }
    return spawned
end

--- Is a spawned character actually usable, or just an empty shell?
---
--- A spawn that returns an actor proves only that an object was constructed.
--- What matters is whether it has the parts this framework drives.
function Summon.Inspect(actor)
    if not IsLive(actor) then return false, "actor is not valid" end

    local mesh = Try(function() return actor:GetSBSkeletalMeshComponent(0) end)
    if not IsLive(mesh) then return false, "no body mesh" end

    local skeletal = Try(function() return mesh.SkeletalMesh end)
    if not IsLive(skeletal) then return false, "mesh component has no skeletal mesh" end

    local instance = Try(function() return mesh:GetAnimInstance() end)
    if not IsLive(instance) then return false, "no anim instance" end

    return true, string.format("mesh=%s anim=%s",
        FullName(skeletal):match("([^%.]+)$") or "?",
        FullName(instance):match("([^%.]+)$") or "?")
end

-- ----------------------------------------------------------------- teardown

--- Remove everything this module summoned.
---
--- A summoned character left standing in the world is the most visible way this
--- framework could misbehave, so this is called on scene end, on leaving
--- gameplay and on unload, not only when a scene finishes tidily.
function Summon.DismissAll()
    local removed = 0
    for index = #summoned, 1, -1 do
        local entry = summoned[index]
        if IsLive(entry.actor) then
            local ok = Try(function() entry.actor:K2_DestroyActor() return true end)
            if ok then removed = removed + 1 end
        end
        table.remove(summoned, index)
    end
    return removed
end

return Summon
