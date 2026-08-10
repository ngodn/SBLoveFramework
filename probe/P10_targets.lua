--[[
    SBLoveFramework -- hand UFunction addresses to the native side (P10)
    ------------------------------------------------------------------
    THE QUESTION

    P9 established, with a control that passed, that the console is reachable:
    slomo halved the game's time rate through
    KismetSystemLibrary.ExecuteConsoleCommand. And it established that
    SBCreateCharacter does nothing through that same working console, by either
    route, with an alias verified against the shipped CharacterTable:

        N_Lily
        N_Lily_BasicCostume

    So the command reaches a live console with valid arguments and has no
    effect. The usual reason is that shipping builds strip cheat bodies. That is
    a guess, and this project has been burned by acting on those.

    HOW THIS ANSWERS IT

    A UFunction holds a pointer to its native implementation. If the body was
    stripped, that implementation is a stub, and a stub is visible in its first
    few instructions.

    Lua can find the UFunction object and read its address. Lua cannot read a
    raw field at a fixed offset inside it. Native can. So this script only
    collects addresses and writes them out; SBLoveNative reads the Func pointer
    and reports it.

    THE CONTROL

    Addresses are collected for commands that WORK as well as the one that does
    not. Without that, a stub-looking body proves nothing, because there would
    be no example of what a working body looks like in this binary.

        SBPlayerBattleState   probe_v13 recorded this one firing
        SBCreateCharacter     does nothing
        SBChangeWorld         untested, and central to the mode engine
        SBGameOptionHUDVisible  untested, cheap to confirm visually

    UFunction::Func is at +0xD8: CoreUObject.hpp gives UFunction a size of 0xE0,
    and Func is its final member, a pointer. The native side treats that as an
    assumption to be checked rather than a fact, and reports what it reads so a
    wrong offset shows up as nonsense rather than as a confident wrong answer.

    Output: ue4ss/SBLove_targets.txt, read by SBLoveNative.
--]]

local Actors = require("actors")

local TargetsFile = "ue4ss/SBLove_targets.txt"
local OutputFile  = "ue4ss/SBLoveFramework_probe.txt"
local POLL_MS     = 1000

--- Functions to locate. Verdict records what is already known about each, so
--- the native report can be read against expectations instead of in a vacuum.
local CHEATS   = "/Script/SB.SBCheatManager"
local KISMET   = "/Script/Engine.KismetSystemLibrary"
local GAMEPLAY = "/Script/Engine.GameplayStatics"

local WANTED = {
    -- The controls. These are KNOWN to work: P9 changed the game's time rate
    -- through ExecuteConsoleCommand and read its clock through
    -- GetGameTimeInSeconds. Their disassembly is what a live exec thunk looks
    -- like in THIS binary, which is the only fair comparison.
    --
    -- The first run had no such control. It used SBPlayerBattleState on the
    -- strength of probe_v13 reporting it fired, and that reading is now
    -- suspect: SBPlayerBattleState and SBGameOptionHUDVisible share one
    -- folded implementation, and two different cheats can only be byte
    -- identical if neither has a body.
    { class = KISMET,   name = "ExecuteConsoleCommand", verdict = "CONTROL, works (P9)" },
    { class = GAMEPLAY, name = "GetTimeSeconds",        verdict = "CONTROL, works (P9)" },

    -- The subjects.
    { class = CHEATS, name = "SBCreateCharacter",      verdict = "does nothing (P9)" },
    { class = CHEATS, name = "SBChangeWorld",          verdict = "mode engine depends on it" },
    { class = CHEATS, name = "SBPlayCustomAnimByTag",  verdict = "mode engine depends on it" },
    { class = CHEATS, name = "SBPlayerBattleState",    verdict = "folded with HUDVisible" },
    { class = CHEATS, name = "SBGameOptionHUDVisible", verdict = "folded with BattleState" },
}

-- --------------------------------------------------------------------- io

local handle = io.open(OutputFile, "w")

local function Out(line)
    line = tostring(line)
    print("[SBLove/P10] " .. line .. "\n")
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

-- ---------------------------------------------------------------- lookup

--- Find a UFunction on the cheat manager class.
---
--- Functions are outered to their class, so the path is Class:Function. Both
--- separators are tried because getting this wrong returns nil, which looks
--- exactly like "the function does not exist" and would be a misleading answer
--- to the actual question.
local function FindFunction(class, name)
    local paths = {
        class .. ":" .. name,
        class .. "." .. name,
    }
    for _, path in ipairs(paths) do
        local object = Try(StaticFindObject, path)
        if IsLive(object) then return object, path end
    end
    return nil, nil
end

local function AddressOf(object)
    local address = Try(function() return object:GetAddress() end)
    if type(address) == "number" then return address end
    return nil
end

-- ------------------------------------------------------------------ state

local Step, Ticks = "wait", 0

local function Collect()
    local lines = {}
    local found, missing = 0, 0

    Out("")
    Out("################ COLLECTING UFUNCTIONS ################")

    for _, entry in ipairs(WANTED) do
        local object, path = FindFunction(entry.class, entry.name)
        if not object then
            Out(string.format("  %-24s NOT FOUND", entry.name))
            missing = missing + 1
        else
            local address = AddressOf(object)
            if not address then
                Out(string.format("  %-24s found, but GetAddress failed",
                    entry.name))
                missing = missing + 1
            else
                Out(string.format("  %-24s 0x%X  (%s)", entry.name, address,
                    entry.verdict))
                lines[#lines + 1] = string.format("%s=0x%X=%s",
                    entry.name, address, entry.verdict)
                found = found + 1
            end
        end
    end

    Out("")
    Out(string.format("  %d found, %d missing", found, missing))

    if found == 0 then
        Out("")
        Out("  Nothing to hand over. Either the path form is wrong or these")
        Out("  functions are not reflected objects in this build. Both are")
        Out("  answers, but neither is the one being asked.")
        return false
    end

    local file = io.open(TargetsFile, "w")
    if not file then
        Out("  could not write " .. TargetsFile)
        return false
    end
    file:write("# written by P10 for SBLoveNative\n")
    for _, line in ipairs(lines) do file:write(line, "\n") end
    file:close()

    Out("")
    Out("  wrote " .. TargetsFile)
    Out("  SBLoveNative reads it, follows Func at +0xD8, and reports.")
    Out("  Its log: ue4ss/Mods/SBLoveNative/SBLoveNative.txt")
    return true
end

local function Tick()
    if Step == "finished" then return end

    if Step == "wait" then
        if not Actors.InGameplay() then
            if Ticks % 5 == 0 then Out("waiting for gameplay (not the menu)") end
            Ticks = Ticks + 1
            return
        end
        Out("")
        Out("in gameplay, collecting")
        Collect()
        Out("")
        Out("ALL DONE -- you can quit.")
        Step = "finished"
    end
end

Out("SBLoveFramework P10 -- hand UFunction addresses to the native side")
Out("Load a save, stand still. This only reads; it changes nothing.")
Out("")

pcall(LoopAsync, POLL_MS, function()
    ExecuteInGameThread(Tick)
    return false
end)
