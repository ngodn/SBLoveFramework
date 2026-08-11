# The magnet: targets instead of joint angles

Everything so far has posed the arm by choosing joint angles and then measuring
where the hand ended up. That is backwards. What a scene actually wants to say
is "her hand is ON her nipple", and it should stay true while she breathes,
shifts weight, or the body underneath moves.

A magnet is a **target the hand is solved onto**, expressed relative to a bone:

```
target = Ab-R-Breast + (lateral, up, forward)   in her body frame
```

Because the target is bone-relative, it tracks the body for free. Because the
arm is solved onto it rather than keyframed at it, the same act works on a
different pose, a different body, or a second actor.

## Why this is baked, not runtime

The engine's own hand IK is closed, and this was measured rather than assumed:

- `Enable_R_Hand` at `+0x11191` with a world target in `RightHitLoc` at
  `+0x113FC` does nothing. Four on/off cycles at `slomo 0.02` agree to 0.01 cm.
  The write is not the problem: reading the property back returns true. The rig
  simply is not evaluated.
- `AnimGraphNode_ModifyBone` pins are copied from anim-BP variables after the
  event graph runs and immediately before evaluation, so a write during
  `ProcessEvent` lands in the window between the two and is overwritten.

So there is no runtime lever to attract a hand with. But there is total control
over the compressed animation keys, which is strictly more powerful for authored
acts: the solve happens once, offline, and the result is an ordinary animation
that costs nothing at runtime.

The magnet is therefore a **solver in SBAnimTool**, not a node in the anim graph.

## The solve: measured, not derived

Both segments measure **24.2 cm**, so this looks like the textbook two-link
case, and it was written that way first. That version is gone. It failed three
times, each failure invisible until the next one surfaced:

| attempt | what gave it away |
| --- | --- |
| composing rotations in its own order | hand landed on target, **elbow 13 cm** from prediction |
| fitting the bone frame to measurements | **det = -1**, a reflection: the engine is left-handed and quaternion sense does not carry over |
| the best fit obtainable | 9.7 degrees of residual, about **8 cm at the wrist** |

So the Jacobian is **measured in the game**. Four probes give
`d(hand)/d(angle)` directly, and that cannot disagree with the engine about
handedness, euler order, or rest pose. Then damped least squares, with the step
capped, because an undamped solve produced 400-degree angles.

It converges in five iterations:

```
iter 1   miss 11.50 cm
iter 2   miss  6.69
iter 3   miss  5.30
iter 4   miss  3.68
iter 5   miss  0.48   converged
```

Slower per solve than closed form, but the result is baked once into keys, so
the cost is paid at authoring time and nothing runs at runtime.

## The fourth degree of freedom

Four angles, three constraints. The arm can **swivel** about the
shoulder-to-hand line with the hand staying exactly where it is, and that free
DOF does not sit still: solving for position alone converged to 0.48 cm while
the elbow slid from flare +8.0 to **-9.8**, tucked across her torso.

This is the same failure as the very first search, which parked the elbow
12.5 cm ABOVE the shoulder while scoring well. A hand position simply does not
determine an arm.

So the swivel is spent deliberately, as a fourth residual pulling the elbow
toward a chosen flare, weighted below the hand:

| quantity | definition | want |
| --- | --- | --- |
| drop | `shoulder.up - elbow.up` | +18 to +25 cm |
| flare | `elbow.right - shoulder.right` | -2 to +6 cm |

`./measure` checks flare in **both** directions. Checking only the upper bound
reported "OK" for that -9.8 cm elbow.

## The contact offset must come from the MESH, not from a constant

A target written as `Ab-R-Breast + (6, -2, 9)` is calibrated to one body. Outfit
mods, and CNS suits in particular, frequently bundle their own body mesh with a
different bust shape. The same constant then puts the hand inside her on one
body and floating off her on another, and nothing in the numbers would say so.

`USkeletalMeshComponent` answers it directly:

```
K2_GetClosestPointOnPhysicsAsset(WorldPosition,
    out ClosestWorldPosition, out Normal, out BoneName, out Distance)
```

That queries the physics asset of the mesh **actually loaded**, so the answer
follows whatever body is equipped. It also returns:

- the **normal**, which is the direction to push flesh for a squish, and
- the **owning bone**, which says whether the nearest surface is really the
  breast or a rib.

So the target becomes "on her surface, near this bone", not a magic triple.
`./sblove surface Ab-R-Breast` reports it.

The caveat is honest: a physics asset is capsules and spheres, not the render
mesh, so this is the collision silhouette rather than the skin. It is still
derived from the loaded asset rather than guessed, and it is per-body correct,
which the constant never was.

## Contact, push and squish

There is no nipple bone. The whole breast chain is collapsed onto one point:

```
Dm-R-Breast-Point  (57678.1, -84674.6, 2241.6)
Dm-R-Breast        (57678.1, -84674.6, 2241.6)
Ab-R-Breast-Link   (57678.1, -84674.6, 2241.6)
Ab-R-Breast        (57678.1, -84674.6, 2241.6)
```

All four are identical, so a nipple target is an offset from `Ab-R-Breast`, not
a bone that can be read. The offsets need calibrating against the mesh visually,
once, and then they are constants.

Deformation needs no animation at all, and does not need the breast bone
displaced either. That was the first plan here and it was wrong: pushing
`Ab-R-Breast` by penetration depth would be fighting the physics rather than
using it.

KawaiiPhysics already pushes its chain out of any collision volume, every
frame. So the squish is one binding:

```
bind spherical 1 Bip001-R-Hand 7
```

`Scripts/contact.lua` has had `Contact.BindToBone(instance, kind, index,
boneName, radius, offset)` all along. Bind a sphere to the hand, and the engine
does contact, deformation and spring-back for free, with no per-tick cost on
our side.

Two rules that come with it:

- **Take over an existing limit, do not grow the array.** A resized `TArray` on
  a live anim node is a far bigger change than an edited entry, and the game
  already ships several volumes. `colliders` lists them.
- **Release on unload.** A volume left bound to the wrong bone stays wrong for
  the rest of the session, the same way the borrowed `ModifyBone` node does.

The depth of the squish is then just how far the `press` waypoint sits INSIDE
her: the target is placed closer to the ribcage than the surface, the hand
follows it, and the collision volume does the rest.

## Pacing: what makes it read as touch rather than collision

Timing is what separates a hand landing on a body from a hand *touching* one.
From the animation literature, and it matches the reference footage:

- **Approach slowly.** Extended time before contact is what builds anticipation;
  the canonical example is a character reaching for a door handle, where the
  delay before the hand arrives carries the whole moment.
- **Anticipation before the reach.** A small movement away first, which also
  gives the motion somewhere to accelerate from.
- **Contact slows things down, it does not speed them up.** After contact the
  motion should become smaller and slower.
- **Ease in and out of every segment.** Constant velocity between poses is the
  single thing that reads as robotic.
- **Overshoot and settle.** Press slightly past the target and relax back, so
  contact has weight instead of stopping dead.
- **The body being touched must respond**, or it reads as touching an object.
  Breathing rate and depth in the spine tracks, the breast deforming, fingers
  flexing. Small habitual motion is what sells a character as alive.

Pressure should cycle rather than hold: squeeze and release, with the release
slower than the squeeze.

## What a scene declares

```
act "grope"
  magnet  R-Hand -> Ab-R-Breast + (6, -2, 9)     palm toward the midline
  path    rest -> outer breast -> nipple
  pace    approach 2.5s, contact 0.4s, knead 3s/cycle
  respond breast squish 0.6, breathing +30%
```

None of that mentions a joint angle, which is the point.
