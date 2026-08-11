# SBLoveFramework

A multi-actor scene framework for **Stellar Blade**, in the spirit of
[BG3SX](https://www.nexusmods.com/baldursgate3/mods/6045) for Baldur's Gate 3.
It pairs characters, aligns them, plays synchronised animations on each, drives
secondary motion from the scene's intensity, and puts everything back when the
scene ends.

**It ships no animations.** Addons provide those.

Requires [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). Works with or without
[CNS](https://www.nexusmods.com/stellarblade/mods/1496).

## Status

Playback is solved and confirmed in game. The scene engine is written but not
yet exercised with two actors.

| Piece | State |
| --- | --- |
| Animation playback | **working, visually confirmed** |
| Actor resolution, placement, pairing maths | **working**, alignment exact to the decimal |
| Scene engine: stages + intensity axis | **working**, solo, measured in game |
| Secondary motion coupled to intensity | **working**, persists and restores cleanly |
| Contact colliders | written, untested |
| Summoning absent characters | **not possible**, both routes exhausted |
| Addon registry (`.sblove.json`) | **written**, validation tested offline |
| Outfit backends (CNS + native) | not started |
| In-game UI | not started |

## Two-actor scenes: working

Confirmed in game with Eve and Raven in a Boss Challenge arena:

```
PAIRED: Eve + Raven
demo.paired  stage 1/1 'facing'  intensity 1/2
  [A=CH_P_EVE_01_Blueprint_C  B=CH_M_NA_53_Blueprint_C]
horizontal gap after alignment: 70.0 cm (asked for 70)
LEVEL 1 / 2  ->  LEVEL 2 / 2  ->  scene stopped, everything restored
```

Both actors resolved, alignment landed on target to the decimal, the intensity
axis stepped, and teardown restored everything.

A Boss Challenge turned out to be the right test bed: a guaranteed humanoid in a
clean arena, reachable without playing through a story section.

## How playback works

Stellar Blade resists every normal route: its anim blueprint has **no montage
slot**, its custom-anim nodes are gated behind an alpha that native C++ rewrites
every frame, and single-node mode crashes the game.

What works is replacing the samples inside the BlendSpace the character is
already playing. Every sample is a writable `UAnimSequence*`, so pointing all of
them at one animation makes the blend output that animation wherever the blend
parameters sit.

```lua
local instance = mesh:GetAnimInstance()
local space    = instance.SBAnimGraphNode_BlendSpacePlayer_2.BlendSpace
for i = 1, 18 do space.SampleData[i].Animation = myAnim end
```

No hooks, no input synthesis, no Blueprint mod, no framerate cost. Full detail
and the dead routes in [docs/playback.md](docs/playback.md).

## The scene model

Taken from the structure of commercial adult animation rather than from BG3SX.
BG3SX models a scene as a dropdown of animations, which is a pose viewer. The
better model, visible in how those titles organise their clips, is **stages with
an intensity axis**:

```
Scene
├─ actors     { A = anchor, B = partner }
└─ Stage
   ├─ alignment { forward, right, up, yaw }   in the anchor's frame
   ├─ tracks    { A = animId, B = animId }    started together
   └─ loops     [ L1, L2, L3, L4 ]            the intensity axis
```

Four verbs: **next/prev stage**, **intensity up/down**, **swap roles**, **end**.

Secondary motion rides the same axis. That is grounded rather than arbitrary:
soft tissue is a mass-spring-damper, so response amplitude follows driving
acceleration on its own, and what has to change with intensity is the
displacement *ceiling*, not the spring. Natural frequency is a property of the
tissue and stays put. See the notes in `Scripts/physics.lua`.

## Modules

| File | Lines | Role |
| --- | --- | --- |
| `Scripts/playback.lua` | 542 | BlendSpace and sequence swapping, additive-mismatch rejection, restore |
| `Scripts/physics.lua` | 497 | KawaiiPhysics + 27 spring chains, intensity ramp, per-side asymmetry |
| `Scripts/scene.lua` | 379 | stages, intensity, roles, teardown |
| `Scripts/actors.lua` | 314 | resolution, placement, pairing maths, capture/restore |
| `Scripts/contact.lua` | 315 | collision volumes, bone-bound and cross-actor driven |
| `Scripts/registry.lua` | 330 | addon discovery, strict per-file validation |
| `Scripts/json.lua` | 220 | decoder with line/column errors and surrogate pairs |
| `Scripts/main.lua` | 227 | current demo harness |

## Authoring animation live

The game does not have to be restarted to change an animation. The compressed
buffer on disk and the one loaded in memory are the same structure, so the same
byte offsets apply to both: SBAnimTool works out the patch from the extracted
asset, Lua supplies the address of the loaded object, and the native DLL copies
the bytes in. One iteration is about six seconds.

```bash
./sblove <cmd>               # live console: bones, where, get, exec, animaddr, ...
./pose  <track> <p> <y> <r>  # constant rotation on one track
./reset [track ...]          # put tracks back to the shipped keys
./measure                    # arm geometry in her body frame, scored
./palm                       # which way the right palm faces
./armprobe <6 angles>        # apply a shoulder+elbow pose, print the geometry
./armsearch                  # grid search the arm, ranked by cost
./palmsearch <out>           # grid search the wrist
./refsheet <video> <name>    # contact sheet from reference footage
./refframe <video> <name> <s...>
```

Tracks 48, 49 and 50 are her right shoulder, elbow and wrist. See
[docs/anatomy.md](docs/anatomy.md) for what each rotation axis does and for the
two ways this measurement was wrong before it was right.

`./reset` exists because patching happens in memory: once a track is
overwritten there is nothing left to undo from, and a sweep through extreme
rotations leaves the arm visibly broken with no way back.

`assets/` holds the extracted animation. It used to live in a session
scratchpad, which meant a wiped `/tmp` would silently break every byte offset
the tools compute.

## Install

```bash
./install.sh              # install and enable
./install.sh status       # what is installed
./install.sh disable      # stop it loading, keep the files
./install.sh uninstall    # remove it and its output
```

Set `SB_DIR` if your game is elsewhere. Output lands in
`SB/Binaries/Win64/ue4ss/SBLoveFramework_scan.txt`.

## Rules this code follows

These are not style preferences. Each one is a mistake already made and paid
for during development.

- **No `RegisterHook`.** UE4SS hooks switch on global `ProcessInternal`
  interception, measured at 1-3 fps regardless of hook count.
- **No single-node animation mode.** It disables the anim blueprint the physics,
  cloth, IK and facial systems depend on, and it crashed the game.
- **Nothing is mutated without a recorded restore.** A BlendSpace is a *shared
  asset* and physics settings live on a live anim instance; either left edited
  stays wrong until the level reloads.
- **Read every write back.** A property write that does not throw proves
  nothing. Three rounds of development reported progress that was not there.
- **Measure against a control.** The character breathes, so zero is the wrong
  reference for "is it moving". Bone travel is compared to an idle baseline.
- **The Lobby is not gameplay.** The main menu builds a fully valid player pawn
  in a level called `Lobby` where every check passes and every answer is
  meaningless. Gate on the pawn's object path.

## Summoning: closed

A partner must already exist in the world. Both routes were built and measured:

| Route | Result |
| --- | --- |
| `SBCreateCharacter` (cheat manager) | inert. No throw, zero instances, counted before and after. The fifth `USBCheatManager` function measured dead on this build, alongside `SBWarpCamp`, `SBWarpWorld`, `SBWarpCampToPointName` and `SBPlayerUseSkill` |
| `BeginDeferredActorSpawnFromClass` | **works**, produces a real actor with no crash. But it has no body mesh *component* at all, so the Blueprint's components are never constructed. `NotifyBP_InitActor`, `NotifyBP_ReInitActor` and `NotifyBP_SetMesh` do not fix it |

Also: **`LoadAsset` on a character Blueprint crashes the game**, so a class that
is not already resident cannot even be looked at. On an `AnimSequence` it is
safe and the framework depends on it.

This is a limit, not a gap. Characters exist everywhere except linear story
sections, and `Actors.NearbyCharacters` finds them.

## External artefacts

Reference data lives in the parent project rather than here, because it is large
and derived from the game:

| Path | What | Regenerate |
| --- | --- | --- |
| `../research/CXXHeaderDump/` | full reflected SDK, 1223 headers | UE4SS `GenerateSDK` |
| `../research/*.usmap` | retail mappings | dumped from the running game |
| `../research/pak-index/` | 199,707 asset paths | `retoc manifest` over the paks |

`docs/character-map.md` explains how to resolve any of the game's 212 characters
from those.
