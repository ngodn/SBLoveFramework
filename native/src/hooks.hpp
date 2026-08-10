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

    /* ---------------------------------------------------- procedural posing
     *
     * A ModifyBone node offers exactly the control a posed limb needs, and its
     * fields are exposed pins, which means the anim graph re-copies them every
     * frame. physics.lua learned that the hard way: writes to exposed pins
     * revert before the next evaluation. So a pose has to be held by the same
     * mechanism that holds the alpha.
     *
     * Lua sets BoneToModify, because that is an FName and constructing one
     * natively is far more trouble than it is worth. Native holds the numbers.
     *
     * `node` is the ModifyBone node's address, which is the anim instance plus
     * the node's offset in its class. Field offsets inside the node come from
     * FAnimNode_ModifyBone in AnimGraphRuntime.hpp. */
    struct Pose
    {
        void* node = nullptr;
        float pitch = 0.0f, yaw = 0.0f, roll = 0.0f;
        uint8_t rotation_mode = 2;   /* BMM_Additive */
        uint8_t rotation_space = 3;  /* BCS_BoneSpace */
        float alpha = 1.0f;
    };

    void HoldPose(const Pose& pose, LogFunc log);
    void ClearPose();
    long PoseWrites();

    void Remove();
}
