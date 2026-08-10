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

    void Remove();
}
