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
| Actor resolution, placement, pairing maths | written |
| Scene engine: stages + intensity axis | **working**, solo, measured in game |
| Secondary motion coupled to intensity | **working**, persists and restores cleanly |
| Contact colliders | written, untested |
| Addon registry (`.sblove.json`) | **written**, validation tested offline |
| Outfit backends (CNS + native) | not started |
| In-game UI | not started |

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
