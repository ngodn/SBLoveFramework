# Where we are

Working notes for resuming. Everything below is measured, not assumed.

## The loop that matters

Two halves, both on demand:

- **Control** — `./sblove`, `./pose`, `./bake` write `SBLove_cmd.txt`; the Lua
  probe executes and answers in `SBLove_out.txt`. No restart per iteration.
- **Sight** — Playwright holds a browser session on the user's `lwfa` stream
  (`https://192.168.1.51:8443/`, password from the user, `.env` on that machine).
  Screenshot the DOM element `application "StellarBlade"`, then crop with PIL.
  Save screenshots to `.playwright-mcp/`, NOT the project root.

The sight half is the important one. Numbers and the screen disagreed all
session, and the screen was always right:

| what the numbers said | what was true |
| --- | --- |
| 6.1 cm from target | elbow 12.5 cm ABOVE the shoulder, a chicken wing |
| every waypoint 0.5-1.6 cm | solving the WRIST, palm carried 4 cm past her |
| reach 3.7 cm (better!) | palm in her cleavage, not on her breast |
| reach 5.3 cm (worse!) | correct, cupping from outside |
| same angles: 2.80 then 45.23 | measuring her REST pose and calling it the result |

No metric caught any of those. Looking did.

## The handshake bug, because it invalidates old numbers

`./pose` used to write a handoff file and `sleep 0.8`, on the reasoning that
the DLL polls every 500 ms. When a patch had not landed in time, the next
command measured her PREVIOUS pose and credited it to the angles just
requested. `./magnet` is closed loop and believes what it reads, so a single
stale sample poisons the finite-difference Jacobian and every iteration after.

Caught by screenshot: a solve reported the palm 45.23 cm from a target that the
SAME angles had measured at 2.80 cm minutes earlier, and she was standing in
her rest pose. Rest measures drop 22.5, flare 2.0, hand ~45 cm from the breast.

FIXED, natively: `ApplyAnimPatch` writes the stamp it applied to
`SBLove_ack.txt`, and callers wait for their own stamp. `./pose` exits 2 loudly
on a 5 s timeout instead of pretending to have worked, and `magnet`'s `sh()` no
longer discards exit codes, which is what made a failed pose invisible.

No sleep constant can fix this: the wait is on an EVENT, not a duration.

**Treat any measurement recorded before this fix as suspect**, including the
elbow's `drop 13.7` and the path solved into `reference/path-preack.txt`.

## Working

- **magnet** solves her arm onto a bone-relative target against the live game,
  0.2-1.8 cm. Closed loop with a measured Jacobian, because an analytic model
  was wrong about euler order and handedness (det = -1, a reflection).
- **placement** offsets derived from her PhysicsAsset via `--bodies`, not tuned.
- **clearance** measures penetration against 36 collision bodies.
- **bake** turns a path of targets into animation keys, guarded: non-converged
  and buried waypoints are rejected rather than cached.
- **curl** animates her fingers with the reach.
- **anchors** derives tier-1 attention targets (docs/attention.md).

Confirmed on screen: she reaches up, cups her own breast with curled fingers,
returns to rest.

## Open

1. **Elbow rides high.** `drop 13.7` against a wanted 18-25. The null-space term
   that tidies it only engages inside 6 cm, and solves now converge before that,
   so it never runs. Raise the gate -- null-space motion cannot move the hand by
   construction, so this is safe.
2. **Geometry is stock Eve's, the body is not.** The DOAXVV Slipstream CNS
   costume declares `"FitMeshType": "Body"` and ships its own PhysicsAsset, so
   4.70 / 10.37 describe a body that is not on screen. retoc cannot extract it
   (CNS containers use DirectoryIndex, the base game PartitionSize, and they
   cannot be composited). The fix is the `surface` command --
   `K2_GetClosestPointOnPhysicsAsset` queries whatever is LOADED. It tries five
   out-param calling conventions in one pass; needs one restart to settle.
3. **Deformation.** The only real feature gap.

## DEFORMATION WORKS (route 5, confirmed on screen)

The feature gap is closed. A ModifyBone node's Translation, held every frame by
the DLL, visibly displaces her breast.

```
pick AnimGraphNode_ModifyBone_6     alpha 1.00, was on Bip001-Prop1
bone Ab-R-Breast
push 8 0 0
```

8 cm is unmistakable on screen: the breast displaces and the costume cup
separates from the body. Contact-scale squish will be 1-3 cm.

**THE THING THAT MATTERS, and it cost most of an evening: borrow a node the
game ACTUALLY EVALUATES.**

`./sblove status` lists seven ModifyBone nodes. Two sit at alpha 0.00 on toe
bones and look like the obvious ones to borrow, being visibly unused. They are
unused because THE GRAPH NEVER RUNS THEM. Writes to them land in the struct,
persist, read back correctly, and do nothing -- the same signature as the
KawaiiPhysics reroot, and for a completely different reason.

The five at alpha 1.00 (driving `Bip001-Prop1` and `Ab_Drone_Ctl`) are
evaluated. Borrowing one of those works immediately.

How to tell them apart, since the field values look identical: point the node
at `Bip001-Head` and ask for `pose 0 60 0`. If her head does not turn, the node
is not in the graph. This test takes seconds and is worth running before ANY
experiment on a node.

Two false conclusions were reached before this, and both looked convincing:

| what was seen | what it actually was |
| --- | --- |
| one screenshot showing a dramatic displacement | not reproducible; a transient, not the mechanism |
| bone position read back unchanged at +/-80 | `Where()` cannot see ModifyBone output AT ALL |

`Where()` reads a transform computed before the skeletal controls run, so it is
useless for verifying this. There is no measurement for deformation. Only the
screen.

## Deformation: four routes closed by measurement

| route | why it fails |
| --- | --- |
| collider bound to the hand | the ONE KawaiiPhysics node roots on `Ab-TL-HairB01`, her hair |
| animation tracks on the breast | `Dm-`/`Ab-` breast bones are runtime-driven; frozen test shows EXACTLY zero response |
| bone scale | UE does not export scale on deformation bones (`perTrack=2`) |
| reroot KawaiiPhysics at the breast | writes and persists, does nothing: the chain is cached at init, and the breast chain is zero-length |

### The BlueprintUpdateAnimation plan was wrong -- do not build it

Previously recorded here as the way forward: hook `BlueprintUpdateAnimation`
via the DLL's ProcessEvent detour and write the breast bone transform into the
component's transform array. **That cannot work, for the same reason as the
four routes above.**

UE splits the animation frame into **Update** and **Evaluate**. Update runs the
event graph so the graph has current variables; it explicitly does not touch
bone transforms. Evaluate runs afterwards and PRODUCES the pose. So a transform
written from a `BlueprintUpdateAnimation` hook is overwritten by evaluation on
the very same frame, every frame. It would look exactly like the frozen-track
test: writes land, persist, and change nothing on screen.

(It was also going to be written via `SetBoneLocationByName`, which lives on
`UPoseableMeshComponent`, not the `USkeletalMeshComponent` Eve has, and fails
silently. Same trap as `GetBoneLocationByName`.)

### Route 5: the ModifyBone node, which runs INSIDE evaluation

`FAnimNode_ModifyBone` is a skeletal control, so it runs during Evaluate. That
is the right phase by construction rather than by luck, and the DLL already
drives one of these nodes successfully -- it is how the pose hold works, so the
mechanism is proven on screen.

`AnimGraphRuntime.hpp:345` gives the layout, and translation sits right beside
the rotation the DLL already writes:

```
FBoneReference BoneToModify   0x00C8      TranslationMode   0x00FC
FVector        Translation    0x00D8      RotationMode      0x00FD
FRotator       Rotation       0x00E4  <-- already written by ApplyPose()
FVector        Scale          0x00F0      TranslationSpace  0x00FF
```

Eve's AnimBP has exactly ONE: `AnimGraphNode_ModifyBone_6` at `0x0F70`
(`CH_P_EVE_01_AnimBP_New.hpp:10`). One node means one bone, so retargeting it
at the breast has to be tested against the bone-caching trap that killed the
KawaiiPhysics reroot.

The open question, and the cheap experiment to run first: `FBoneReference` is
`0x10` bytes with `BoneName` its only UPROPERTY, so the resolved index lives in
the transient tail (`BoneIndex`, and `bUseSkeletonIndex`). ModifyBone resolves
name to index in `InitializeBoneReferences`, at cache-bones time. Writing the
NAME alone will almost certainly do nothing. Writing name AND index together
might. Test that before building anything on top of it.

If the node cannot be retargeted, the fallback is a native hook on
`FinalizeBoneTransform` / `RefreshBoneTransforms`, which run after evaluation
and before the render -- hookable by RVA the same way ProcessEvent already is.

## Repositories

- `SBLoveFramework` -- https://github.com/ngodn/SBLoveFramework
- `tools/SBAnimTool` -- https://github.com/ngodn/SBAnimTool (separate repo, it
  is a general UE 4.26 tool and not specific to this framework)

`assets/` (95 MB of extracted game data) and `reference/frames|sheets` (frames
from commercial releases) are gitignored on purpose -- not ours to redistribute.
