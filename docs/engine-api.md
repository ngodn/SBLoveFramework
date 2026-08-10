# The engine instruction set

Written 2026-08-11. This is the API SBLove Mode is built on.

Stellar Blade ships `USBCheatManager` with **698 developer commands**. They are
the tools the developers used to build and debug the game: load a world, create
a character, swap a mesh, play an animation on a tagged actor, drive the camera,
hide the HUD. Nearly every primitive a scene mode needs already exists.

## They are reachable, and how we know

Reachable through `ConsoleCommand` on the player controller, not by calling the
UFunction directly.

The evidence is [probe_v13_console.txt](../../research/probe_v13_console.txt).
It ran seven commands and two of them demonstrably changed the game:

```
TEST 2/7  ConsoleCommand("slomo 0.5")            >>> SLOMO TOOK EFFECT <<<
TEST 7/7  ConsoleCommand("SBPlayerBattleState")   >>> SKILL FIRED <<<
```

`SBPlayerBattleState` is a `USBCheatManager` member (SB.hpp:16392). A cheat
manager function produced an observable effect, so the object is live and the
class is reachable. An earlier session recorded "cheat manager inert" after
`SBCreateCharacter` did nothing; that conclusion was wrong. One command failing
is an argument or state problem, not proof the whole class is dead.

## The return value proves nothing

In the same probe:

```
TEST 1/7  ConsoleCommand("ThisCommandDoesNotExist123") -> true
```

`ConsoleCommand` returns `true` for a command that does not exist. **Never treat
a return value as confirmation.** Every command below has to be verified by an
observable change in the world, measured before and after. Five of the seven
commands in that probe returned `true` and did nothing at all.

## The instruction set

Signatures from `USBCheatManager`, SB.hpp lines 16000-16709. Console arguments
are positional and space separated.

### World

| Command | Purpose |
| --- | --- |
| `SBChangeWorld(FString changeWorld)` | load a world |
| `SBEnterWorld(FName EnterWorldAlias)` | enter a world by alias |
| `SBZoneEvent(FName InEventAlias)` | fire a zone event |
| `SBBlockLevelStreaming(bool bBlock)` | pin streaming, relevant to the teleport failures |
| `SBEnvState(FName EnvAlias, FName TagName)` | environment state |
| `SBCurrentWorldInfo()` | report where we are |

### Cast

| Command | Purpose |
| --- | --- |
| `SBCreateCharacter(FName Alias, float X, float Y, float Z, float Yaw)` | spawn by CharacterTable alias, **relative** to the player |
| `SBCharacterDespawnFromTag(FString InTag)` | remove by tag |
| `SBHideActor(FString TagName, bool bHide)` | hide without removing |
| `SBActorInfo(FString inActorName)` | inspect an actor |

Aliases come from `CharacterTable`. See [character-map.md](character-map.md).

### Appearance

| Command | Purpose |
| --- | --- |
| `SBChangeBody(FName MeshPath)` | swap body mesh |
| `SBChangeFace(FName MeshPath)` | swap face mesh |
| `SBChangeMesh(int32 MeshInfoIndex, FName MeshPath, FName AnimPath)` | swap a mesh slot with its anim |
| `SBEquipBodySuit(int32 ShortCutNum)` | equip an outfit |

This is the native outfit backend, so CNS stays optional as designed.

### Animation

The important one:

```cpp
SBPlayCustomAnimByTag(FString InActorTag, FString InAnimName, int32 inCustomIndex,
                      float InPlayStartTime, float InPlayEndTime, float InPlayRate,
                      float InBlendInTime, float InBlendOutTime,
                      bool bInLoop, int32 LoopCount);
```

Per-actor targeting by tag, with blend in and out, play rate, a time window and
looping. Two actors can be driven independently, and stage transitions can be
blended rather than snapped.

| Command | Purpose |
| --- | --- |
| `SBPlayCustomAnim(...)` | play on the player |
| `SBPlayCustomAnimByTag(...)` | play on a tagged actor |
| `SBPlayCustomAnimMeshSlot(..., ESBSkelMeshSlot inMeshSlot)` | play on one mesh slot |
| `SBPlayCustomAnimMeshSlotByTag(...)` | both at once |
| `SBPlayCustomAnimByFolder(FString InFolderPath)` | play a folder of animations |
| `SBPlayShow(FString InShowDataPath)` | play a full authored show |
| `SBPlayCameraAnim(FString InPath)` | play a camera animation |

`SBPlayCustomAnimMeshSlotByTag` means **face and body can run different
animations on the same actor at the same time**, which is the layering that
makes performance read as performance rather than as a looping clip.

`SBPlayCustomAnimByFolder` is worth investigating as an addon delivery route: if
it enumerates a folder, an addon may be able to ship animations as files rather
than as table rows.

### Presentation

| Command | Purpose |
| --- | --- |
| `SBGameOptionHUDVisible(bool bVisible)` | hide the HUD |
| `SBCameraFOV(float InNewFov)` | field of view |
| `SBPlayerMoveTo(float X, float Y, float Z, ...)` | walk the player somewhere |
| `slomo <float>` | time dilation, **verified working** |

## What this changes

The BlendSpace sample-swap in [playback.md](playback.md) was built without
knowing `SBPlayCustomAnimByTag` existed. It works, and it stays as the fallback,
but a command with blend in/out and per-actor targeting is a better instrument
if it verifies.

Keep our own physics layer regardless. Nothing in the 698 commands drives
secondary motion; [physics.lua](../Scripts/physics.lua) has no equivalent here.

## The discipline

Every command in this document is **unverified** except `slomo` and
`SBPlayerBattleState`. This file is a map of what to test, not a list of what
works. The project's evidence standard applies: measure a real change in the
world before and after, and treat anything else as unproven.
