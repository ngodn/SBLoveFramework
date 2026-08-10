# Playback: solved

How to make a Stellar Blade character play an arbitrary animation from Lua, with
no hooks, no input synthesis, and no Blueprint mod.

**Confirmed working in game on 2026-08-10.** Eve played a replacement animation
cleanly, visually verified, with no distortion. Established by probes P1-P8 plus
the v0.1 state scanner and v0.2 swap test.

## The mechanism: replace the samples inside her BlendSpace

Eve's body pose comes from a **BlendSpace**, not from an animation sequence. A
BlendSpace holds a set of samples, each pointing at a `UAnimSequence`, blended
together by speed and direction.

Replace **every** sample with the same animation and the blend output is that
animation wherever the blend parameters happen to sit. She plays it standing
still, walking, or anything else.

```lua
local mesh     = pawn:GetSBSkeletalMeshComponent(0)      -- ESBMesh_Body
local instance = mesh:GetAnimInstance()                  -- CH_P_EVE_01_AnimBP_New_C
local node     = instance.SBAnimGraphNode_BlendSpacePlayer_2
local space    = node.BlendSpace                         -- IdleRun_BS_Peaceful2D_Roll

local samples = space.SampleData                         -- TArray<FBlendSample>
for i = 1, 18 do
    samples[i].Animation = myAnim                        -- record the original first
end
```

Verified result:

```
SBAnimGraphNode_BlendSpacePlayer_2  ->  IdleRun_BS_Peaceful2D_Roll
18 samples: proto_Idle, Proto_Sprint, Proto_Walk, Proto_Run, Proto_Jog,
            Proto_Run_Roll_L/R, Proto_Sprint_Roll_L/R, Proto_Walk_Roll_L/R, ...
wrote 18 of 18 samples, verified by read-back
```

That is her main locomotion BlendSpace, which is why it covers the whole body.

Implemented in `SBLoveFramework/Scripts/playback.lua` as
`FindLiveBlendSpaces`, `SwapBlendSpace`, `RestoreBlendSpace`.

## Finding the target at runtime

Do not hardcode `SBAnimGraphNode_BlendSpacePlayer_2`. Which node is live depends
on the character and the situation.

Walk the anim instance's node properties, read `BlendSpace` off each, and keep
those whose `BlendWeight > 0`. The node property list is derived offline from
`research/CXXHeaderDump/CH_P_EVE_01_AnimBP_New.hpp`; 86 of them descend from
`FAnimNode_AssetPlayerBase`.

## The danger, and it is a real one

**A BlendSpace is a shared asset, not per-character state.** Editing it affects
everything that uses it, for the rest of the session, and nothing resets it.

Every sample's original pointer must be recorded and restored. `playback.lua`
restores on scene end, on leaving gameplay, and on mod unload. If the process is
killed mid-swap, restarting the game reloads the asset clean from the pak, since
nothing is written to disk.

## Sequence swapping: works, but not on the body

Overwriting `node.Sequence` on a live node also drives the skeleton, and it is
implemented in `playback.lua` as `Swap` / `PlayOnLive`. It is the right tool for
layers, not for the body.

Scanning every gameplay state showed only these sequence nodes ever live:

```
AnimGraphNode_SequencePlayer_25  Eve_Acc_idle_Anim    ABSOLUTE  w=1.00
AnimGraphNode_SequencePlayer_26  CH_P_EVE_09_AccIdle  additive  w=1.00
AnimGraphNode_SequencePlayer_31  Proto_Idle_Add       additive  w=0.14
```

`Eve_Acc_idle_Anim` lives in `/CH_P_EVE_01/Acc/`, a folder of four accessory and
Beta-skill animations. It is the hairpin and attachment layer, not her body.

### Additive compatibility is mandatory

The first apparently successful swap put a full-body absolute jog into
`CH_P_EVE_09_AccIdle`, which lives under `/Animation/Additive/`. Absolute bone
transforms were added on top of the base pose and the character deformed
violently. Measured hand travel was **171,623** units against an idle baseline
of **2.1**, which read as a spectacular success and was garbage.

`UAnimSequence.AdditiveAnimType` is readable (`AAT_None = 0` means absolute).
`Playback.Swap` refuses a mismatch unless `opts.force` is passed.

## Routes that are dead

| Route | Why |
| --- | --- |
| UE montages | Eve's anim blueprint contains **no `AnimNode_Slot`**. Every montage needs one. `PlaySlotAnimationAsDynamicMontage` returns a real `AnimMontage` for any slot name and animates nothing. Note it is a `UAnimInstance` method (`Engine.hpp:9075`), not `USkeletalMeshComponent` (`18542`) |
| CustomAnim nodes | Present and injectable, gated by `CustomAnimAlpha`, which the event graph rewrites every frame from `GetCurrentCustomAnimAlpha()`. The character-side state behind that getter is native C++ with no UProperty. Writing the alpha and reading back 1.0 looks like success; it is only 1.0 between the write and the next update. Winning needs a hook, and hooks cost 1-3 fps |
| `PlayAnimation` single-node | **Crashes the game.** Disables the anim blueprint that physics, cloth, IK and facial depend on. Also unsuitable in principle |
| `ActorPlayCustomAnimSequence` | On `ISBShowActorInterface`, not on `ASBCharacter`. Confirmed at runtime and in the offline 251-function list |

### The CustomAnim node map, kept for later

Worth keeping: if the character-side alpha is ever reachable, this gives
upper/lower separation, an additive layer and a morph channel for free.

```
SBAnimGraphNode_SequenceBlendedPlayer_1   CustomAnimNode          main body
SBAnimGraphNode_SequenceBlendedPlayer_4   CustomAnimNode_Upper
SBAnimGraphNode_SequenceBlendedPlayer_7   CustomAnimNode_Lower
SBAnimGraphNode_SequenceBlendedPlayer     CustomAnimAdditiveNode
SBAnimGraphNode_SequenceBlendedPlayer_6   SBCustomAnimNode01
SBAnimGraphNode_SequenceBlendedPlayer_8   CustomAnimNodeForMorph
SBAnimGraphNode_SequenceBlendedPlayer_2   CustomAnimNode1
SBAnimGraphNode_SequenceBlendedPlayer_3   CustomAnimAdditiveNode_Upper
SBAnimGraphNode_SequenceBlendedPlayer_5   CustomAnimNode1_Upper
```

## Writable surface, all verified by read-back

| Operation | Works |
| --- | --- |
| `sample.Animation = anim` on `BlendSpace.SampleData[i]` | **yes**, the mechanism |
| `node.Sequence = anim` | yes |
| `node.PlaySequences[1] = anim` (grows the TArray 0 to 1) | yes |
| `array:Add(anim)` | no, throws; use index assignment |

## Other things that bite

**Loaded assets get garbage collected.** `LoadAsset` returns a working object
and a few seconds later the same object no longer works, because nothing holds a
reference. Load and assign in the same breath; never preload into a cache.

**`LoadAsset` on a character Blueprint crashes the game.** Measured twice, with
the log stopping mid-function and no error written. On an `AnimSequence` it is
completely safe and the framework depends on it. A character Blueprint is
different in kind: it drags in its whole dependency graph, meshes, anim
blueprint, materials and physics assets, synchronously on the game thread.

Consequence: a character class can only be *looked up* with `StaticFindObject`,
never loaded. If the class is not already resident, that character cannot be
summoned, which is the same practical limit as it not being in the world.

**Summoning absent characters is therefore not available.** `SBCreateCharacter`
on `USBCheatManager` is inert (verified by counting instances before and after:
no throw, zero spawned), and the engine route cannot load a class that is not
already there. Pairing uses characters that already exist nearby.

**The Lobby is not gameplay.** The main menu builds a fully valid player pawn in
a level named `Lobby`. Every check passes there and every answer is worthless.
Gate on the pawn's object path, structurally.

## Evidence standard

Every playback signal the game offers is self-reported:

| Signal | What it actually proves |
| --- | --- |
| a montage object returned | an object was constructed |
| `IsPlaying == true` | the component set a flag on itself |
| an `FGuid` handle returned | the call did not throw |
| a property write that does not throw | nothing at all |

None of them show a character moving. Read every write back, measure bone travel
against an **idle baseline** (the character breathes, so zero is the wrong
reference), and for anything visual, look at the screen. Three probes reported
progress that was not there before this rule was adopted.
