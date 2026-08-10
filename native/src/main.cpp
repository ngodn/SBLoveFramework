/*
 * SBLoveNative -- the native half of SBLoveFramework.
 *
 * WHY THIS EXISTS
 *
 * The Lua half can find objects and read properties, but two things it cannot
 * do are exactly the two things the framework needs most:
 *
 *   1. Hook a function cheaply. UE4SS's Lua RegisterHook switches on global
 *      ProcessInternal interception and costs 1-3 fps no matter how many hooks
 *      are installed. Probe P8 abandoned the CustomAnimNode route for this
 *      reason alone: the anim blueprint's event graph rewrites CustomAnimAlpha
 *      to 0 every frame, and a polling timer can never win that race. An inline
 *      hook on one function costs nothing and wins it every frame.
 *
 *   2. Call functions that have no UFunction behind them. UWorld::GetTimeSeconds
 *      is a plain C++ method, so Lua cannot reach it through reflection. Probe
 *      P9 hung for exactly this reason.
 *
 * WHY NOT THE UE4SS C++ MODDING API
 *
 * It cannot be built. The API's Unreal types live in a submodule, UEPseudo,
 * which has been deleted from GitHub (RE-UE4SS issues #577 and #796). Nobody
 * can build a UE4SS C++ mod from source right now.
 *
 * That turns out not to matter, and avoiding it removes a real risk. UE4SS
 * loads any DLL placed at Mods/<name>/dlls/main.dll, which is already proven on
 * this machine by SBAutoInput. Because this DLL never touches a UE4SS C++ type,
 * it cannot be broken by an ABI mismatch with UE4SS -- and there IS one to be
 * broken by: the installed build (SHA 47477f8) declares an extra virtual,
 * on_ui_init, that official v3.0.1 does not, which shifts every vtable slot
 * after it.
 *
 * MILESTONE 1, WHICH IS ALL THIS FILE DOES
 *
 * Prove the toolchain end to end: that a Linux-cross-compiled MSVC-ABI DLL
 * loads under the installed UE4SS, runs, and can report. It resolves the game
 * module and writes what it found. Nothing is hooked and nothing is patched.
 *
 * Establishing that the delivery mechanism works, on its own, before layering
 * behaviour on top, is deliberate. Several dead ends this project hit were
 * mechanisms that failed silently while the code on top looked correct.
 */

#include <windows.h>
#include <psapi.h>

#include <cstdarg>
#include <cwchar>
#include <cstring>
#include <cstdio>
#include <cstdint>

#include "hooks.hpp"

namespace
{
    constexpr const char* kVersion = "SBLoveNative milestone 1";

    HMODULE g_self = nullptr;
    HANDLE g_log = INVALID_HANDLE_VALUE;

    /* The log path is absolute and derived from where this DLL actually is,
     * never relative to the working directory.
     *
     * The first attempt used the relative path "ue4ss\SBLoveNative.txt" on the
     * assumption that the process working directory was Binaries\Win64, which
     * is where the Lua side's files land. It is not: UE4SS reports its working
     * directory as Binaries\Win64\ue4ss, so the path resolved into a directory
     * that does not exist, fopen failed, and every subsequent log call silently
     * did nothing. The DLL had loaded and run correctly the whole time.
     *
     * This DLL lives at <mod>\dlls\main.dll, so stripping two components lands
     * on the mod folder. */
    void LogOpen()
    {
        wchar_t path[MAX_PATH]{};
        if (!GetModuleFileNameW(g_self, path, MAX_PATH)) return;

        /* strip "main.dll", then strip "dlls" */
        for (int stripped = 0; stripped < 2; ++stripped)
        {
            wchar_t* slash = wcsrchr(path, L'\\');
            if (!slash) return;
            *slash = L'\0';
        }

        if (wcscat_s(path, MAX_PATH, L"\\SBLoveNative.txt") != 0) return;

        g_log = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    }

    void Log(const char* format, ...)
    {
        char line[1024];

        va_list args;
        va_start(args, format);
        int written = vsnprintf(line, sizeof(line) - 2, format, args);
        va_end(args);

        if (written < 0) return;
        line[written++] = '\n';
        line[written] = '\0';

        /* Always emit to the debugger stream as well. If the file could not be
         * opened, this is the only way the failure is visible at all, and a
         * silent logger is precisely what cost the last run. */
        OutputDebugStringA(line);

        if (g_log != INVALID_HANDLE_VALUE)
        {
            DWORD ignored = 0;
            WriteFile(g_log, line, static_cast<DWORD>(written), &ignored, nullptr);
            FlushFileBuffers(g_log);
        }
    }

    /* The game's own module, which is where every offset in
     * research/CXXHeaderDump is relative to. Everything native depends on
     * resolving this, so it is the first thing proven. */
    struct ModuleInfo
    {
        HMODULE handle = nullptr;
        uintptr_t base = 0;
        size_t size = 0;
        char name[MAX_PATH] = {};
    };

    bool ResolveGameModule(ModuleInfo& out)
    {
        /* The executable is the main module: passing null asks for it by
         * definition, so this cannot pick up a DLL by mistake. */
        out.handle = GetModuleHandleW(nullptr);
        if (!out.handle) return false;

        MODULEINFO info{};
        if (!GetModuleInformation(GetCurrentProcess(), out.handle,
                                  &info, sizeof(info)))
        {
            return false;
        }

        out.base = reinterpret_cast<uintptr_t>(info.lpBaseOfDll);
        out.size = info.SizeOfImage;
        GetModuleFileNameA(out.handle, out.name, MAX_PATH);
        return true;
    }

    /* Build an absolute path to a file in the ue4ss folder, which is four
     * directories up from <mod>\dlls\main.dll. Never relative: assuming the
     * working directory is what silently broke milestone 1's logging. */
    bool Ue4ssPath(const wchar_t* leaf, wchar_t* out, size_t count)
    {
        if (!GetModuleFileNameW(g_self, out, static_cast<DWORD>(count))) return false;
        for (int stripped = 0; stripped < 4; ++stripped)
        {
            wchar_t* slash = wcsrchr(out, L'\\');
            if (!slash) return false;
            *slash = L'\0';
        }
        return wcscat_s(out, count, leaf) == 0;
    }

    /* The Lua side finds Eve's anim instance and writes its address here. Lua
     * can find the object; only native code can order a write after the event
     * graph, which is the whole problem P8 could not solve. */
    bool ReadAnimRequest(const ModuleInfo& game)
    {
        wchar_t path[MAX_PATH]{};
        if (!Ue4ssPath(L"\\SBLove_anim.txt", path, MAX_PATH)) return false;
        if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) return false;

        HANDLE file = CreateFileW(path, GENERIC_READ,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;

        char buffer[512]{};
        DWORD read = 0;
        ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
        CloseHandle(file);
        buffer[read] = '\0';

        unsigned long long instance = 0;
        unsigned offset = 0;
        float value = 1.0f;
        if (sscanf_s(buffer, "instance=0x%llx offset=0x%x value=%f",
                     &instance, &offset, &value) < 2)
        {
            Log("SBLove_anim.txt is malformed: %s", buffer);
            return false;
        }

        Log("");
        Log("######## MILESTONE 4 -- winning the CustomAnimAlpha race ########");
        Log("");
        if (!Hooks::HoldAnimAlpha(game.base, Log,
                                  reinterpret_cast<void*>(instance),
                                  offset, value))
        {
            return false;
        }

        /* An optional second line asks for a limb pose. Lua sets BoneToModify,
         * because that is an FName; native holds the numbers, because they are
         * exposed pins the graph re-copies every frame. */
        const char* pose_line = strstr(buffer, "pose=");
        if (pose_line)
        {
            unsigned long long node = 0;
            float pitch = 0.0f, yaw = 0.0f, roll = 0.0f;
            unsigned mode = 2, space = 3;
            if (sscanf_s(pose_line,
                         "pose=0x%llx pitch=%f yaw=%f roll=%f mode=%u space=%u",
                         &node, &pitch, &yaw, &roll, &mode, &space) >= 4)
            {
                Log("");
                Log("######## MILESTONE 5 -- procedural posing ########");
                Log("");
                Hooks::Pose pose{};
                pose.node = reinterpret_cast<void*>(node);
                pose.pitch = pitch;
                pose.yaw = yaw;
                pose.roll = roll;
                pose.rotation_mode = static_cast<uint8_t>(mode);
                pose.rotation_space = static_cast<uint8_t>(space);
                Hooks::HoldPose(pose, Log);
            }
            else
            {
                Log("pose line present but malformed, ignoring it");
            }
        }
        return true;
    }

    /* Runs when the hijacked console command fires.
     *
     * The FString argument is still sitting unparsed in the FFrame. Reading it
     * means walking the VM's parameter state, which is the next step; for now
     * this proves our code runs at all, which is the thing being tested. */
    void OnConsoleCommand(void* Context, void* Stack)
    {
        Log("  -> detour ran. Context=0x%016llX Stack=0x%016llX",
            reinterpret_cast<unsigned long long>(Context),
            reinterpret_cast<unsigned long long>(Stack));
    }

    DWORD WINAPI Main(LPVOID)
    {
        LogOpen();
        Log("%s", kVersion);
        Log("built on Linux with clang-cl, MSVC ABI, x86_64");
        Log("");

        ModuleInfo game{};
        if (!ResolveGameModule(game))
        {
            Log("FAILED to resolve the game module (error %lu)", GetLastError());
            Log("");
            Log("Nothing native can work without this, since every offset in");
            Log("the dumped SDK is relative to the module base.");
            return 1;
        }

        Log("game module resolved");
        Log("  path: %s", game.name);
        Log("  base: 0x%016llX", static_cast<unsigned long long>(game.base));
        Log("  size: 0x%08zX (%zu MB)", game.size, game.size / (1024 * 1024));
        Log("");

        /* A default-ASLR UE4 shipping build normally lands high; a base of
         * 0x140000000 means the image loaded at its preferred address. Neither
         * is wrong, but which one it is decides whether offsets can be applied
         * directly or have to be rebased, so it is worth stating outright. */
        if (game.base == 0x140000000ULL)
        {
            Log("  loaded at its preferred base, so dumped RVAs apply directly");
        }
        else
        {
            Log("  relocated, so dumped RVAs must be added to the base above");
        }

        Log("");
        Log("MILESTONE 1 PASSED");
        Log("  A Linux-built MSVC-ABI DLL loaded under the installed UE4SS,");
        Log("  ran, and resolved the game module. The delivery mechanism works.");
        Log("");

        /* ---------------------------------------------------- milestone 3 */

        Log("################ MILESTONE 3 -- inline hooking ################");
        Log("");
        const bool hooked = Hooks::Install(game.base, Log, OnConsoleCommand);
        Log("");

        if (hooked)
        {
            /* Report on change rather than on a clock, so the log stays quiet
             * until something actually happens and then says so immediately. */
            Log("watching for the command. Run this from the Lua side:");
            Log("  ExecuteConsoleCommand(\"SBChangeWorld sblove-test\")");
            Log("");

            long last = 0;
            bool announced_alpha = false;
            long last_writes = 0;

            for (int attempt = 0; attempt < 900; ++attempt)
            {
                const long now = Hooks::CommandCount();
                if (now != last)
                {
                    Log("HOOK FIRED -- %ld call%s so far", now, now == 1 ? "" : "s");
                    last = now;
                }

                /* The Lua side writes this once it has found Eve's anim
                 * instance, which cannot happen before gameplay. */
                if (!announced_alpha && ReadAnimRequest(game))
                {
                    announced_alpha = true;
                }

                if (announced_alpha)
                {
                    const long writes = Hooks::AlphaWrites();
                    if (writes > 0 && last_writes == 0)
                    {
                        Log("");
                        Log("ALPHA HELD -- first re-assertion landed");
                        Log("  %ld writes, %ld ProcessEvent calls seen",
                            writes, Hooks::ProcessEventCalls());
                        Log("  The write is now ordered AFTER the event graph,");
                        Log("  which is what a Lua timer could never do.");
                    }
                    else if (writes > 0 && (attempt % 20) == 0)
                    {
                        Log("  holding: %ld alpha / %ld pose / %ld ProcessEvent",
                            writes, Hooks::PoseWrites(),
                            Hooks::ProcessEventCalls());
                    }
                    last_writes = writes;
                }

                Sleep(500);
            }
        }
        return 0;
    }
}

/* UE4SS looks for these when it loads a C++ mod. Exporting them keeps it from
 * reporting the DLL as broken. They intentionally do nothing: this mod does not
 * use the UE4SS C++ API, because that API cannot currently be built. */
extern "C"
{
    __declspec(dllexport) void* start_mod()
    {
        return nullptr;
    }

    __declspec(dllexport) void uninstall_mod(void*)
    {
    }
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_self = module;
        DisableThreadLibraryCalls(module);
        /* Real work goes on its own thread. Doing it inside DllMain runs under
         * the loader lock, where almost everything interesting deadlocks. */
        CloseHandle(CreateThread(nullptr, 0, Main, nullptr, 0, nullptr));
    }
    return TRUE;
}
