--[[
    SBLoveFramework -- console command verification (P9, second attempt)
    ------------------------------------------------------------------
    WHY THERE IS A SECOND ATTEMPT

    The first P9 run reported "neither route spawns". That verdict was worthless,
    because its own control failed in the same run:

        ConsoleCommand("ThisCommandCannotExist_SBLove_P9")  returned: nil
        TimeDilation after slomo 0.5: 1.0        NOTHING

    slomo is known to work here. probe_v13 changed time dilation with it. So a
    run where slomo does nothing is a run where the instrument is broken, and
    nothing measured through that instrument means anything. The old summary
    still printed verdicts on steps 3-5. It should have refused.

    WHAT WAS WRONG

    The route. The first attempt called:

        controller:ConsoleCommand(command, true)

    The code that demonstrably worked (archive/SBAutoCombat/scripts/act.lua:107)
    calls the engine's Blueprint helper instead:

        kismet:ExecuteConsoleCommand(world, command, controller)

    UKismetSystemLibrary.ExecuteConsoleCommand is a real BlueprintCallable
    UFunction present in every UE4 build, which is why it is reliable where a
    direct method call on the controller is not.

    Both routes are kept below, and tried against the same control, because
    "which route works" is itself worth recording.

    THE CONTROL GATES EVERYTHING

    Nothing is tested until slomo is proven to move time in THIS run. If it does
    not, the probe stops and says the instrument is broken. A probe that reports
    findings its own control does not support is worse than no probe.

    Time is measured two independent ways, because one instrument agreeing with
    itself is not evidence:

      1. WorldSettings.TimeDilation read back
      2. game seconds elapsed per real second, from GetTimeSeconds across ticks

    Under slomo 0.5 the second should fall to about half. That one cannot be
    faked by a property write that the engine ignores.

    WHAT IS THEN TESTED
      SBCreateCharacter   as a UFunction, and through the console
      SBGameOptionHUDVisible   you watch the screen

    SAFETY
      slomo restored to 1.0 in the same step, and again on unload.
      HUD restored, and again on unload.

    WHAT TO DO
      Load a save, stand in the world, press nothing. About 50 seconds.
      Watch the screen near the end for the HUD.

    Output: ue4ss/SBLoveFramework_probe.txt
--]]

local Actors = require("actors")

local OutputFile = "ue4ss/SBLoveFramework_probe.txt"
local POLL_MS    = 1000

local SPAWN_ALIAS = "N_Lily"
local SPAWN_CLASS = "CH_NPC_01_Blueprint_C"
local SPAWN_ARGS  = { forward = 250.0, right = 0.0, up = 0.0, yaw = 180.0 }

-- --------------------------------------------------------------------- io

local handle = io.open(OutputFile, "w")

local function Out(line)
    line = tostring(line)
    print("[SBLove/P9] " .. line .. "\n")
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

-- ------------------------------------------------------------- primitives

local function Controller()
    local controller = Try(FindFirstOf, "SBPlayerController")
    if IsLive(controller) then return controller end
    controller = Try(FindFirstOf, "PlayerController")
    if IsLive(controller) then return controller end
    return nil
end

local KismetCache = nil
local function Kismet()
    if IsLive(KismetCache) then return KismetCache end
    KismetCache = Try(StaticFindObject,
        "/Script/Engine.Default__KismetSystemLibrary")
    return IsLive(KismetCache) and KismetCache or nil
end

--- Route A: the engine's Blueprint helper. This is the one that worked in
--- SBAutoCombat, so it is the default everywhere below.
local function ConsoleViaKismet(command)
    local kismet = Kismet()
    if not kismet then return false, "no KismetSystemLibrary" end
    local controller = Controller()
    if not controller then return false, "no player controller" end
    local world = Try(function() return controller:GetWorld() end)
    if not IsLive(world) then return false, "no world" end
    local ok = pcall(function()
        kismet:ExecuteConsoleCommand(world, command, controller)
    end)
    return ok, ok and nil or "call threw"
end

--- Route B: the direct method. This is what the first attempt used, and it
--- produced nothing at all, not even on a known good command.
local function ConsoleViaController(command)
    local controller = Controller()
    if not controller then return false, "no player controller" end
    local ok = pcall(function() controller:ConsoleCommand(command, true) end)
    return ok, ok and nil or "call threw"
end

--- Set once the control proves which route moves the game.
local Console = ConsoleViaKismet

local function CountOf(className)
    local list = Try(FindAllOf, className)
    if not list then return 0 end
    local count = 0
    for _, entry in ipairs(list) do
        if IsLive(entry) then count = count + 1 end
    end
    return count
end

local function TimeDilation()
    local settings = Try(FindFirstOf, "SBWorldSettings")
    if not IsLive(settings) then settings = Try(FindFirstOf, "WorldSettings") end
    if not IsLive(settings) then return nil end
    local value = Try(function() return settings.TimeDilation end)
    return type(value) == "number" and value or nil
end

local GameplayStaticsCache = nil
local function GameplayStatics()
    if IsLive(GameplayStaticsCache) then return GameplayStaticsCache end
    GameplayStaticsCache = Try(StaticFindObject,
        "/Script/Engine.Default__GameplayStatics")
    return IsLive(GameplayStaticsCache) and GameplayStaticsCache or nil
end

--- Game seconds, which slow down under slomo while our real-time timer does
--- not. This is the measurement that cannot be faked by an ignored write.
---
--- UWorld::GetTimeSeconds is a plain C++ method with no UFunction behind it, so
--- it is not callable through reflection. The first attempt used it, got nil
--- every tick, and the probe waited forever for a number that could not arrive.
--- Both routes below are BlueprintCallable and therefore actually reachable.
local GameSecondsRoute = nil

local function GameSeconds()
    local controller = Controller()
    if not controller then return nil, "no controller" end
    local world = Try(function() return controller:GetWorld() end)
    if not IsLive(world) then return nil, "no world" end

    local kismet = Kismet()
    if kismet then
        local value = Try(function() return kismet:GetGameTimeInSeconds(world) end)
        if type(value) == "number" then
            GameSecondsRoute = "KismetSystemLibrary.GetGameTimeInSeconds"
            return value
        end
    end

    local statics = GameplayStatics()
    if statics then
        local value = Try(function() return statics:GetTimeSeconds(world) end)
        if type(value) == "number" then
            GameSecondsRoute = "GameplayStatics.GetTimeSeconds"
            return value
        end
    end

    return nil, "neither GetGameTimeInSeconds nor GetTimeSeconds returned a number"
end

local function CheatManager()
    local manager = Try(FindFirstOf, "SBCheatManager")
    if IsLive(manager) then return manager end
    local controller = Controller()
    if controller then
        local owned = Try(function() return controller.CheatManager end)
        if IsLive(owned) then return owned end
    end
    return nil
end

-- ------------------------------------------------------------------ state

local Step, Ticks = "wait", 0
local Results  = {}
local Baseline = {}
local RouteName = "kismet"

local function Record(name, verdict, detail)
    Results[#Results + 1] = { name = name, verdict = verdict, detail = detail }
    Out(string.format("     %-8s %s", verdict, detail or ""))
end

local function Abort(reason)
    Out("")
    Out("################ ABORTED ################")
    Out("  " .. reason)
    Out("")
    Out("  No verdicts are given on the real tests. The control failed, so")
    Out("  every measurement taken through it would be meaningless. This is")
    Out("  a broken instrument, not a finding about the game.")
    Out("")
    Out("ALL DONE -- you can quit.")
    Step = "finished"
end

-- ------------------------------------------------------------------- steps

--- Sample game time across ticks so its rate can be compared before and after.
--- Returns the rate, or nil while still collecting.
local Samples      = {}
local RateUsable   = nil   -- nil = undecided, false = fall back to TimeDilation
local SAMPLE_LIMIT = 6     -- ticks to wait before declaring the rate unusable

local function SampleRate()
    local now, why = GameSeconds()
    if now == nil then
        if RateUsable == nil and #Samples == 0 then Samples.why = why end
        return nil
    end
    Samples[#Samples + 1] = now
    if #Samples < 3 then return nil end
    local span = Samples[#Samples] - Samples[#Samples - 2]
    return span / 2.0   -- game seconds per real second, at POLL_MS = 1000
end

--- Did the world slow down? Prefers the rate, falls back to TimeDilation when
--- game time could not be read at all. Returns changed, description.
local function SlowedDown(rate, dilation)
    if rate and Baseline.rate and Baseline.rate > 0 then
        return rate < Baseline.rate * 0.75,
               string.format("rate %.2f -> %.2f", Baseline.rate, rate)
    end
    if type(dilation) == "number" and type(Baseline.dilation) == "number" then
        return math.abs(dilation - Baseline.dilation) > 0.01,
               string.format("TimeDilation %.2f -> %.2f",
                   Baseline.dilation, dilation)
    end
    return false, "no usable measurement"
end

local function StepWait()
    if not Actors.InGameplay() then
        if Ticks % 5 == 0 then Out("waiting for gameplay (not the menu)") end
        return
    end
    local pawn = Actors.GetPlayerPawn()
    Out("")
    Out("in gameplay: " .. tostring(Try(function() return pawn:GetFullName() end)))
    Out("  cheat manager:      " .. (CheatManager() and "found" or "NOT FOUND"))
    Out("  player controller:  " .. (Controller() and "found" or "NOT FOUND"))
    Out("  KismetSystemLibrary:" .. (Kismet() and " found" or " NOT FOUND"))
    Out("")
    Out("############ CONTROL -- prove the console moves the game ############")
    Out("  measuring normal time rate first")
    Samples = {}
    Step, Ticks = "rate_before", 0
end

local function StepRateBefore()
    local rate = SampleRate()

    -- Never wait forever for a number that may never come. The first attempt
    -- did exactly that and produced a log that simply stopped mid-sentence.
    if rate == nil then
        if Ticks < SAMPLE_LIMIT then return end
        RateUsable = false
        Out("  could not read game time: " .. tostring(Samples.why))
        Out("  falling back to TimeDilation alone, which is the weaker check")
    else
        RateUsable    = true
        Baseline.rate = rate
        Out(string.format("  normal rate: %.2f game seconds per real second "
            .. "(via %s)", rate, tostring(GameSecondsRoute)))
    end

    Baseline.dilation = TimeDilation()
    Out(string.format("  TimeDilation reads: %s", tostring(Baseline.dilation)))
    if RateUsable == false and Baseline.dilation == nil then
        Abort("neither game time nor TimeDilation can be read, so there is no "
            .. "way to tell whether a console command did anything")
        return
    end
    Out("")
    Out("  route A: KismetSystemLibrary.ExecuteConsoleCommand(\"slomo 0.5\")")
    local ok, err = ConsoleViaKismet("slomo 0.5")
    if not ok then Out("     call failed: " .. tostring(err)) end
    Samples = {}
    Step, Ticks = "rate_kismet", 0
end

local function StepRateKismet()
    local rate = SampleRate()
    if rate == nil and RateUsable and Ticks < SAMPLE_LIMIT then return end
    local dilation = TimeDilation()
    local changed, how = SlowedDown(rate, dilation)
    Out("     " .. how)

    if changed then
        Console, RouteName = ConsoleViaKismet, "kismet"
        Record("console route", "WORKED", "Kismet route moves the game")
        ConsoleViaKismet("slomo 1.0")
        Out("  restored slomo 1.0")
        Out("")
        Out("############ TEST 1 -- SBCreateCharacter, UFunction ############")
        Baseline.spawn = CountOf(SPAWN_CLASS)
        Out(string.format("  %s count before: %d", SPAWN_CLASS, Baseline.spawn))
        local manager = CheatManager()
        if not manager then
            Record("SBCreateCharacter/ufunction", "SKIPPED", "no cheat manager")
            Step, Ticks = "ufunction_done", 0
            return
        end
        local ok, err = pcall(function()
            manager:SBCreateCharacter(FName(SPAWN_ALIAS),
                SPAWN_ARGS.forward, SPAWN_ARGS.right, SPAWN_ARGS.up, SPAWN_ARGS.yaw)
        end)
        Out(string.format("  manager:SBCreateCharacter(%s, ...) -> %s", SPAWN_ALIAS,
            ok and "no error" or ("threw: " .. tostring(err))))
        Step, Ticks = "ufunction", 0
        return
    end

    -- Kismet did not move it. Try the other route before giving up.
    Out("     Kismet route did not change the rate")
    ConsoleViaKismet("slomo 1.0")
    Out("")
    Out("  route B: controller:ConsoleCommand(\"slomo 0.5\")")
    local ok, err = ConsoleViaController("slomo 0.5")
    if not ok then Out("     call failed: " .. tostring(err)) end
    Samples = {}
    Step, Ticks = "rate_controller", 0
end

local function StepRateController()
    local rate = SampleRate()
    if rate == nil and RateUsable and Ticks < SAMPLE_LIMIT then return end
    local changed, how = SlowedDown(rate, TimeDilation())
    Out("     " .. how)
    ConsoleViaController("slomo 1.0")
    ConsoleViaKismet("slomo 1.0")

    if changed then
        Console, RouteName = ConsoleViaController, "controller"
        Record("console route", "WORKED", "controller route moves the game")
        Out("")
        Out("############ TEST 1 -- SBCreateCharacter, UFunction ############")
        Baseline.spawn = CountOf(SPAWN_CLASS)
        local manager = CheatManager()
        if not manager then
            Record("SBCreateCharacter/ufunction", "SKIPPED", "no cheat manager")
            Step, Ticks = "ufunction_done", 0
            return
        end
        pcall(function()
            manager:SBCreateCharacter(FName(SPAWN_ALIAS),
                SPAWN_ARGS.forward, SPAWN_ARGS.right, SPAWN_ARGS.up, SPAWN_ARGS.yaw)
        end)
        Step, Ticks = "ufunction", 0
        return
    end

    Abort("slomo changed nothing by either route. The console is not reachable "
        .. "from here in this build, so no cheat command can be tested yet.")
end

local function StepUFunction()
    local now = CountOf(SPAWN_CLASS)
    if now > Baseline.spawn then
        Record("SBCreateCharacter/ufunction", "WORKED",
            string.format("%s %d -> %d", SPAWN_CLASS, Baseline.spawn, now))
        Step, Ticks = "ufunction_done", 0
        return
    end
    if Ticks >= 5 then
        Record("SBCreateCharacter/ufunction", "NOTHING",
            string.format("%s stayed at %d over 5s", SPAWN_CLASS, Baseline.spawn))
        Step, Ticks = "ufunction_done", 0
    end
end

local function StepUFunctionDone()
    Out("")
    Out("########## TEST 2 -- SBCreateCharacter, console (" .. RouteName .. ") ##########")
    Baseline.spawn = CountOf(SPAWN_CLASS)
    local command = string.format("SBCreateCharacter %s %g %g %g %g",
        SPAWN_ALIAS, SPAWN_ARGS.forward, SPAWN_ARGS.right,
        SPAWN_ARGS.up, SPAWN_ARGS.yaw)
    Out(string.format("  %s count before: %d", SPAWN_CLASS, Baseline.spawn))
    Out("  " .. command)
    Console(command)
    Step, Ticks = "console_spawn", 0
end

local function StepConsoleSpawn()
    local now = CountOf(SPAWN_CLASS)
    if now > Baseline.spawn then
        Record("SBCreateCharacter/console", "WORKED",
            string.format("%s %d -> %d", SPAWN_CLASS, Baseline.spawn, now))
        Step, Ticks = "hud", 0
        return
    end
    if Ticks >= 6 then
        Record("SBCreateCharacter/console", "NOTHING",
            string.format("%s stayed at %d over 6s", SPAWN_CLASS, Baseline.spawn))
        Step, Ticks = "hud", 0
    end
end

local function StepHud()
    Out("")
    Out("################ TEST 3 -- HUD, watch the screen ################")
    Out("  SBGameOptionHUDVisible false   -- HUD should vanish for 4 seconds")
    Console("SBGameOptionHUDVisible false")
    Step, Ticks = "hud_wait", 0
end

local function StepHudWait()
    if Ticks < 4 then return end
    Console("SBGameOptionHUDVisible true")
    Out("  SBGameOptionHUDVisible true    -- HUD should be back")
    Record("SBGameOptionHUDVisible", "ASK", "did the HUD actually disappear?")
    Step, Ticks = "summary", 0
end

local function StepSummary()
    Out("")
    Out("################ SUMMARY ################")
    Out("  control passed, so these verdicts stand")
    Out("")
    for _, entry in ipairs(Results) do
        Out(string.format("  %-8s %s", entry.verdict, entry.name))
    end

    local uf, con
    for _, entry in ipairs(Results) do
        if entry.name == "SBCreateCharacter/ufunction" then uf  = entry.verdict end
        if entry.name == "SBCreateCharacter/console"   then con = entry.verdict end
    end

    Out("")
    Out("  SBCreateCharacter")
    Out(string.format("    as UFunction:  %s", tostring(uf)))
    Out(string.format("    via console:   %s", tostring(con)))
    if con == "WORKED" then
        Out("    -> the cast can be loaded. The engine's other 697 commands are")
        Out("       worth testing one by one.")
    elseif uf == "WORKED" then
        Out("    -> the UFunction route works after all; last session's failure")
        Out("       was the alias, not the call.")
    else
        Out("    -> the console works but this command does nothing. That is a")
        Out("       real finding now, because the control passed. Next suspects:")
        Out("       the alias N_Lily, or a required game state.")
    end
    Out("")
    Out("ALL DONE -- you can quit. Answer: did the HUD disappear?")
    Step = "finished"
end

-- -------------------------------------------------------------------- tick

local STEPS = {
    wait            = StepWait,
    rate_before     = StepRateBefore,
    rate_kismet     = StepRateKismet,
    rate_controller = StepRateController,
    ufunction       = StepUFunction,
    ufunction_done  = StepUFunctionDone,
    console_spawn   = StepConsoleSpawn,
    hud             = StepHud,
    hud_wait        = StepHudWait,
    summary         = StepSummary,
}

local function Tick()
    if Step == "finished" then return end
    local handler = STEPS[Step]
    if handler then handler() end
    Ticks = Ticks + 1
end

Out("SBLoveFramework P9 (second attempt) -- is the console reachable?")
Out("The first run's control failed, so it proved nothing. This one stops if")
Out("that happens again instead of reporting verdicts it cannot support.")
Out("")
Out("Load a save, stand still, about 50 seconds. Watch the screen near the end.")
Out("")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)

pcall(RegisterOnUnloadCallback or function() end, function()
    Try(function() ConsoleViaKismet("slomo 1.0") end)
    Try(function() ConsoleViaKismet("SBGameOptionHUDVisible true") end)
end)
