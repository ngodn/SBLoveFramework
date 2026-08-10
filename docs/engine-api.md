# The cheat manager is hollow

Rewritten 2026-08-11, after measuring. **The previous version of this file was
wrong**, and wrong in an expensive way: it called `USBCheatManager`'s 698
developer commands "the engine instruction set" and mapped the whole mode engine
onto them. They do nothing. Nothing in this document is a route to anything.

It is kept rather than deleted so the route is not re-proposed later.

## What was claimed

That Stellar Blade shipped a complete toolkit for a scene mode:

| Wanted | Command |
| --- | --- |
| load a world | `SBChangeWorld`, `SBEnterWorld` |
| load a cast | `SBCreateCharacter` |
| play a scene | `SBPlayCustomAnimByTag`, `SBPlayShow` |
| change appearance | `SBChangeBody`, `SBChangeFace` |
| presentation | `SBGameOptionHUDVisible`, `SBCameraFOV` |

The functions exist. They are reflected, findable by path, and their `UFunction`
objects carry a valid pointer to real, non-stub machine code. Every surface
check said yes.

## What is actually true

The bodies are compiled out of the shipping build. What survives is the
engine-generated exec thunk, which unmarshals parameters and returns.

`execSBCreateCharacter`, disassembled from the shipped exe at RVA `0x026A36A0`:

```
movq  0x20(%rbx), %rax     ; Stack.Code
setne %sil
addq  %rax, %rsi
movq  %rsi, 0x20(%rbx)     ; P_FINISH
...epilogue...
retq                       ; nothing is ever called
```

All five parameters are parsed correctly. Then it returns.

## The control, which is the only reason this is a finding

A thunk that looks empty proves nothing without a working one to compare
against, in the same binary, built by the same compiler.

`GameplayStatics.GetTimeSeconds`, which P9 proved works, at RVA `0x04755750`:

```
movq  %rdi, 0x20(%rbx)     ; P_FINISH
callq 0x14462bd30          ; calls the implementation
testq %rax, %rax
movss 0x748(%rax), %xmm0   ; reads the value
movss %xmm0, (%rsi)        ; stores the result
retq
```

The live one does its work after `P_FINISH`. The cheat has no work to do.

An earlier attempt used `SBPlayerBattleState` as the control, on the strength of
probe_v13 reporting it fired. That reading was wrong, and the binary says so:

```
SBPlayerBattleState      Func: 0x142683F40
SBGameOptionHUDVisible   Func: 0x142683F40
```

One address for two different commands. Linkers fold functions whose code is
byte identical, and two semantically different cheats can only be identical if
neither has a body.

## What still works

- **`slomo`** and other engine console commands. These are UE's own, not the
  game's, and P9 measured a time-rate ratio of 0.52 under `slomo 0.5`.
- **`KismetSystemLibrary.ExecuteConsoleCommand`** as the delivery route.
  `PlayerController:ConsoleCommand` never worked from Lua.
- Everything reflected: properties, `StaticFindObject`, `FindAllOf`. The
  framework's existing playback, placement and physics are untouched by this.

## What this costs

Three things that were treated as solved are not:

- **Loading a cast.** `SBCreateCharacter` is dead, alongside the engine spawn
  (empty shell), `ServerRequest_CreateActor` (RPCs do not execute, probe_v19)
  and `LoadAsset` on a character Blueprint (crashes). Scenes have to be staged
  where the characters already exist.
- **Loading a world.** `SBChangeWorld` is dead. Placement stays manual, and
  level streaming remains the constraint it was.
- **Animation via the game's own player.** `SBPlayCustomAnimByTag` is dead. The
  BlendSpace sample swap in [playback.md](playback.md) is not a fallback, it is
  the mechanism.

## How to check a command before believing in it

This is cheap now, and no command should be trusted without it.

1. Lua: `StaticFindObject("/Script/SB.SBCheatManager:Name")`, then `GetAddress()`
2. Native: read `Func` at `+0xD8` (`UFunction` is `0xE0`, `Func` is its last member)
3. Subtract the module base, `0x140000000`, which is also the preferred base, so
   RVAs apply directly with no rebasing
4. `llvm-objdump -d --start-address=... --stop-address=...` on the shipped exe
5. Look for a call **after** `P_FINISH`. No call means no body.

[probe/P10_targets.lua](../probe/P10_targets.lua) does steps 1 and 2 and hands
the addresses to the native half.

## The lesson worth keeping

Every cheap check passed. The function existed, resolved, had a valid code
pointer, and did not begin with `ret`. The byte-level heuristic in the native
probe reported "has a real body" for all seven functions, including the two that
were provably empty.

Only reading the actual instructions, against a known-good control, gave the
right answer.
