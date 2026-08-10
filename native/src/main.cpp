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

    /* ------------------------------------------------------ milestone 2 */

    /* UFunction::Func, the pointer to the native implementation.
     *
     * CoreUObject.hpp gives UFunction a size of 0xE0 and Func is its final
     * member, a pointer, so it sits at 0xD8. The dump lists no members for
     * UFunction, so this is derived rather than read, and it is treated as an
     * assumption to be checked: everything read through it is reported raw so a
     * wrong offset shows up as obvious nonsense instead of a confident wrong
     * answer. A Func inside the module's address range is the sanity check. */
    constexpr size_t kUFunctionFuncOffset = 0xD8;

    /* Is this address readable? Asking the OS beats trusting an address that
     * arrived from another process's log file. */
    bool Readable(const void* address, size_t bytes)
    {
        MEMORY_BASIC_INFORMATION info{};
        if (!VirtualQuery(address, &info, sizeof(info))) return false;
        if (info.State != MEM_COMMIT) return false;

        const DWORD readable = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                               PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                               PAGE_EXECUTE_WRITECOPY;
        if (!(info.Protect & readable)) return false;
        if (info.Protect & PAGE_GUARD) return false;

        const auto start = reinterpret_cast<uintptr_t>(address);
        const auto end = reinterpret_cast<uintptr_t>(info.BaseAddress) + info.RegionSize;
        return start + bytes <= end;
    }

    /* Read "NAME=0xADDR=note" lines that the Lua side wrote. Lua can find a
     * UFunction object but cannot read a raw field inside it; that is the whole
     * reason this half exists. */
    void ReportTargets(const ModuleInfo& game)
    {
        wchar_t path[MAX_PATH]{};
        if (!GetModuleFileNameW(g_self, path, MAX_PATH)) return;

        /* main.dll -> dlls -> SBLoveNative -> Mods, landing on ue4ss */
        for (int stripped = 0; stripped < 4; ++stripped)
        {
            wchar_t* slash = wcsrchr(path, L'\\');
            if (!slash) return;
            *slash = L'\0';
        }
        if (wcscat_s(path, MAX_PATH, L"\\SBLove_targets.txt") != 0) return;

        HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            Log("no targets file yet; run the P10 Lua probe to produce one");
            Log("  expected at ue4ss\\SBLove_targets.txt");
            return;
        }

        char buffer[4096]{};
        DWORD read = 0;
        ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
        CloseHandle(file);
        buffer[read] = '\0';

        Log("");
        Log("################ MILESTONE 2 -- are the cheat bodies real? ################");
        Log("");
        Log("  UFunction::Func assumed at +0x%zX (UFunction size 0xE0, Func last)",
            kUFunctionFuncOffset);
        Log("  A Func inside the module means the offset is right.");
        Log("");

        for (char* line = buffer; line && *line;)
        {
            char* next = strchr(line, '\n');
            if (next) *next++ = '\0';

            if (*line != '#' && *line)
            {
                char name[128]{};
                unsigned long long address = 0;
                if (sscanf_s(line, "%127[^=]=0x%llx", name,
                             static_cast<unsigned>(sizeof(name)), &address) == 2)
                {
                    const char* note = strchr(line, '=');
                    note = note ? strchr(note + 1, '=') : nullptr;
                    note = note ? note + 1 : "";

                    Log("  %s  (%s)", name, note);
                    Log("    UFunction object: 0x%016llX", address);

                    auto* slot = reinterpret_cast<void**>(
                        static_cast<uintptr_t>(address) + kUFunctionFuncOffset);

                    if (!Readable(slot, sizeof(void*)))
                    {
                        Log("    UNREADABLE at +0x%zX -- address or offset is wrong",
                            kUFunctionFuncOffset);
                        Log("");
                        line = next;
                        continue;
                    }

                    auto func = reinterpret_cast<uintptr_t>(*slot);
                    const bool in_module = func >= game.base &&
                                           func < game.base + game.size;

                    Log("    Func:             0x%016llX%s",
                        static_cast<unsigned long long>(func),
                        in_module ? "" : "   <-- OUTSIDE the module, offset suspect");

                    if (in_module)
                    {
                        Log("    RVA:              0x%08llX",
                            static_cast<unsigned long long>(func - game.base));
                    }

                    if (Readable(reinterpret_cast<void*>(func), 32))
                    {
                        const auto* code = reinterpret_cast<const unsigned char*>(func);
                        char hex[3 * 32 + 1]{};
                        for (int i = 0; i < 32; ++i)
                        {
                            sprintf_s(hex + i * 3, 4, "%02X ", code[i]);
                        }
                        Log("    first 32 bytes:   %s", hex);

                        /* Not a disassembler, just the two shapes a stripped
                         * body takes. Anything else is dumped above and read
                         * off-line, which is where the real answer comes from. */
                        if (code[0] == 0xC3)
                        {
                            Log("    -> immediate ret. STUBBED.");
                        }
                        else if (code[0] == 0x33 && code[1] == 0xC0 && code[2] == 0xC3)
                        {
                            Log("    -> xor eax,eax; ret. STUBBED.");
                        }
                        else
                        {
                            Log("    -> has a real body");
                        }
                    }
                    Log("");
                }
            }
            line = next;
        }

        Log("  Compare SBPlayerBattleState, which works, against");
        Log("  SBCreateCharacter, which does not. If both have real bodies then");
        Log("  stripping is not the explanation and the argument handling is.");
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
        Log("  Nothing is hooked and nothing is patched.");
        Log("");

        /* The Lua side writes its targets only once it reaches gameplay, which
         * is long after this DLL loads, so wait rather than checking once and
         * reporting a missing file as a finding. */
        Log("waiting for ue4ss\\SBLove_targets.txt (up to 5 minutes)");
        for (int attempt = 0; attempt < 150; ++attempt)
        {
            wchar_t probe[MAX_PATH]{};
            if (GetModuleFileNameW(g_self, probe, MAX_PATH))
            {
                for (int stripped = 0; stripped < 4; ++stripped)
                {
                    wchar_t* slash = wcsrchr(probe, L'\\');
                    if (slash) *slash = L'\0';
                }
                wcscat_s(probe, MAX_PATH, L"\\SBLove_targets.txt");
                if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
                {
                    /* Let the writer finish before reading a partial file. */
                    Sleep(500);
                    ReportTargets(game);
                    return 0;
                }
            }
            Sleep(2000);
        }

        Log("no targets file appeared. Run the P10 Lua probe:");
        Log("  ./install.sh probe P10_targets");
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
