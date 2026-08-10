--[[
    SBLoveFramework -- fire the hijacked console command (P11)
    ------------------------------------------------------------------
    WHAT IS BEING TESTED

    SBLoveNative has patched an inline hook over execSBChangeWorld. That command
    is hollow -- milestone 2 disassembled it and found parameters parsed,
    P_FINISH run, and nothing called -- but it is still fully wired to the
    console: the name resolves, the argument unmarshals, the dispatch happens.

    So if the hook works, running the command from here should run OUR code
    inside the game process, using the game's own console parser as the
    transport. That would give the mod a command channel with no new plumbing.

    This script sends the command. The native log records whether it arrived:
        ue4ss/Mods/SBLoveNative/SBLoveNative.txt

    THE SECOND QUESTION: WHAT DOES THE HOOK COST

    UE4SS's Lua RegisterHook was measured at 1-3 fps in this game, because it
    switches on global ProcessInternal interception for every UFunction call in
    the engine. That single fact is why the CustomAnimNode route was abandoned
    in P8, and why the native half exists at all.

    An inline hook should cost nothing measurable, because it patches one
    function and touches nothing else. "Should" is not evidence, so this
    measures frame time before and after firing the command, over the same
    number of samples, and reports both.

    The measurement is deliberately coarse. It is not trying to detect a 1%
    regression; it is trying to distinguish "no measurable cost" from the 1-3
    fps cliff that made the Lua route unusable. Those differ by an order of
    magnitude and a crude instrument can tell them apart.

    WHAT TO DO
      Load a save, stand still, press nothing. About 40 seconds.

    Output: ue4ss/SBLoveFramework_probe.txt
--]]

local Actors = require("actors")

local OutputFile = "ue4ss/SBLoveFramework_probe.txt"
local POLL_MS    = 250
local SAMPLES    = 40   -- 10 seconds per phase at 250 ms

-- --------------------------------------------------------------------- io

local handle = io.open(OutputFile, "w")

local function Out(line)
    line = tostring(line)
    print("[SBLove/P11] " .. line .. "\n")
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
    return Try(FindFirstOf, "PlayerController")
end

local KismetCache = nil
local function Kismet()
    if IsLive(KismetCache) then return KismetCache end
    KismetCache = Try(StaticFindObject,
        "/Script/Engine.Default__KismetSystemLibrary")
    return IsLive(KismetCache) and KismetCache or nil
end

--- The route P9 proved works. PlayerController:ConsoleCommand never did.
local function Console(command)
    local kismet = Kismet()
    local controller = Controller()
    if not kismet or not IsLive(controller) then return false end
    local world = Try(function() return controller:GetWorld() end)
    if not IsLive(world) then return false end
    return pcall(function()
        kismet:ExecuteConsoleCommand(world, command, controller)
    end)
end

--- Game time, used to derive frame pacing. UWorld::GetTimeSeconds has no
--- UFunction behind it, which is what hung the first P9; these two are
--- BlueprintCallable and therefore actually reachable.
local function GameSeconds()
    local controller = Controller()
    if not IsLive(controller) then return nil end
    local world = Try(function() return controller:GetWorld() end)
    if not IsLive(world) then return nil end

    local kismet = Kismet()
    if kismet then
        local value = Try(function() return kismet:GetGameTimeInSeconds(world) end)
        if type(value) == "number" then return value end
    end
    local statics = Try(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if IsLive(statics) then
        local value = Try(function() return statics:GetTimeSeconds(world) end)
        if type(value) == "number" then return value end
    end
    return nil
end

-- ------------------------------------------------------------------ state

local Step, Ticks = "wait", 0
local Before, After = {}, {}

local function Mean(samples)
    if #samples < 2 then return nil end
    local total = 0
    for i = 2, #samples do total = total + (samples[i] - samples[i - 1]) end
    return total / (#samples - 1)
end

local function Report()
    local before = Mean(Before)
    local after  = Mean(After)

    Out("")
    Out("################ RESULT ################")
    if not before or not after then
        Out("  could not measure game time, no cost verdict")
    else
        Out(string.format("  game seconds per tick before: %.4f", before))
        Out(string.format("  game seconds per tick after:  %.4f", after))
        local change = before > 0 and ((after - before) / before) * 100.0 or 0
        Out(string.format("  change: %+.1f%%", change))
        Out("")
        if math.abs(change) < 10.0 then
            Out("  No meaningful change. The inline hook is free, unlike")
            Out("  UE4SS's Lua RegisterHook which cost 1-3 fps here.")
        else
            Out("  The rate moved. Worth investigating before hooking anything")
            Out("  that runs every frame.")
        end
    end
    Out("")
    Out("  Whether the hook actually FIRED is in the native log:")
    Out("    ue4ss/Mods/SBLoveNative/SBLoveNative.txt")
    Out("  It should say: HOOK FIRED")
    Out("")
    Out("ALL DONE -- you can quit.")
end

local function Tick()
    if Step == "finished" then return end

    if Step == "wait" then
        if not Actors.InGameplay() then
            if Ticks % 20 == 0 then Out("waiting for gameplay (not the menu)") end
            Ticks = Ticks + 1
            return
        end
        Out("")
        Out("in gameplay")
        Out("measuring frame pacing BEFORE firing the command")
        Step, Ticks = "before", 0
        return
    end

    if Step == "before" then
        local now = GameSeconds()
        if now then Before[#Before + 1] = now end
        Ticks = Ticks + 1
        if Ticks >= SAMPLES then
            Out(string.format("  %d samples", #Before))
            Out("")
            Out("################ FIRING THE HOOKED COMMAND ################")
            Out("  ExecuteConsoleCommand(\"SBChangeWorld sblove-test\")")
            local ok = Console("SBChangeWorld sblove-test")
            Out("  sent: " .. tostring(ok))
            Out("  (the return value means nothing; the native log is the proof)")
            Out("")
            Out("measuring frame pacing AFTER")
            Step, Ticks = "after", 0
        end
        return
    end

    if Step == "after" then
        local now = GameSeconds()
        if now then After[#After + 1] = now end
        Ticks = Ticks + 1

        -- Fire a few more times so a single-shot fluke is distinguishable from
        -- a working channel, and so the native counter has something to count.
        if Ticks == 10 or Ticks == 20 then
            Console("SBChangeWorld sblove-test-" .. Ticks)
        end

        if Ticks >= SAMPLES then
            Report()
            Step = "finished"
        end
        return
    end
end

Out("SBLoveFramework P11 -- does the inline hook fire, and what does it cost?")
Out("Load a save, stand still. About 40 seconds.")
Out("")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)
