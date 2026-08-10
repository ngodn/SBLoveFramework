#pragma once

#include <cstdint>

namespace Hooks
{
    /* printf-style, supplied by main.cpp so hooks do not own the log. */
    using LogFunc = void (*)(const char* format, ...);

    /* Called when the hijacked console command fires. Context is the object it
     * ran on, Stack is the FFrame holding the still-unparsed arguments. */
    using CommandCallback = void (*)(void* Context, void* Stack);

    /* Patch execSBChangeWorld so the game's own console becomes a command
     * channel into native code. Returns false and patches nothing if the
     * target's prologue does not match what was read from the shipped exe. */
    bool Install(uintptr_t module_base, LogFunc log, CommandCallback on_command);

    /* How many times the hijacked command has fired. */
    long CommandCount();

    /* ------------------------------------------------------- the anim race
     *
     * Probe P8's finding, and the reason the native half exists at all:
     *
     *   1. the anim blueprint's event graph sets CustomAnimAlpha = 0
     *   2. the graph evaluates, sees 0, and ignores the CustomAnim node
     *   3. a Lua timer writes 1.0        <- always too late
     *   4. repeat, every frame
     *
     * P6 read the alpha back as 1.0 and took that for success. It was only 1.0
     * between our write and the next update; at evaluation it was always 0.
     *
     * Winning needs a write ordered after the event graph runs, which means a
     * hook, and in Lua a hook costs 1-3 fps because UE4SS switches on global
     * ProcessInternal interception. Natively it costs a pointer comparison.
     *
     * ProcessEvent runs the event graph, so re-asserting the value after the
     * original returns puts our write last. */
    bool HoldAnimAlpha(uintptr_t module_base, LogFunc log,
                       void* anim_instance, uint32_t alpha_offset, float value);

    /* Re-assertions performed, and total ProcessEvent calls seen. The second
     * number is how often the detour ran at all, which is the cost story. */
    long AlphaWrites();
    long ProcessEventCalls();

    void Remove();
}
