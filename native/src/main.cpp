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
    /* Last handoff seen, so a rewritten file is noticed but an unchanged one
     * is not re-applied 120 times a minute. */
    char g_last_request[512]{};

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

        /* Unchanged since last time means nothing to do. This is what lets the
         * Lua side rewrite the file to retune a pose without a game restart:
         * the poll is cheap and only acts on an actual edit. */
        if (strcmp(buffer, g_last_request) == 0) return true;
        strcpy_s(g_last_request, sizeof(g_last_request), buffer);

        unsigned long long instance = 0;
        unsigned offset = 0;
        float value = 1.0f;
        /* An explicit release, so `clear` actually stops the hold. Without
         * this the parse simply failed and the previous pose kept being
         * re-asserted forever. */
        if (strstr(buffer, "cleared") != nullptr)
        {
            Hooks::HoldAnimAlpha(game.base, Log, nullptr, 0, 0.0f);
            Hooks::ClearPose();
            return true;
        }

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

        /* "hold=0x<offset> <value>" lines: absolute-offset float writes,
         * re-asserted after every ProcessEvent on this instance. Offsets are
         * relative to the anim instance, so the Lua side can name a variable
         * from the header dump without native needing to know any of them. */
        {
            Hooks::Hold holds[24]{};
            int count = 0;
            const char* scan = buffer;
            while (count < 24 && (scan = strstr(scan, "hold=")) != nullptr)
            {
                unsigned off = 0, width = 4;
                float v = 0.0f;
                if (sscanf_s(scan, "hold=0x%x %f %u", &off, &v, &width) >= 2)
                {
                    holds[count].address = reinterpret_cast<void*>(
                        static_cast<uintptr_t>(instance) + off);
                    holds[count].value = v;
                    holds[count].width = static_cast<uint8_t>(width == 1 ? 1 : 4);
                    ++count;
                }
                scan += 5;
            }
            Hooks::SetHolds(holds, count, Log);
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

                /* An OPTIONAL translation on the same node, for contact
                 * deformation. Parsed separately rather than as more fields on
                 * the pose= line so that every existing caller keeps working
                 * unchanged: no push= means tmode stays BMM_Ignore and the
                 * detour skips the translation writes entirely.
                 *
                 * Space defaults to BCS_ComponentSpace (1), not the rotation's
                 * BCS_BoneSpace (3). A push into flesh is a direction on her
                 * body, and bone space would rotate it with the bone -- which
                 * for a breast bone driven by a spring node means the push
                 * direction would wobble with the jiggle it is supposed to be
                 * deforming. */
                const char* push = strstr(buffer, "push=");
                if (push)
                {
                    float tx = 0.0f, ty = 0.0f, tz = 0.0f;
                    unsigned tmode = 2, tspace = 1;   /* additive, component */
                    if (sscanf_s(push, "push=%f %f %f mode=%u space=%u",
                                 &tx, &ty, &tz, &tmode, &tspace) >= 3)
                    {
                        pose.tx = tx;
                        pose.ty = ty;
                        pose.tz = tz;
                        pose.translation_mode  = static_cast<uint8_t>(tmode);
                        pose.translation_space = static_cast<uint8_t>(tspace);
                        Log("  push (%.2f, %.2f, %.2f) mode=%u space=%u",
                            tx, ty, tz, tmode, tspace);
                    }
                    else
                    {
                        Log("push line present but malformed, ignoring it");
                    }
                }

                Hooks::HoldPose(pose, Log);
            }
            else
            {
                Log("pose line present but malformed, ignoring it");
            }
        }
        return true;
    }

    /* Is this address safe to read? The object address arrives from another
     * process via a text file, so it is checked rather than trusted. */
    bool Readable(const void* address, size_t bytes)
    {
        MEMORY_BASIC_INFORMATION info{};
        if (!VirtualQuery(address, &info, sizeof(info))) return false;
        if (info.State != MEM_COMMIT) return false;
        const DWORD ok = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
        if (!(info.Protect & ok) || (info.Protect & PAGE_GUARD)) return false;
        const auto start = reinterpret_cast<uintptr_t>(address);
        const auto end = reinterpret_cast<uintptr_t>(info.BaseAddress) + info.RegionSize;
        return start + bytes <= end;
    }

    /* Patch the compressed animation buffer of an AnimSequence already loaded
     * in the game.
     *
     * The buffer edited on disk and the one held in memory are the same
     * structure, so applying the same byte offsets live changes the animation
     * with no repack and no restart. That turns a several-minute iteration into
     * a couple of seconds, which matters when the angles have to be found by
     * measuring rather than derived.
     *
     * FCompressedAnimSequence holds CompressedByteStream as its third TArray,
     * but rather than trust a hardcoded offset the buffer is FOUND: scan the
     * object for a TArray whose Num equals the size the file says it should be.
     * An exact size match on a five-figure number is not something a wrong
     * field lands on by accident. */
    bool ApplyAnimPatch()
    {
        wchar_t path[MAX_PATH]{};
        if (!Ue4ssPath(L"\\SBLove_patch.txt", path, MAX_PATH)) return false;
        if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) return false;

        HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;

        static char buffer[1 << 20];
        DWORD read = 0;
        ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
        CloseHandle(file);
        buffer[read] = '\0';

        static char applied[64]{};
        char stamp[64]{};
        const char* stampLine = strstr(buffer, "stamp=");
        if (stampLine) sscanf_s(stampLine, "stamp=%63s", stamp, 64u);
        if (stamp[0] && strcmp(stamp, applied) == 0) return false;   /* already done */

        unsigned long long objectAddr = 0;
        unsigned bulkSize = 0;
        const char* o = strstr(buffer, "object=");
        /* Accept "bulksize 123" and "bulksize=123". The emitter writes the
         * former and the first parser only matched the latter, so it silently
         * found nothing and returned. A parse that declines without saying why
         * is the same failure mode as a logger that cannot open its file. */
        const char* b = strstr(buffer, "bulksize");
        if (!o || !b)
        {
            Log("SBLove_patch.txt missing object= or bulksize");
            return false;
        }
        sscanf_s(o, "object=0x%llx", &objectAddr);
        if (sscanf_s(b, "bulksize=%u", &bulkSize) != 1)
            sscanf_s(b, "bulksize %u", &bulkSize);
        if (!objectAddr || !bulkSize)
        {
            Log("SBLove_patch.txt: object=0x%llX bulksize=%u, one is unusable",
                objectAddr, bulkSize);
            return false;
        }

        Log("");
        Log("######## LIVE ANIM PATCH ########");
        Log("  AnimSequence object 0x%016llX, expecting a %u byte buffer",
            objectAddr, bulkSize);

        /* Find the buffer by CONTENT, not by container layout.
         *
         * The first attempt looked for a TArray whose Num matched the file's
         * buffer size and found nothing, because in a shipping build
         * CompressedByteStream is a TMaybeMappedArray, not a TArray: it exists
         * to support memory-mapped animation, so its layout is not
         * {ptr, num, max} and no field holds the size where one was expected.
         *
         * Matching the first sixteen bytes sidesteps the container entirely.
         * Sixteen specific bytes at a pointer inside this exact object is not
         * something a wrong slot lands on. */
        uint8_t want[16]{};
        const char* sigLine = strstr(buffer, "signature ");
        if (!sigLine) { Log("  patch file has no signature line"); return false; }
        for (int i = 0; i < 16; i++)
        {
            unsigned v = 0;
            sscanf_s(sigLine + 10 + i * 2, "%2x", &v);
            want[i] = static_cast<uint8_t>(v);
        }

        uint8_t* found = nullptr;
        for (size_t off = 0; off + 8 <= 0x300; off += 8)
        {
            auto* slot = reinterpret_cast<uint8_t*>(objectAddr + off);
            if (!Readable(slot, 8)) continue;
            auto* data = *reinterpret_cast<uint8_t**>(slot);
            if (!data || !Readable(data, bulkSize)) continue;
            if (memcmp(data, want, sizeof(want)) != 0) continue;
            found = data;
            Log("  buffer found via +0x%zX -> 0x%016llX", off,
                reinterpret_cast<unsigned long long>(data));
            break;
        }
        if (!found)
        {
            Log("  no pointer in this object reaches a buffer starting with the");
            Log("  expected 16 bytes. Either the object address is wrong, or the");
            Log("  loaded animation is not the one the patch was computed from.");
            return false;
        }

        int count = 0;
        for (const char* line = strstr(buffer, "patch "); line; line = strstr(line, "patch "))
        {
            unsigned at = 0, hex = 0;
            if (sscanf_s(line, "patch %u %4x", &at, &hex) == 2 && at + 2 <= bulkSize)
            {
                /* Emitted big-endian as printed, written little-endian as stored. */
                found[at]     = static_cast<uint8_t>((hex >> 8) & 0xFF);
                found[at + 1] = static_cast<uint8_t>(hex & 0xFF);
                ++count;
            }
            line += 6;
        }

        strcpy_s(applied, sizeof(applied), stamp);

        /* ACKNOWLEDGE, so callers can WAIT for the patch instead of guessing.
         *
         * This closes a bug that quietly corrupted measurements all session.
         * ./pose wrote this file and slept 0.8 s, on the reasoning that the
         * poll interval is 500 ms. When the patch had not landed by then, the
         * next command measured her PREVIOUS pose and attributed it to the
         * angles just requested.
         *
         * It is not a small error. One solve read her REST pose -- arm hanging,
         * drop 22.5, flare 2.0 -- as the result of a chest pose, scoring the
         * palm 45.23 cm from a target the same angles had measured at 2.80 cm
         * moments earlier. A closed-loop solver believes its measurements, so a
         * single stale read poisons the Jacobian and everything after it.
         *
         * No sleep is long enough to fix this, because the wait is on an event
         * rather than on a duration: a hitching frame makes any constant wrong.
         * Writing the stamp back means the caller can poll for THIS patch, and
         * a caller that never sees its own stamp knows it failed rather than
         * carrying on with a stale number. */
        wchar_t ackPath[MAX_PATH]{};
        if (Ue4ssPath(L"\\SBLove_ack.txt", ackPath, MAX_PATH))
        {
            HANDLE ack = CreateFileW(ackPath, GENERIC_WRITE, FILE_SHARE_READ,
                                     nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                     nullptr);
            if (ack != INVALID_HANDLE_VALUE)
            {
                char line[96]{};
                const int n = sprintf_s(line, sizeof(line), "%s %d\n", stamp, count);
                DWORD written = 0;
                if (n > 0) WriteFile(ack, line, static_cast<DWORD>(n), &written, nullptr);
                CloseHandle(ack);
            }
        }

        Log("  applied %d byte patches", count);
        Log("  the change is live; no repack and no restart");
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

        /* Discard any handoff left by a previous session. A stale one is read
         * at DLL load, which installs the hook before UE4SS is ready and takes
         * the whole Lua subsystem down with it. */
        {
            wchar_t stale[MAX_PATH]{};
            if (Ue4ssPath(L"\\SBLove_anim.txt", stale, MAX_PATH))
            {
                DeleteFileW(stale);
            }
        }

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

            /* No iteration bound. This started as a timed probe, but it is
             * now the live control loop: it polls the handoff file so a pose
             * can be retuned while the game runs. A bounded loop quietly
             * stopped re-reading after 7.5 minutes while the hook went on
             * holding the last pose forever, which looked exactly like new
             * poses having no effect. */
            for (unsigned attempt = 0; ; ++attempt)
            {
                const long now = Hooks::CommandCount();
                if (now != last)
                {
                    Log("HOOK FIRED -- %ld call%s so far", now, now == 1 ? "" : "s");
                    last = now;
                }

                /* The Lua side writes this once it has found Eve's anim
                 * instance, which cannot happen before gameplay. */
                /* Polled every pass, not once. A pose is retuned by rewriting
                 * the handoff file, which is the whole point of a live loop:
                 * an experiment per game launch is not a workable pace. */
                if (ReadAnimRequest(game))
                {
                    announced_alpha = true;
                }

                ApplyAnimPatch();

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
