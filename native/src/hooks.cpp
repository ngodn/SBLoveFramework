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

    /* ------------------------------------------------------- the anim race */

    /* From ue4ss/UE4SS.log, which resolves these for this exact binary:
     *     ProcessEvent address 0x142b744c0
     * The module loads at its preferred base 0x140000000, so this is the RVA. */
    constexpr uintptr_t kProcessEventRva = 0x02B744C0;

    /* Checked before patching. ProcessEvent runs for every UFunction call in
     * the engine, so patching the wrong address here is far more destructive
     * than getting a hollow cheat wrong.
     *
     *   40 55             push rbp
     *   56                push rsi
     *   57                push rdi
     *   41 54             push r12
     */
    constexpr unsigned char kProcessEventPrologue[] = {
        0x40, 0x55, 0x56, 0x57, 0x41, 0x54
    };

    /* Where a 6-byte rip-relative jmp lands. FF 25 <disp32> reads a pointer
     * from [rip + disp], and rip is the address of the next instruction, so
     * the slot is at code + 6 + disp and the destination is what it holds. */
    uintptr_t target_of_jump(const unsigned char* code, int32_t displacement)
    {
        const auto slot = reinterpret_cast<uintptr_t>(code) + 6 + displacement;
        if (IsBadReadPtr(reinterpret_cast<void*>(slot), sizeof(uintptr_t)))
        {
            return 0;
        }
        return *reinterpret_cast<const uintptr_t*>(slot);
    }

    /* void UObject::ProcessEvent(UFunction* Function, void* Parms)
     * A member function, so under Microsoft x64 `this` arrives in RCX. */
    using ProcessEventFunc = void(__fastcall*)(void* Object, void* Function,
                                               void* Parms);

    ProcessEventFunc g_original_process_event = nullptr;

    void* g_anim_instance = nullptr;
    uint32_t g_alpha_offset = 0;
    float g_alpha_value = 1.0f;

    volatile LONG g_alpha_writes = 0;
    volatile LONG g_process_event_calls = 0;

    /* Field offsets inside FAnimNode_ModifyBone (AnimGraphRuntime.hpp:345),
     * where Alpha comes from its base FAnimNode_SkeletalControlBase. */
    constexpr size_t kModifyBoneAlpha         = 0x2C;
    constexpr size_t kModifyBoneRotation      = 0xE4;
    constexpr size_t kModifyBoneRotationMode  = 0xFD;
    constexpr size_t kModifyBoneRotationSpace = 0x100;

    Hooks::Pose g_pose{};
    volatile LONG g_pose_writes = 0;

    /* Re-assert the pose. Called only from the detour, after the original, so
     * it lands after the graph has re-copied its exposed pins. */
    inline void ApplyPose()
    {
        const auto node = reinterpret_cast<uintptr_t>(g_pose.node);

        *reinterpret_cast<float*>(node + kModifyBoneAlpha) = g_pose.alpha;

        /* FRotator is pitch, yaw, roll as three consecutive floats. */
        auto* rotation = reinterpret_cast<float*>(node + kModifyBoneRotation);
        rotation[0] = g_pose.pitch;
        rotation[1] = g_pose.yaw;
        rotation[2] = g_pose.roll;

        *reinterpret_cast<uint8_t*>(node + kModifyBoneRotationMode) =
            g_pose.rotation_mode;
        *reinterpret_cast<uint8_t*>(node + kModifyBoneRotationSpace) =
            g_pose.rotation_space;

        InterlockedIncrement(&g_pose_writes);
    }

    void __fastcall ProcessEventDetour(void* Object, void* Function, void* Parms)
    {
        /* Everything before the original runs on EVERY UFunction call in the
         * engine, so it is one load, one compare and one increment. Anything
         * heavier here is the fps cliff that made the Lua route unusable. */
        InterlockedIncrement(&g_process_event_calls);

        if (g_original_process_event)
        {
            g_original_process_event(Object, Function, Parms);
        }

        /* After, so the write lands after the event graph has set the alpha to
         * zero. This ordering is the entire point; doing it before the original
         * would reproduce P8's failure exactly. */
        if (Object != nullptr && Object == g_anim_instance)
        {
            auto* alpha = reinterpret_cast<float*>(
                reinterpret_cast<uintptr_t>(Object) + g_alpha_offset);
            *alpha = g_alpha_value;
            InterlockedIncrement(&g_alpha_writes);

            if (g_pose.node != nullptr) ApplyPose();
        }
    }

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

    bool HoldAnimAlpha(uintptr_t module_base, LogFunc log,
                       void* anim_instance, uint32_t alpha_offset, float value)
    {
        const auto target = module_base + kProcessEventRva;

        log("holding CustomAnimAlpha");
        log("  anim instance: 0x%016llX",
            reinterpret_cast<unsigned long long>(anim_instance));
        log("  alpha offset:  +0x%X", alpha_offset);
        log("  value:         %.2f", value);
        log("  ProcessEvent at RVA 0x%08llX -> 0x%016llX",
            static_cast<unsigned long long>(kProcessEventRva),
            static_cast<unsigned long long>(target));

        /* The address came from UE4SS's own log for this exact binary, which
         * makes it well sourced but not verified. Patching the wrong function
         * here would be far worse than with a hollow cheat: ProcessEvent runs
         * for every UFunction call in the engine. */
        auto* code = reinterpret_cast<const unsigned char*>(target);
        char found[3 * sizeof(kProcessEventPrologue) + 1]{};
        for (size_t i = 0; i < sizeof(kProcessEventPrologue); ++i)
        {
            sprintf_s(found + i * 3, 4, "%02X ", code[i]);
        }
        log("  prologue: %s", found);

        /* Three cases, and only the last is a refusal.
         *
         * The expected prologue means nobody else has touched it.
         *
         * A rip-relative jmp (FF 25) means somebody hooked it first. That is
         * the normal case here: UE4SS hooks ProcessEvent for its own callbacks
         * before our DLL runs, and the jump target lands outside the game
         * module, which is how a foreign hook announces itself.
         *
         * Chaining onto that is fine and is what MinHook is for: our detour
         * goes first, its trampoline holds the relocated jmp, and calling the
         * original lands in UE4SS's detour and then the real function. What is
         * NOT fine is assuming an unrecognised prologue is safe, because
         * patching over another mod's trampoline would corrupt it, and CNS and
         * everything else running under UE4SS would go down with it. */
        const bool pristine = memcmp(code, kProcessEventPrologue,
                                     sizeof(kProcessEventPrologue)) == 0;
        const bool jump_thunk = code[0] == 0xFF && code[1] == 0x25;

        if (pristine)
        {
            log("  prologue is the original, nobody else has hooked this");
        }
        else if (jump_thunk)
        {
            const auto displacement =
                *reinterpret_cast<const int32_t*>(code + 2);
            const auto target = target_of_jump(code, displacement);
            const bool foreign = target < module_base ||
                                 target >= module_base + 0x14400000ULL;
            log("  already hooked by someone else (jmp -> 0x%016llX%s)",
                static_cast<unsigned long long>(target),
                foreign ? ", outside the game module" : "");
            log("  chaining after them rather than patching over their hook");
        }
        else
        {
            log("  PROLOGUE UNRECOGNISED, refusing to patch ProcessEvent");
            log("  Not the original, and not a jump thunk either. Patching");
            log("  blindly here would corrupt whatever is actually there, and");
            log("  ProcessEvent runs for every UFunction call in the engine.");
            log("  Re-read 'ProcessEvent address' from ue4ss/UE4SS.log.");
            return false;
        }

        g_anim_instance = anim_instance;
        g_alpha_offset = alpha_offset;
        g_alpha_value = value;

        void* original = nullptr;
        if (MH_CreateHook(reinterpret_cast<void*>(target),
                          reinterpret_cast<void*>(&ProcessEventDetour),
                          &original) != MH_OK)
        {
            log("  MH_CreateHook failed on ProcessEvent");
            return false;
        }
        g_original_process_event = reinterpret_cast<ProcessEventFunc>(original);

        if (MH_EnableHook(reinterpret_cast<void*>(target)) != MH_OK)
        {
            log("  MH_EnableHook failed on ProcessEvent");
            return false;
        }

        log("  ProcessEvent hooked; alpha is re-asserted after every event");
        return true;
    }

    long AlphaWrites()
    {
        return InterlockedCompareExchange(&g_alpha_writes, 0, 0);
    }

    long ProcessEventCalls()
    {
        return InterlockedCompareExchange(&g_process_event_calls, 0, 0);
    }

    void HoldPose(const Pose& pose, LogFunc log)
    {
        log("holding a pose on ModifyBone node 0x%016llX",
            reinterpret_cast<unsigned long long>(pose.node));
        log("  rotation: pitch %.1f yaw %.1f roll %.1f",
            pose.pitch, pose.yaw, pose.roll);
        log("  mode %u (0 ignore, 1 replace, 2 additive), space %u",
            pose.rotation_mode, pose.rotation_space);
        log("  alpha %.2f", pose.alpha);
        log("  held after every ProcessEvent, because a ModifyBone node's");
        log("  fields are exposed pins and the graph re-copies them per frame");

        /* Assigned last. The detour reads g_pose.node to decide whether to
         * apply anything, so filling the rest first means it can never see a
         * live pointer beside a half-written pose. */
        g_pose = pose;
    }

    void ClearPose()
    {
        g_pose.node = nullptr;
    }

    long PoseWrites()
    {
        return InterlockedCompareExchange(&g_pose_writes, 0, 0);
    }

    void Remove()
    {
        MH_DisableHook(MH_ALL_HOOKS);
        MH_Uninitialize();
    }
}
