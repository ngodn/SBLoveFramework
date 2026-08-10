# Posing Eve: what works and what does not

Measured 2026-08-11 through the live console, with time dilated to `slomo 0.02`
so the idle animation stopped and the noise floor was **0.00 cm**.

That last detail is the reason this document exists. Every earlier measurement
of posing was taken while Eve was idling, where her hand wanders 20-40 cm on its
own. Changes of that size were repeatedly read as the pose working. They were
not.

## The rule

**Write the anim-BP variable, not the node's pin.**

The anim graph copies its exposed pins from anim-BP variables after the event
graph runs and immediately before evaluating. A write made during
`ProcessEvent` lands in the window between the two and is overwritten before it
matters.

Reading the pin back shows the value we wrote, because the read happens in that
same window. That reading is worthless. It is the same mistake P6 made with
`CustomAnimAlpha`, and `physics.lua` hit the same wall when its writes to
KawaiiPhysics pins kept reverting.

## Measured, zero noise, fully reversible

Hand displacement from holding each variable at 1.0, `Bip001-R-Hand`:

| variable | offset | movement |
| --- | --- | --- |
| `CustomAnimAlpha_Upper` | `+0x11378` | **4.0 cm, exactly repeatable** |
| `EventMoveIKAlpha_Hand_R` | `+0x11CBC` | 2.0 cm |
| `EventMoveIKAlpha` | `+0x11C20` | 2.0 cm |
| `IKAlphaRight` | `+0x113AC` | none |
| `KnockDown_FullBodyIK_Alpha` | `+0x11D38` | none |
| `CustomAnimAlpha` | `+0x11330` | none |

Releasing every hold returned the hand to baseline exactly, to two decimals.

`CustomAnimAlpha_Upper` was then re-measured over four on/off cycles and gave
byte-identical positions every time:

```
off  (57494.14, -84486.51, 2209.75)
ON   (57492.78, -84489.97, 2208.27)
```

4.0 cm, repeatable, reversible, and visible on screen. A first single-shot
reading of 14.5 cm was inflated by the character still settling; four cycles
is what separated the effect from the settle.

`CustomAnimAlpha_Upper` is the one worth building on. It gates the upper-body
custom animation path, which is the right shape for this framework: the upper
body can be posed while the lower body keeps its normal idle and locomotion.

It moves the hand only 4.0 cm because the slot is EMPTY, so the graph blends
toward very nearly the pose it already had. The small size is the evidence that
content is the missing half, not that the lever is weak. Putting
real content there is the next step, and the BlendSpace sample swap in
[playback.md](playback.md) is the proven way to do it.

## Open: what the upper slot actually blends toward

Swapping an animation into `SBAnimGraphNode_CustomBlendSpacePlayer` and holding
`CustomAnimAlpha_Upper` measured **4.01 cm**, identical to the 4.0 cm measured
with the slot untouched. The sample swap reported success and five BlendSpaces
were restored afterwards, so the write happened; it simply is not the asset
that variable blends toward.

So the lever is real and the content route is not found yet. Candidates not yet
tried: the nine `FSBAnimNode_SequenceBlendedPlayer` nodes, the eleven
`FAnimNode_ControlRig` nodes, and the `LayeredBoneBlend` nodes, which are the
usual way an upper-body-only blend is built.

Worth noting the 4.0 cm is stable across a swap, which suggests the variable
blends toward a fixed reference pose rather than toward a slot whose contents
can be replaced.

## Does not work: ModifyBone pins

Setting `AnimGraphNode_ModifyBone.BoneToModify` and holding `Rotation` and
`Alpha` through the `ProcessEvent` hook produces **no movement at all**. Four
rotations, including 60 degrees on two axes, all measured identical:

```
bone set        (57495.55, -84502.48, 2201.80)
pose 0 0 0      (57495.55, -84502.48, 2201.80)
pose 0 0 60     (57495.55, -84502.48, 2201.80)
pose 0 0 -60    (57495.55, -84502.48, 2201.80)
pose 0 60 0     (57495.55, -84502.48, 2201.80)
```

This route looked alive for a long time and was not:

- Repointing `BoneToModify` from `Bip001-R-Toe0` to `Bip001-R-Forearm` **did**
  visibly move her arm. That was the game's own foot correction landing on the
  forearm, not our rotation. The node is a foot corrector the game drives
  itself, which is also why it is not really "idle at alpha 0.00".
- A later run appeared to show four distinct hand positions across four poses.
  That was the character settling from the first pose, measured during idle.

## Measuring anything on a character

1. `slomo 0.02` first. The idle noise floor is 20-40 cm; most effects worth
   finding are smaller than that.
2. Confirm the noise floor is actually zero by sampling the same bone several
   times before changing anything.
3. Alternate on and off more than once. A single before-and-after cannot
   distinguish an effect from a settle.
4. Release everything and confirm the baseline returns exactly. If it does not,
   something else moved and the measurement is void.
5. `slomo 1.0` afterwards.

## Hooking, for anyone extending this

Be the **outermost** hook, installed last. Hooking `ProcessEvent` before UE4SS
does killed every Lua mod in the process, CNS included: we patched the pristine
function, UE4SS patched over us, and its interception stopped working.
`SBLoveNative` now waits for a foreign `jmp` to appear before installing, and
refuses to patch a prologue it does not recognise.
