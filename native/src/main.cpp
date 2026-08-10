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
#include <cstdio>
#include <cstdint>

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
        Log("  Nothing is hooked and nothing is patched. Next is an inline hook");
        Log("  on the anim update, which is the thing Lua provably cannot do.");
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
