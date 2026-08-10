--[[
    SBLoveFramework -- paired scene test (v0.5)
    ------------------------------------------------------------------
    First test of two actors in one scene. Exercises the parts that only exist
    when a partner is present: alignment, the shared-BlendSpace guard, dual
    playback and dual teardown.

    IT ADAPTS TO WHO IS ACTUALLY THERE

    Adam and Lily are ordinary NPCs, not always loaded. Raven is a boss and only
    exists during her encounters. In a dungeon there may be nobody but Eve. So
    this reports every character it can resolve, and then:

        partner found     runs a PAIRED scene with it
        no partner        runs the SOLO scene and says where to find one

    That way a run is never wasted, and "nobody was nearby" is distinguished
    from "pairing is broken", which are different problems with the same
    symptom.

    WHERE TO FIND A PARTNER
      Lily and Adam appear in Xion and in story areas rather than in dungeons.
      If this reports no partner, load a save in a populated area and rerun.

    ALSO EXERCISED
      The addon registry, scanning ~mods for *.sblove.json. It reports what it
      found and every problem with a file, scene, stage and line number. This
      run does not require any addon to be installed; the scene definitions
      below are built in.

    RUN ORDER
        0s   report resolvable characters and registry contents
        3s   scene starts, level 1
       13s   level 2
       23s   scene ends, everything restored

    SAFETY
      Teardown is the scene engine's: BlendSpace samples, physics, transforms
      and input blocking are all captured before the first write and restored on
      the timer, on leaving gameplay, and on mod unload. A BlendSpace is a
      SHARED asset, so one left edited stays wrong until level reload.

    Output: ue4ss/SBLoveFramework_scan.txt
--]]

local Playback = require("playback")
local Actors   = require("actors")
local Physics  = require("physics")
local Scene    = require("scene")
local Registry = require("registry")
local Summon   = require("summon")

local ModName    = "SBLove"
local OutputFile = "ue4ss/SBLoveFramework_scan.txt"

local EVE = "/Game/Art/Character/PC/CH_P_EVE_01/Animation/"

--- Candidate partners, most interesting first. Raven is included because if she
--- ever IS present the pairing should be tried, but she is a boss so absence is
--- the normal answer.
local PARTNERS = { "Lily", "Adam", "Tachy", "Drone", "Raven" }

--- Alias and expected class for characters we can try to summon. Aliases are
--- CharacterTable row names; classes come from CharacterAppearanceTable's
--- CharacterAssetPath with "_C" appended. See docs/character-map.md.
local SUMMONABLE = {
    { name = "Lily",  alias = "N_Lily",     class = "CH_NPC_01_Blueprint_C",
      asset = "/Game/Art/Character/NPC/CH_NPC_01/Blueprints/CH_NPC_01_Blueprint" },
    { name = "Adam",  alias = "N_Adam",     class = "CH_NPC_Adam_01_Blueprint_C",
      asset = "/Game/Art/Character/NPC/CH_NPC_Adam_01/Blueprints/CH_NPC_Adam_01_Blueprint" },
    { name = "Tachy", alias = "N_TachyNPC", class = "CH_NPC_TachyNPC_Blueprint_C",
      asset = "/Game/Art/Character/NPC/CH_NPC_TachyNPC/Blueprints/CH_NPC_TachyNPC_Blueprint" },
}

--- Built in so the run does not depend on an addon being installed. Same shape
--- as addons/example.sblove.json.
local function PairedScene(partnerName)
    return {
        id = "demo.paired",
        stages = { {
            id          = "facing",
            displayName = "Facing",
            -- 70 cm in front of Eve, turned to face her. These belong to the
            -- animation; a real pack records what fits its own clips.
            alignment   = { forward = 70, right = 0, up = 0, yaw = 180 },
            loops = {
                { A = EVE .. "Proto_Walk.Proto_Walk", B = EVE .. "Proto_Walk.Proto_Walk" },
                { A = EVE .. "Proto_Jog.Proto_Jog",   B = EVE .. "Proto_Jog.Proto_Jog"   },
            },
        } },
        _partner = partnerName,
    }
end

local SOLO = {
    id = "demo.solo",
    stages = { {
        id        = "locomotion",
        alignment = { forward = 0, right = 0, up = 0, yaw = 180 },
        loops = {
            { A = EVE .. "Proto_Walk.Proto_Walk" },
            { A = EVE .. "Proto_Jog.Proto_Jog"   },
        },
    } },
}

--- Actor spawning crashed the game once, inside BeginDeferredActorSpawnFromClass
--- or FinishSpawningActor. Off until the FTransform marshalling is verified.
local ALLOW_SPAWN = false

--- How close a character has to be to become the partner. 8 m is close enough
--- to be deliberate: you walk up to someone rather than triggering on whoever
--- is across the plaza.
local PARTNER_RANGE = 800.0

local POLL_MS      = 500
local SETTLE_TICKS = 14    -- ~7 s, a summon needs time to arrive
local LEVEL_TICKS  = 20

local Try, IsLive, FullName = Actors.Try, Actors.IsLive, Actors.FullName

-- ------------------------------------------------------------------- output

local Handle = nil

local function Out(text)
    print(string.format("[%s] %s\n", ModName, text))
    if not Handle then
        local ok, handle = pcall(io.open, OutputFile, "w")
        if ok then Handle = handle end
    end
    if Handle then Handle:write(text, "\n") Handle:flush() end
end

-- -------------------------------------------------------------------- state

local Stage    = "wait"
local Ticks    = 0
local Level    = 0
local LastWait = nil
local Partner  = nil

local PartnerActor = nil
local Pending      = nil     -- an in-flight summon, collected on later ticks

local function ReportCast()
    Out("")
    Out("################ WHO IS HERE ################")
    local names = { "Eve" }
    for _, name in ipairs(PARTNERS) do names[#names + 1] = name end

    for _, name in ipairs(names) do
        local actor, why = Actors.Resolve(name)
        if actor then
            Out(string.format("  %-8s PRESENT  %s", name,
                FullName(actor):match("([^%.]+)$") or "?"))
            if name ~= "Eve" and not Partner then
                Partner, PartnerActor = name, actor
            end
        else
            Out(string.format("  %-8s -        %s", name, tostring(why)))
        end
    end

    -- If nobody we want is here, ask the game to bring one in. This is the
    -- point of the mod being a mode you enter: it should not depend on the cast
    -- happening to be nearby.
    if not Partner then
        Out("")
        Out("################ SUMMONING ################")

        -- READ ONLY. The actual spawn crashed the game, with the log stopping
        -- inside SpawnClass, so it is gated behind ALLOW_SPAWN until the
        -- FTransform marshalling is verified. Diagnose checks everything that
        -- can be checked without constructing an actor, which is most of the
        -- chain, and tells us whether the class path fix worked.
        for _, entry in ipairs(SUMMONABLE) do
            local ok, report = Summon.Diagnose(entry.asset)
            Out(string.format("  %-6s %s", entry.name, ok and "CLASS OK" or "no class"))
            Out("    " .. tostring(report))
        end

        if ALLOW_SPAWN then
            Out("")
            Out("  ALLOW_SPAWN is on; attempting a real spawn")
            for _, entry in ipairs(SUMMONABLE) do
                local actor, err = Summon.SpawnClass(entry.asset,
                    { forward = 200, yaw = 180 }, true)
                if actor then
                    local usable, detail = Summon.Inspect(actor)
                    Out(string.format("  SPAWNED %s: %s", entry.name, tostring(detail)))
                    if usable then Partner, PartnerActor = entry.name, actor break end
                    Out("    not usable, dismissing")
                    Summon.DismissAll()
                else
                    Out(string.format("  %-6s spawn failed: %s", entry.name, tostring(err)))
                end
            end
        else
            Out("")
            Out("  spawning is OFF (it crashed the game). Set ALLOW_SPAWN = true")
            Out("  in main.lua to retry once the class report above looks right.")
        end
    end

    -- Whatever else is standing around, as a last resort. Any SBCharacter with
    -- an anim instance works as a partner: what pairing needs is a second
    -- actor, not a particular one.
    if not Partner and not Pending then
        local nearby = Actors.NearbyCharacters(3000.0)
        Out("")
        Out(string.format("  no named partner; %d other character%s nearby",
            #nearby, #nearby == 1 and "" or "s"))
        for index, entry in ipairs(nearby) do
            if index > 6 then break end
            Out(string.format("    %6.0f cm  %s", entry.distance, entry.class))
        end
        if #nearby > 0 then
            Partner      = nearby[1].class
            PartnerActor = nearby[1].actor
            Out("  using the nearest as the test partner: " .. Partner)
        end
    end
end

local function ReportRegistry()
    Out("")
    Out("################ ADDON REGISTRY ################")
    local loaded, problems, files = Registry.ScanAll()
    Out(string.format("  %s  (from %s file%s found)", Registry.Summary(),
        tostring(files or 0), (files == 1) and "" or "s"))

    for _, scene in ipairs(Registry.Scenes()) do
        local actors = scene.actors or {}
        Out(string.format("    %-26s %s%s  stages=%d", scene.id,
            actors.A or "?", actors.B and (" + " .. actors.B) or " (solo)",
            #scene.stages))
    end
    for _, problem in ipairs(Registry.Errors()) do
        Out("    problem: " .. problem)
    end
    if loaded == 0 and (files or 0) == 0 then
        Out("    (no addons installed; this run uses built-in definitions)")
    end
end

local function StartScene()
    local eve = Actors.Resolve("Eve")
    if not eve then Out("  Eve not resolvable") return false end

    local definition, partnerActor = SOLO, PartnerActor
    if partnerActor then definition = PairedScene(Partner) end

    Out("")
    Out("################ SCENE ################")
    if partnerActor then
        Out("  PAIRED: Eve + " .. Partner)
    else
        Out("  SOLO: no partner in this area.")
        Out("  Lily and Adam appear in Xion and story areas, not dungeons.")
        Out("  Load a save somewhere populated and rerun to test pairing.")
    end

    local ok, err = Scene.Start(definition, eve, partnerActor)
    if not ok then
        Out("  scene failed to start: " .. tostring(err))
        return false
    end

    Out("  " .. Scene.Describe())
    local problems = Scene.LastProblems()
    if problems and #problems > 0 then
        for _, problem in ipairs(problems) do Out("    problem: " .. problem) end
    end

    if partnerActor then
        -- Alignment only matters with a partner, and it is the thing most
        -- likely to look wrong, so report where each actually ended up.
        local a, b = Actors.GetLocation(eve), Actors.GetLocation(partnerActor)
        if a and b then
            local gap = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
            Out(string.format("  horizontal gap after alignment: %.1f cm " ..
                "(asked for 70)", gap))
        end
    end
    return true
end

local function NextLevel()
    Level = Level + 1
    if Level > 2 then return false end

    if Level > 1 then
        local ok, err = Scene.SetIntensity(Level)
        if not ok then Out("  intensity change failed: " .. tostring(err)) end
    end

    Out("")
    Out(string.format("################ LEVEL %d / 2 ################", Level))
    Out("  " .. Scene.Describe())
    Out("  >>> watch them for 10 seconds <<<")
    return true
end

-- ------------------------------------------------------------------- driver

local function Tick()
    local pawn, why = Actors.InGameplay()
    if not pawn then
        if why ~= LastWait then Out("waiting: " .. why) LastWait = why end
        if Scene.IsActive() then
            Scene.Stop()
            Out("  scene stopped (left gameplay), everything restored")
        end
        Try(function() Summon.DismissAll() end)
        Stage, Ticks, Level, Partner, PartnerActor, Pending =
            "wait", 0, 0, nil, nil, nil
        return
    end

    Scene.Tick()

    if Stage == "wait" then
        ReportCast()
        ReportRegistry()
        if PartnerActor then
            Stage, Ticks = "settle", 0
        else
            Out("")
            Out("No partner yet. Walk up to a character and the scene starts")
            Out("by itself. Ctrl+Alt+P runs it solo, Ctrl+Alt+O ends it.")
            Stage, Ticks = "waiting_for_partner", 0
        end
        return
    end

    Ticks = Ticks + 1

    -- Loading always drops you at a camp, so a scene cannot simply run a few
    -- seconds after load: you still have to walk to whoever you want. Waiting
    -- for a partner to appear, and saying so once a minute, is far more usable
    -- than firing once and giving up before you have arrived.
    if Stage == "waiting_for_partner" then
        if not PartnerActor then
            local nearby = Actors.NearbyCharacters(PARTNER_RANGE)
            if #nearby > 0 then
                Partner, PartnerActor = nearby[1].class, nearby[1].actor
                Out("")
                Out(string.format("partner found: %s at %.0f cm",
                    Partner, nearby[1].distance))
                Stage, Ticks = "settle", 0
            elseif Ticks % 120 == 0 then
                Out(string.format("waiting for a humanoid within %.0f m " ..
                    "(walk up to one, or Ctrl+Alt+P to run solo)",
                    PARTNER_RANGE / 100))
            end
        end
        return
    end

    if Stage == "settle" then
        -- A summon is not complete when the call returns, so it is collected
        -- over the following ticks rather than assumed to have worked.
        if Pending and not PartnerActor then
            local actor, info = Summon.Collect(Pending)
            if actor then
                Partner, PartnerActor = Pending.name, actor
                Out(string.format("  %s ARRIVED at %.0f cm", Pending.name,
                    type(info) == "number" and info or -1))
                Pending = nil
            elseif Ticks >= SETTLE_TICKS - 1 then
                Out("  summon did not arrive: " .. tostring(info))
                Out("  (USBCheatManager bodies are stripped in shipping builds;" ..
                    " this confirms it for SBCreateCharacter)")
                Pending = nil
            end
        end

        if Ticks >= SETTLE_TICKS then
            Stage = StartScene() and "levels" or "done"
            Ticks = LEVEL_TICKS
        end
        return
    end

    if Stage == "levels" then
        if Ticks >= LEVEL_TICKS then
            Ticks = 0
            if not NextLevel() then
                Out("")
                Out("################ DONE ################")
                Scene.Stop()
                local dismissed = Summon.DismissAll()
                Out(string.format("  scene stopped, everything restored" ..
                    "%s", dismissed > 0 and
                    (", " .. dismissed .. " summoned character(s) dismissed") or ""))
                Out("")
                if Partner then
                    Out("Did they both animate, and did " .. Partner ..
                        " end up in front of Eve facing her?")
                else
                    Out("Solo run only. Rerun where Lily or Adam is present " ..
                        "to test pairing.")
                end
                Stage = "done"
            end
        end
        return
    end
end

-- Manual controls. Letters, not function keys: an iPad keyboard has none and
-- many laptops need an Fn chord.
pcall(RegisterKeyBind, Key.P, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
    if Scene.IsActive() then
        Out("a scene is already running (Ctrl+Alt+O to end it)")
        return
    end
    Out("")
    Out("manual start requested")
    Stage, Ticks, Level = StartScene() and "levels" or "done", LEVEL_TICKS, 0
end)

pcall(RegisterKeyBind, Key.O, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
    if not Scene.IsActive() then Out("no scene running") return end
    Scene.Stop()
    Summon.DismissAll()
    Out("scene ended, everything restored")
    Stage, Ticks, Level = "waiting_for_partner", 0, 0
end)

Out("SBLoveFramework v0.5 -- paired scene test")
Out("  Ctrl+Alt+P  start a scene now   Ctrl+Alt+O  end it")
Out("Load a save. Ideally somewhere Lily or Adam is present, such as Xion.")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)

--- Re-assert the two graph-driven physics nodes each frame; the other 26 spring
--- chains keep what they are given and are not touched here.
pcall(LoopAsync, 16, function()
    ExecuteInGameThread(Physics.SustainAll)
    return false
end)

pcall(RegisterOnUnloadCallback or function() end, function()
    Try(function() Scene.Stop() end)
    Try(function() Playback.RestoreEverything() end)
    Try(function() Physics.RestoreAll() end)
    Try(function() Actors.RestoreAll() end)
    Try(function() Summon.DismissAll() end)
end)
