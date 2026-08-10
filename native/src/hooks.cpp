/*
 * SBLoveNative -- inline hooks.
 *
 * WHY HOOKING IS THE WHOLE POINT OF THE NATIVE HALF
 *
 * UE4SS's Lua RegisterHook switches on global ProcessInternal interception, and
 * that was measured at 1-3 fps in this game regardless of how many hooks were
 * registered. Probe P8 abandoned the CustomAnimNode route for that reason
 * alone: the anim blueprint's event graph rewrites CustomAnimAlpha to 0 every
 * frame, so a polling timer can never win, and the only way to win is a hook.
 *
 * An inline hook patches one function's first instructions and costs nothing
 * anywhere else in the engine. That is the capability Lua could not offer.
 *
 * WHAT IS HOOKED FIRST, AND WHY IT IS NOT THE ANIM GRAPH
 *
 * A command channel, because the anim hook needs somewhere to send commands
 * from and something to prove the mechanism with.
 *
 * Milestone 2 established that all 698 USBCheatManager commands are hollow:
 * their bodies are compiled out and only the generated exec thunk survives,
 * which parses parameters, runs P_FINISH and returns. See docs/engine-api.md.
 *
 * But the thunks are still fully wired to the console. The command parses, the
 * arguments unmarshal, the dispatch happens. Only the body is missing. So
 * hooking one gives a working command channel into native code, using the
 * game's own console parser, with no new plumbing at all.
 *
 * SBChangeWorld is the pick:
 *   - it takes a single FString, so it can carry an arbitrary command
 *   - its thunk has a unique address, unlike SBPlayerBattleState and
 *     SBGameOptionHUDVisible which the linker folded together because both
 *     are empty
 *   - it is hollow, so nothing is being taken away from the game
 *
 * WHY A HARDCODED RVA IS SAFE HERE
 *
 * Milestone 1 measured the module loading at 0x140000000, its preferred base,
 * so RVAs apply directly. The RVA below was read from the shipped exe. It is
 * still verified at runtime before anything is patched, because a wrong address
 * would mean patching arbitrary code, and this is checked rather than trusted.
 */

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <cstdio>

#include "../deps/minhook/include/MinHook.h"

#include "hooks.hpp"

namespace
{
    /* execSBChangeWorld, read from SB-Win64-Shipping.exe. Verified before use
     * by matching its first bytes; see kExpectedPrologue. */
    constexpr uintptr_t kChangeWorldRva = 0x026977B0;

    /* The first bytes the disassembly showed at that RVA. If the game updates,
     * this stops matching and the hook refuses to install rather than patching
     * whatever now lives there.
     *
     *   48 89 5C 24 08    mov [rsp+8], rbx
     *   57                push rdi
     *   48 83 EC 40       sub rsp, 0x40
     */
    constexpr unsigned char kExpectedPrologue[] = {
        0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x40
    };

    /* A UE exec thunk. Context is the object the command ran on, Stack holds
     * the unparsed arguments, Result is where a return value would go.
     *
     * The signature matters: this is called by the engine's dispatcher with
     * Microsoft x64 conventions, which is why the DLL is built against the MSVC
     * ABI rather than mingw. */
    using ExecFunc = void(__fastcall*)(void* Context, void* Stack, void* Result);

    ExecFunc g_original_change_world = nullptr;

    volatile LONG g_change_world_calls = 0;

    Hooks::CommandCallback g_command_callback = nullptr;

    void __fastcall ChangeWorldDetour(void* Context, void* Stack, void* Result)
    {
        InterlockedIncrement(&g_change_world_calls);

        if (g_command_callback)
        {
            g_command_callback(Context, Stack);
        }

        /* Still call through. The original is hollow so this changes nothing
         * today, but calling the original is what keeps a hook honest: if the
         * body ever comes back, or the pick moves to a command that does have
         * one, the game keeps working. */
        if (g_original_change_world)
        {
            g_original_change_world(Context, Stack, Result);
        }
    }
}

namespace Hooks
{
    bool Install(uintptr_t module_base, LogFunc log, CommandCallback on_command)
    {
        g_command_callback = on_command;

        const auto target = module_base + kChangeWorldRva;
        auto* code = reinterpret_cast<const unsigned char*>(target);

        log("installing hooks");
        log("  execSBChangeWorld at RVA 0x%08llX -> 0x%016llX",
            static_cast<unsigned long long>(kChangeWorldRva),
            static_cast<unsigned long long>(target));

        /* Verify before patching. Writing a jump over the wrong function would
         * corrupt whatever actually lives there, and would do it silently. */
        if (memcmp(code, kExpectedPrologue, sizeof(kExpectedPrologue)) != 0)
        {
            char found[3 * sizeof(kExpectedPrologue) + 1]{};
            for (size_t i = 0; i < sizeof(kExpectedPrologue); ++i)
            {
                sprintf_s(found + i * 3, 4, "%02X ", code[i]);
            }
            log("  PROLOGUE MISMATCH, refusing to patch");
            log("    expected: 48 89 5C 24 08 57 48 83 EC 40");
            log("    found:    %s", found);
            log("  The game was probably updated. Re-read the RVA from the exe.");
            return false;
        }
        log("  prologue matches, safe to patch");

        if (MH_Initialize() != MH_OK)
        {
            log("  MH_Initialize failed");
            return false;
        }

        void* original = nullptr;
        if (MH_CreateHook(reinterpret_cast<void*>(target),
                          reinterpret_cast<void*>(&ChangeWorldDetour),
                          &original) != MH_OK)
        {
            log("  MH_CreateHook failed");
            return false;
        }
        g_original_change_world = reinterpret_cast<ExecFunc>(original);

        if (MH_EnableHook(reinterpret_cast<void*>(target)) != MH_OK)
        {
            log("  MH_EnableHook failed");
            return false;
        }

        log("  hook installed and enabled");
        log("");
        log("  Fire it from the Lua side with:");
        log("    ExecuteConsoleCommand(\"SBChangeWorld hello\")");
        return true;
    }

    long CommandCount()
    {
        return InterlockedCompareExchange(&g_change_world_calls, 0, 0);
    }

    void Remove()
    {
        MH_DisableHook(MH_ALL_HOOKS);
        MH_Uninitialize();
    }
}
