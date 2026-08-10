--[[
    SBLoveFramework -- console command verification (P9)
    ------------------------------------------------------------------
    THE QUESTION

    USBCheatManager has 698 developer commands (docs/engine-api.md). Nearly
    every primitive a scene mode needs is in there: SBChangeWorld,
    SBCreateCharacter, SBChangeBody, SBPlayCustomAnimByTag.

    An earlier session called SBCreateCharacter as a UFunction:

        manager:SBCreateCharacter(FName(alias), fwd, right, up, yaw)   -- summon.lua:118

    Nothing happened, and the conclusion recorded was "USBCheatManager bodies
    are stripped in shipping builds" (main.lua:479). That conclusion was drawn
    from one function, by one route, and generalised to the whole class.

    probe_v13 contradicts it. It fired SBPlayerBattleState through
    ConsoleCommand and the game responded. SBPlayerBattleState is a
    USBCheatManager member (SB.hpp:16392), so the class is NOT stripped.

    The difference between the two attempts is the ROUTE, not the class. This
    probe tests exactly that, by calling the same function both ways in the
    same run, minutes apart, against the same measurement.

    WHY THE RETURN VALUE IS IGNORED THROUGHOUT

    probe_v13 also recorded this:

        ConsoleCommand("ThisCommandDoesNotExist123") -> true

    ConsoleCommand returns true for a command that does not exist. Five of its
    seven commands returned true and did nothing. So every test below is judged
    by a measured change in the world, and step 1 re-establishes that baseline
    so the log carries its own proof that the return value means nothing.

    WHAT IS MEASURED

      step 1  a command that cannot exist        return value only (the control)
      step 2  slomo 0.5                          WorldSettings.TimeDilation read back
      step 3  SBCreateCharacter, UFunction       count of the expected class
      step 4  SBCreateCharacter, ConsoleCommand  count of the expected class
      step 5  SBGameOptionHUDVisible false       YOU report, it is on your screen

    Steps 3 and 4 are the point. Same function, same argument, same target,
    different route.

    SAFETY
      slomo is restored to 1.0 in step 2, and again on unload.
      The HUD is restored in step 5, and again on unload.
      Anything spawned is left in place: this probe measures, it does not clean
      up, because a failed despawn would confuse the result it is measuring.

    WHAT TO DO
      Load a save and stand in the world, anywhere. Do not press anything.
      The run takes about 40 seconds. Watch the screen during step 5.

    Output: ue4ss/SBLoveFramework_probe.txt
--]]

local Actors = require("actors")

local OutputFile = "ue4ss/SBLoveFramework_probe.txt"
local POLL_MS    = 1000

--- Spawn target. N_Lily is a CharacterTable row name; the class is what
--- CharacterAppearanceTable says it produces. See docs/character-map.md.
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

--- Run a console command. Returns what the engine said, which by design is
--- recorded and then disregarded.
local function Console(command)
    local controller = Controller()
    if not controller then return nil, "no player controller" end
    local returned = Try(function()
        return controller:ConsoleCommand(command, true)
    end)
    return returned, nil
end

--- Live count of a class, so "did anything appear" is answered by comparison
--- rather than by trusting the call.
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
    if type(value) == "number" then return value end
    return nil
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
local Results = {}
local Baseline = { dilation = nil, spawn = nil }

local function Record(name, verdict, detail)
    Results[#Results + 1] = { name = name, verdict = verdict, detail = detail }
    Out(string.format("     %-8s %s", verdict, detail or ""))
end

--- Poll for a spawn over several ticks, because the call returning does not
--- mean the actor exists yet.
local function CollectSpawn(label, before)
    local now = CountOf(SPAWN_CLASS)
    if now > before then
        Record(label, "WORKED", string.format(
            "%s count %d -> %d, a character arrived", SPAWN_CLASS, before, now))
        return true
    end
    return false
end

-- ------------------------------------------------------------------- steps

local function StepWait()
    if not Actors.InGameplay() then
        if Ticks % 5 == 0 then Out("waiting for gameplay (not the menu)") end
        return
    end
    local pawn = Actors.GetPlayerPawn()
    Out("")
    Out("in gameplay: " .. tostring(Try(function() return pawn:GetFullName() end)))
    Out("cheat manager object: " .. (CheatManager() and "found" or "NOT FOUND"))
    Out("player controller: " .. (Controller() and "found" or "NOT FOUND"))
    Out("")
    Out("################ STEP 1 -- the control ################")
    Step, Ticks = "control", 0
end

local function StepControl()
    local returned = Console("ThisCommandCannotExist_SBLove_P9")
    Out("  ConsoleCommand(\"ThisCommandCannotExist_SBLove_P9\")")
    Out(string.format("     returned: %s", tostring(returned)))
    Out("     ^ whatever this says, it is meaningless. Nothing below is")
    Out("       judged by a return value.")
    Out("")
    Out("################ STEP 2 -- slomo, a known good ################")
    Baseline.dilation = TimeDilation()
    Out(string.format("  TimeDilation before: %s", tostring(Baseline.dilation)))
    Console("slomo 0.5")
    Step, Ticks = "slomo", 0
end

local function StepSlomo()
    local now = TimeDilation()
    Out(string.format("  TimeDilation after slomo 0.5: %s", tostring(now)))
    if Baseline.dilation == nil or now == nil then
        Record("slomo", "UNKNOWN", "could not read TimeDilation, no verdict")
    elseif math.abs(now - Baseline.dilation) > 0.01 then
        Record("slomo", "WORKED", string.format(
            "%.2f -> %.2f, the console route is live",
            Baseline.dilation, now))
    else
        Record("slomo", "NOTHING", string.format("stayed at %.2f", now))
    end
    Console("slomo 1.0")
    Out("  restored slomo 1.0")

    Out("")
    Out("############ STEP 3 -- SBCreateCharacter, UFunction ############")
    Out("  this is the route that failed last session")
    local manager = CheatManager()
    Baseline.spawn = CountOf(SPAWN_CLASS)
    Out(string.format("  %s count before: %d", SPAWN_CLASS, Baseline.spawn))
    if not manager then
        Record("SBCreateCharacter/ufunction", "SKIPPED", "no cheat manager object")
        Step, Ticks = "ufunction_done", 0
        return
    end
    local ok, err = pcall(function()
        manager:SBCreateCharacter(FName(SPAWN_ALIAS),
            SPAWN_ARGS.forward, SPAWN_ARGS.right, SPAWN_ARGS.up, SPAWN_ARGS.yaw)
    end)
    Out(string.format("  called manager:SBCreateCharacter(%s, ...) -> %s",
        SPAWN_ALIAS, ok and "no error" or ("threw: " .. tostring(err))))
    Step, Ticks = "ufunction", 0
end

local function StepUFunction()
    if CollectSpawn("SBCreateCharacter/ufunction", Baseline.spawn) then
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
    Out("########## STEP 4 -- SBCreateCharacter, ConsoleCommand ##########")
    Out("  same function, same argument, different route")
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
    if CollectSpawn("SBCreateCharacter/console", Baseline.spawn) then
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
    Out("################ STEP 5 -- HUD, watch the screen ################")
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
    for _, entry in ipairs(Results) do
        Out(string.format("  %-8s %s", entry.verdict, entry.name))
    end
    Out("")

    local uf  = nil
    local con = nil
    for _, entry in ipairs(Results) do
        if entry.name == "SBCreateCharacter/ufunction" then uf  = entry.verdict end
        if entry.name == "SBCreateCharacter/console"   then con = entry.verdict end
    end

    Out("  THE COMPARISON THAT MATTERS")
    Out(string.format("    UFunction route:      %s", tostring(uf)))
    Out(string.format("    ConsoleCommand route: %s", tostring(con)))
    if con == "WORKED" and uf ~= "WORKED" then
        Out("    -> the route was the problem. 698 commands just opened up.")
    elseif con == "WORKED" and uf == "WORKED" then
        Out("    -> both work. Last session's failure was the ALIAS, not the")
        Out("       call. Check N_Lily against CharacterTable.")
    elseif con ~= "WORKED" and uf ~= "WORKED" then
        Out("    -> neither spawns. The class is reachable (slomo/battle state")
        Out("       prove that), so SBCreateCharacter specifically is either")
        Out("       stubbed or needs different arguments. Not the same as the")
        Out("       whole cheat manager being dead.")
    end
    Out("")
    Out("ALL DONE -- you can quit. Answer: did the HUD disappear?")
    Step = "finished"
end

-- -------------------------------------------------------------------- tick

local STEPS = {
    wait           = StepWait,
    control        = StepControl,
    slomo          = StepSlomo,
    ufunction      = StepUFunction,
    ufunction_done = StepUFunctionDone,
    console_spawn  = StepConsoleSpawn,
    hud            = StepHud,
    hud_wait       = StepHudWait,
    summary        = StepSummary,
}

local function Tick()
    if Step == "finished" then return end
    local handler = STEPS[Step]
    if handler then handler() end
    Ticks = Ticks + 1
end

Out("SBLoveFramework P9 -- can we reach the 698 cheat commands?")
Out("Load a save and stand still. About 40 seconds. Watch the screen at step 5.")
Out("")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)

pcall(RegisterOnUnloadCallback or function() end, function()
    Try(function() Console("slomo 1.0") end)
    Try(function() Console("SBGameOptionHUDVisible true") end)
end)
