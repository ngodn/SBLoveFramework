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

local ModName    = "SBLove"
local OutputFile = "ue4ss/SBLoveFramework_scan.txt"

local EVE = "/Game/Art/Character/PC/CH_P_EVE_01/Animation/"

--- Candidate partners, most interesting first. Raven is included because if she
--- ever IS present the pairing should be tried, but she is a boss so absence is
--- the normal answer.
local PARTNERS = { "Lily", "Adam", "Tachy", "Drone", "Raven" }

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

local POLL_MS      = 500
local SETTLE_TICKS = 6
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
            if name ~= "Eve" and not Partner then Partner = name end
        else
            Out(string.format("  %-8s -        %s", name, tostring(why)))
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

    local definition, partnerActor = SOLO, nil
    if Partner then
        partnerActor = Actors.Resolve(Partner)
        if partnerActor then definition = PairedScene(Partner) end
    end

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
        Stage, Ticks, Level, Partner = "wait", 0, 0, nil
        return
    end

    Scene.Tick()

    if Stage == "wait" then
        ReportCast()
        ReportRegistry()
        Stage, Ticks = "settle", 0
        return
    end

    Ticks = Ticks + 1

    if Stage == "settle" then
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
                Out("  scene stopped, everything restored")
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

Out("SBLoveFramework v0.5 -- paired scene test")
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
end)
