--[[
    SBLoveFramework -- dynamic intensity demo (v0.4)
    ------------------------------------------------------------------
    Proves the whole system end to end, in miniature: a real stage with four
    intensity loops, driven through the scene engine, with secondary motion
    following the intensity axis automatically.

    WHY WALK / JOG / RUN / SPRINT

    A fixed physics preset was the wrong model. Soft tissue is a
    mass-spring-damper, and the response amplitude follows the DRIVING
    ACCELERATION rather than any setting. So to show that honestly the demo
    needs four animations that genuinely differ in acceleration, and Eve's own
    locomotion set is exactly that, already authored for her skeleton:

        level 1   Proto_Walk      gentle
        level 2   Proto_Jog
        level 3   Proto_Run
        level 4   Proto_Sprint    hardest

    That is the Umemaro loop_a..loop_d shape using assets that already exist.

    WHAT TO WATCH FOR

    Two separate things are happening, and they are worth telling apart:

      1. the animation gets faster, so the driving acceleration rises and the
         secondary motion grows ON ITS OWN. This needs no settings at all.
      2. the physics CEILING lifts with intensity (MaxDisplacement, LimitAngle),
         so that growth is not clipped, and Damping eases so more of the
         acceleration shows through.

    Stiffness is deliberately almost unchanged across all four, because natural
    frequency is a property of the tissue and should not appear to change with
    how hard she is moving.

    RUN ORDER

        0s    report shipped physics
        3s    scene starts at level 1  (walk)
       13s    level 2  (jog)
       23s    level 3  (run)
       33s    level 4  (sprint)
       43s    scene ends, everything restored

    SAFETY

    Everything goes through the scene engine, so teardown is the engine's:
    BlendSpace samples, physics settings, actor transforms and input blocking
    are all captured before the first write and restored on the timer, on
    leaving gameplay, and on mod unload. A BlendSpace is a SHARED asset and
    physics live on a live anim instance, so either left edited would persist
    until level reload. Nothing is written to disk; a hard kill is recovered by
    restarting the game.

    Output: ue4ss/SBLoveFramework_scan.txt
--]]

local Playback = require("playback")
local Actors   = require("actors")
local Physics  = require("physics")
local Scene    = require("scene")

local ModName    = "SBLove"
local OutputFile = "ue4ss/SBLoveFramework_scan.txt"

local EVE_ANIM = "/Game/Art/Character/PC/CH_P_EVE_01/Animation/"

--- One stage, four intensity loops. This is a real scene definition in the
--- format addons will ship, just built from stock assets instead of authored
--- ones. B tracks are absent because this is a solo demo.
local DEMO = {
    id = "demo.locomotion",
    stages = {
        {
            id          = "locomotion",
            displayName = "Locomotion ramp",
            tags        = { "demo", "solo" },
            alignment   = { forward = 0, right = 0, up = 0, yaw = 180 },
            loops = {
                { A = EVE_ANIM .. "Proto_Walk.Proto_Walk"     },
                { A = EVE_ANIM .. "Proto_Jog.Proto_Jog"       },
                { A = EVE_ANIM .. "Proto_Run.Proto_Run"       },
                { A = EVE_ANIM .. "Proto_Sprint.Proto_Sprint" },
            },
        },
    },
}

local POLL_MS      = 500
local SETTLE_TICKS = 6      -- ~3 s in gameplay before touching anything
local LEVEL_TICKS  = 20     -- 10 s per intensity level

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

local Instance = nil
local Stage    = "wait"
local Ticks    = 0
local Level    = 0
local LastWait = nil

local LEVEL_NAMES = { "walk", "jog", "run", "sprint" }

local function ReportPhysics(label)
    Out("")
    Out("---- physics: " .. label)
    Out(Physics.Describe(Instance))
end

local function StartScene()
    local pawn = Actors.Resolve("Eve")
    if not pawn then Out("  Eve not resolvable") return false end

    local ok, err = Scene.Start(DEMO, pawn, nil)
    if not ok then
        Out("  scene failed to start: " .. tostring(err))
        return false
    end

    Out("")
    Out("################ SCENE STARTED ################")
    Out("  " .. Scene.Describe())

    -- The previous run showed level 1 keeping the shipped physics values while
    -- levels 2..4 ramped correctly, which means the apply that happens inside
    -- Scene.Start did not take. Its error was being swallowed by a silent
    -- pcall. Both are fixed; this prints whatever the engine now reports so the
    -- cause is visible rather than inferred.
    local problems = Scene.LastProblems()
    if problems and #problems > 0 then
        Out("  physics/playback problems at start:")
        for _, problem in ipairs(problems) do Out("    " .. problem) end
    else
        Out("  no problems reported at start")
    end
    return true
end

local function NextLevel()
    Level = Level + 1
    if Level > 4 then return false end

    if Level > 1 then
        local ok, err = Scene.SetIntensity(Level)
        if not ok then Out("  intensity change failed: " .. tostring(err)) end
    end

    Out("")
    Out(string.format("################ LEVEL %d / 4  (%s) ################",
        Level, LEVEL_NAMES[Level]))
    Out("  " .. Scene.Describe())
    ReportPhysics("at level " .. Level)
    Out("  >>> watch her for 10 seconds <<<")
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
        Instance, Stage, Ticks, Level = nil, "wait", 0, 0
        return
    end

    Scene.Tick()    -- lets the engine end the scene if an actor vanishes

    if not IsLive(Instance) then
        Instance = Playback.GetAnimInstance(pawn)
        if not Instance then return end
        Out("")
        Out("anim instance: " .. FullName(Instance))
        ReportPhysics("as shipped")
        Stage, Ticks = "settle", 0
        return
    end

    Ticks = Ticks + 1

    if Stage == "settle" then
        if Ticks >= SETTLE_TICKS then
            Stage = StartScene() and "levels" or "done"
            Ticks = LEVEL_TICKS       -- fire the first level immediately
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
                Out("  scene stopped, blend space + physics + actor restored")
                ReportPhysics("after restore (should match 'as shipped')")
                Out("")
                Out("Did the secondary motion visibly grow from walk to sprint?")
                Stage = "done"
            end
        end
        return
    end
end

Out("SBLoveFramework v0.4 -- dynamic intensity demo")
Out("Load a save, stand in the world. Runs ~45 s: walk -> jog -> run -> sprint,")
Out("with secondary motion following the intensity axis automatically.")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)

pcall(RegisterOnUnloadCallback or function() end, function()
    Try(function() Scene.Stop() end)
    Try(function() Playback.RestoreEverything() end)
    Try(function() Physics.RestoreAll() end)
    Try(function() Actors.RestoreAll() end)
end)
