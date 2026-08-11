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

No metric caught any of those. Looking did.

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

## Deformation: four routes closed by measurement

| route | why it fails |
| --- | --- |
| collider bound to the hand | the ONE KawaiiPhysics node roots on `Ab-TL-HairB01`, her hair |
| animation tracks on the breast | `Dm-`/`Ab-` breast bones are runtime-driven; frozen test shows EXACTLY zero response |
| bone scale | UE does not export scale on deformation bones (`perTrack=2`) |
| reroot KawaiiPhysics at the breast | writes and persists, does nothing: the chain is cached at init, and the breast chain is zero-length |

What is left: **native**. `BlueprintUpdateAnimation` IS implemented on
`CH_P_EVE_01_AnimBP_New` and is a real UFunction, so the DLL's existing
ProcessEvent hook already sees it. Compute penetration each frame and write the
breast bone transform directly into the component's transform array.

NOT via `SetBoneLocationByName` -- that lives on `UPoseableMeshComponent`, not
the `USkeletalMeshComponent` Eve has, and would silently do nothing. Same trap
as `GetBoneLocationByName` earlier.

## Repositories

- `SBLoveFramework` -- https://github.com/ngodn/SBLoveFramework
- `tools/SBAnimTool` -- https://github.com/ngodn/SBAnimTool (separate repo, it
  is a general UE 4.26 tool and not specific to this framework)

`assets/` (95 MB of extracted game data) and `reference/frames|sheets` (frames
from commercial releases) are gitignored on purpose -- not ours to redistribute.
