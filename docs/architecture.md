# SBLoveFramework — architecture

Written 2026-08-10, second session. This is the design doc. It records what was
researched, what was decided, and why. [playback.md](playback.md) records the
solved playback mechanism and the routes that are dead.

## What this mod is

A multi-actor scene framework for Stellar Blade, in the spirit of BG3SX for
Baldur's Gate 3. It pairs two or more characters, aligns them, plays
synchronised animations on each, and manages the scene's lifecycle. It ships
**no animations of its own** — addons provide those, the way BG3SX does.

## Why this is worth building

Stellar Blade's adult modding scene is large but flat. Everything in it is one
of two things:

- **mesh/material replacers** — outfits, skins, faces (CNS ecosystem, hundreds
  of mods)
- **single-character animation packs** — ATOOL, CNS `.dekani.json` anim lists,
  dance mods

Nobody has built the layer above: **two characters doing something together**.
CNS's own schema has a `LinkedAnims` field described as "simultaneous
multi-character triggering", and it is used **zero times** across every config
installed on this system. It is an unfinished stub.

That is the gap.

## What already exists and must be built on, not replaced

### CNS (Custom Nanosuit System) by Dekita

Installed at `ue4ss/Mods/DekCNS` plus `LogicMods/DekCNS_P.pak`. This is the
single most important dependency. Read its `Scripts/main.lua` (1083 lines)
before writing anything.

| CNS provides | Detail |
| --- | --- |
| Character resolution | `EVE` = player pawn, `ADAM` = `CH_NPC_Adam_01_Blueprint_C`, `LILY` = `CH_NPC_01_Blueprint_C`, `DRONE` = `CH_Drone_BP_C`. Nearest-instance selection by `GetDistanceTo` |
| Mesh access | `Character:GetSBSkeletalMeshComponent(slot)` |
| Outfit swapping | `.dekcns.json`, 67 configs installed |
| Animation registry | `.dekani.json` → soft ref to any `AnimSequence`, per character, Body or Face |
| Free camera | WASD/QE, its own mode |
| In-game UI | Blueprint UMG widget |

**Architecture worth copying exactly:** CNS's Lua is *only* a data and IO layer.
It exposes callbacks via `RegisterCustomEvent` and a Blueprint mod calls into
them. There is not one `RegisterHook` in the whole mod, which is why it does not
destroy the framerate. Last session proved `RegisterHook` costs 1-3 fps
regardless of hook count, because UE4SS switches on global `ProcessInternal`
interception. **Never use it.**

### The `.dekani.json` animation format

```json
{
  "CharacterID": "EVE",
  "AniTargetID": "Body",
  "AniCatTypes": ["Pose"],
  "AniFilePath": "/Game/Art/.../P_Eve_Tachy_Battle_Jog.P_Eve_Tachy_Battle_Jog",
  "UniqueAniID": "author.mod.anim",
  "LinkedAnims": []
}
```

SBLoveFramework's own format deliberately mirrors this so addon authors already
know it.

## The scene model, and why it is not BG3SX's

BG3SX models a scene as a flat list: pick an animation from a dropdown, it
plays, pick another. That is a pose viewer with extra steps.

Umemaro's structure is better, and it is worth stating how it was determined,
because it was measured rather than assumed. Both purchased titles are **Unity
6000.0.58 IL2CPP** and both are **pre-rendered MP4 players** — 3.58 GB of the
3.6 GB is `resources.resource` holding video, and the asset files contain
**zero** `AnimationClip`, `SkinnedMeshRenderer`, `Avatar` or `AnimatorController`
objects. There is no skeletal animation in them to extract or retarget. Their
value is structural, and the structure is legible from the 171 clip names:

```
OP
A01                                   single clip  (act transition)
A02  loop_a loop_b loop_c loop_d      4 intensity loops
     sub1 .. sub9                     9 transition / reaction clips
A03  … A05                            same shape
A06                                   single clip  (act transition)
A07 … A09                             same shape
B01 … B08                             second route, same shape
END1  END2
```

So: **13 core stages, each with 4 seamless intensity loops plus transition
clips, across 2 routes, bracketed by act transitions and two endings.**

The lesson is that a scene is a **state machine over stages**, where each stage
has an intensity axis you move along, not a list you pick from. That is what
makes it read as a scene instead of a pose browser. SBLoveFramework adopts this:

```
Scene
├─ actors      { A = <SBCharacter>, B = <SBCharacter> }
├─ stage       current Stage
└─ Stage
   ├─ id, displayName, tags
   ├─ alignment  { offset = {x,y,z}, yaw, heightMatch }
   ├─ tracks     { A = animId, B = animId }     paired, started same frame
   ├─ loops      [ L0, L1, L2, L3 ]             intensity axis
   └─ exits      [ { to = stageId, via = animId } ]
```

Controls become: **next/prev stage**, **intensity up/down**, **swap roles**,
**end scene**. Four verbs, which is the whole point.

## Layering

```
┌──────────────────────────────────────────────┐
│ UI     WB_SBLove_Main  (Blueprint UMG)       │  authored in UE 4.26 editor
│        packaged to Content/Paks/LogicMods    │
└───────────────┬──────────────────────────────┘
                │ RegisterCustomEvent
┌───────────────▼──────────────────────────────┐
│ Bridge  ue4ss/Mods/SBLoveFramework/Scripts   │  pure Lua, no hooks
│   registry.lua   load + index .sblove.json   │
│   actors.lua     resolve, save/restore state │
│   align.lua      relative placement          │
│   scene.lua      the stage machine           │
│   outfit.lua     strip / redress  (backends) │
│   api.lua        events for other mods       │
└───────────────┬──────────────────────────────┘
                │ UFunction calls only
┌───────────────▼──────────────────────────────┐
│ Game    Stellar Blade, UE 4.26               │
└──────────────────────────────────────────────┘
```

## CNS is optional, not required

**Hard requirement: the framework must work with and without CNS installed.**
CNS is detected at runtime and used when present, never assumed.

Nothing in the core depends on it. Character resolution comes from
`CharacterAppearanceTable` (see [character-map.md](character-map.md)),
which is the game's own data and is more complete than CNS's four hardcoded
classes. Animations come from our own `.sblove.json` registry. Playback,
alignment and scene state are all direct UFunction calls.

The only place CNS genuinely helps is **wardrobe**, so that is the one part
written against a backend interface:

```
outfit.lua
 ├─ detect:  is DekCNS loaded?
 ├─ backend "cns"     -> drive CNS's outfit swap, so scenes can strip to and
 │                       restore any CNS outfit the user owns, and the user's
 │                       existing 67 configs just work
 └─ backend "native"  -> no CNS: hide/show mesh slots directly through
                         GetSBSkeletalMeshComponent(slot) + SetVisibility,
                         and restore the exact prior visibility on scene exit
```

Both backends satisfy the same two calls, `Strip(actor, policy)` and
`Restore(actor)`. Everything above them is identical, and the UI shows which
backend is active rather than hiding the difference.

The native backend is strictly less capable: it can hide an outfit but cannot
swap in a different one. That is an acceptable floor, and it means a user with
no CNS still gets working scenes.

Detection is by presence, not by version string: look for the CNS Lua module or
its registered custom events, and fall back the moment anything is missing. A
half-present CNS must degrade to native rather than error.

## Measured in game (probes P1-P4)

| Finding | Status |
| --- | --- |
| `LoadAsset(path)` resolves an `AnimSequence` at runtime | **WORKS**, confirmed twice |
| `K2_TeleportTo` horizontal placement | **HOLDS**, +150 requested, +150.0 held, 0.0 drift over 3 samples. The movement component does not fight it, so alignment needs no neutralising |
| Eve's skeleton | `CH_P_EVE_01_Skeleton`, 182 bones, `Bip001-R-Hand` naming |
| Eve's anim instance | `CH_P_EVE_01_AnimBP_New_C`, `AnimationMode = 0` (AnimationBlueprint) |
| `PlaySlotAnimationAsDynamicMontage` | on `UAnimInstance` (Engine.hpp:9075), **not** the mesh component (18542). Returns a montage with `LoopCount >= 1`, returns nil with `LoopCount = 0` |
| Whether a montage actually moves the skeleton | **STILL UNKNOWN**, see below |
| `ActorPlayCustomAnimSequence` on `ASBCharacter` | **NOT AVAILABLE.** Confirmed twice: nullptr at runtime, and absent from the offline 251-function list. `ASBCharacter` has custom-anim *getters* only |
| `PlayAnimation` single-node mode | **CRASHES THE GAME.** Do not use |

### PlayAnimation single-node crashes the game

`SetAnimationMode(1)` + `PlayAnimation()` sets `IsPlaying = true` and looks like
it works. Held on the live player pawn for two seconds, with CNS concurrently
refreshing outfits, it hard-crashed the game (P4).

Single-node mode disables the anim blueprint, and SB's gameplay systems depend
on it for physics, cloth, IK and facial. A brief flip survives; holding it does
not. It is also unsuitable on its own terms, since a scene framework cannot
destroy the graph everything else rides on.

**Never put a live character into single-node mode.**

### The evidence standard this project now uses

Every playback signal so far was self-reported by the thing under test:

| Signal | What it actually proves |
| --- | --- |
| montage object returned | an object was constructed |
| `IsPlaying == true` | the component set a flag on itself |
| a returned `FGuid` handle | the call did not throw |

None of them show a character moving. Eve's anim blueprint was extracted from
the paks and read offline: it defines **no** `DefaultSlot`, `FullBody` or
`UpperBody` slot node. A montage played into a slot the graph lacks is silently
discarded, which is entirely consistent with every "success" observed so far.

So playback claims are now measured by **bone travel**: sample a hand bone
relative to the actor and sum the distance moved, against an idle **baseline**,
because Eve breathes and is never perfectly still. A route counts only if it
clearly beats idle. Judging against zero would score breathing as success.

## Verified engine primitives

Every one of these is a real callable UFunction, confirmed in the SDK dump. None
requires a hook.

| Need | Function | Source |
| --- | --- | --- |
| Play an anim over the anim BP | `USkeletalMeshComponent::PlaySlotAnimationAsDynamicMontage(Asset, SlotName, BlendIn, BlendOut, PlayRate, LoopCount, BlendOutTriggerTime, StartAt)` | `Engine.hpp:9106` |
| Play an anim replacing the BP | `USkeletalMeshComponent::PlayAnimation(Asset, bLooping)` | `Engine.hpp:18701` |
| Switch anim mode | `SetAnimationMode(EAnimationMode)` | `Engine.hpp:18677` |
| Full control of playhead | `OverrideAnimationData(Asset, bLooping, bPlaying, position, PlayRate)` | `Engine.hpp:18703` |
| Place an actor | `K2_SetActorLocationAndRotation(Loc, Rot, bSweep, Hit, bTeleport)` | `Engine.hpp:7112` |
| Place ignoring collision | `K2_TeleportTo(Loc, Rot)` | `Engine.hpp:7106` |
| Height match | `SetActorScale3D(Scale)` | `Engine.hpp:7074` |
| Get a mesh slot | `SBCharacter::GetSBSkeletalMeshComponent(ESBSkelMeshSlot)` | `SB.hpp:12855` |

`ESBSkelMeshSlot`: `Body=0, Face=1, Hair1=2, Ponytail=3, PonytailShort=4,
Weapon1..4=5..8, Accessory1..5=9..13, Etc1=14, Etc2=15, All=100`.

**Preferred playback is `PlaySlotAnimationAsDynamicMontage`,** not
`PlayAnimation`. `PlayAnimation` forces the component into single-node mode and
throws away the anim blueprint, which takes physics, cloth and facial systems
with it. The slot montage plays *over* the existing graph and blends out
cleanly, which is also what makes returning to normal gameplay safe.

## The hard parts, named honestly

1. **The character will fight you.** SB's movement component and anim BP will
   re-assert control and slide the actor. A scene must first neutralise the
   pawn: stop movement, disable AI logic, ignore input. `SetIgnoreMoveInput` was
   verified working last session. This is the piece most likely to need
   iteration.

2. **Restoring state.** Anything a scene changes has to be recorded and put back
   exactly, or the save gets corrupted in ways that show up hours later. Every
   mutation goes through a single save/restore path with no exceptions. CNS's
   own config warns that its physics fix can make characters "fall through the
   world" — that is the failure mode to design against.

3. **Alignment is per-animation data, not something to compute.** Two clips
   authored separately will never line up from a formula. The offset and yaw
   belong in the addon's JSON, tuned by whoever made the animation. The
   framework provides a live nudge UI so they can find those numbers.

4. **Raven is a boss, not a standing NPC.** Her class is now known,
   `CH_M_NA_53_Blueprint_C`, with a second beast form `CH_M_NA_42_Blueprint_C`
   (see [character-map.md](character-map.md) for how that was resolved and
   cross-validated). The catch is availability: unlike Adam and Lily she is not
   in the world outside her encounters, so `FindAllOf` legitimately returns
   nothing most of the time. "Actor not present" is a normal state the UI has to
   report honestly rather than fail on.

## Animation authoring pipeline

Chosen scope: build the pipeline as well as the framework. Nothing usable can be
extracted from the Umemaro titles (they are video), so all content is original.

```
 Blender / UE 4.26                     retoc (tools/retoc)
 ─────────────────                     ───────────────────
 1. extract SB skeleton  ──┐
    (FModel or retoc       │
     to-legacy)            │
 2. author paired anim  ───┤
    on that skeleton       │
 3. import to UE 4.26   ───┤
    project, cook          │
 4. cooked legacy asset ───┴──> retoc to-zen ──> .utoc/.ucas/.pak
                                                       │
 5. drop in Content/Paks/~mods/  <─────────────────────┘
 6. register in <name>.sblove.json
```

Both animations of a pair are authored **in the same scene, on two skeletons,
with the character origins where the framework will place them**. The offset and
yaw recorded in step 6 are exactly the origin delta used in step 2. That is what
makes them line up.

## Division of work

| Piece | Who |
| --- | --- |
| Lua bridge, scene engine, registry, alignment, persistence | me, headless |
| `.sblove.json` format + validator | me |
| Runtime probe to identify Raven and any other character | me |
| retoc build + cook/convert scripting | me |
| `WB_SBLove_Main` UMG widget | **needs UE 4.26 editor, so you** |
| Blueprint mod packaging to `LogicMods` | you, from my spec |
| The animations themselves | animators |

The UMG widget is the one thing that cannot be produced headlessly. It will be
specified down to the widget names, the events it must call, and the data
shapes it receives, so authoring it is mechanical rather than design work.

## Non-negotiables

- **No `RegisterHook`, ever.** Global `ProcessInternal` interception, 1-3 fps.
- **No input synthesis.** Last session's `PostMessage` bridge is unnecessary
  here; everything is direct UFunction calls.
- **No mutation without a recorded restore.**
- **Framework ships zero animations.** Content lives in addons.
