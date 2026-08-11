# Arm and hand geometry, measured

Numbers here are centimetres in Eve's own body frame, relative to
`Bip001-Spine2`, with axes built from her skeleton:

```
up   = Spine2 - Spine1
rt   = R-Clavicle - L-Clavicle
fwd  = cross(rt, up)          left-handed: forward = right x up
```

Read them with `./measure` and `./palm`.

## The forward axis is cross(rt, up), not cross(up, rt)

Unreal is left-handed (X forward, Y right, Z up), so `right x up` is forward.
With the operands the other way round, every forward reading comes out negated.

That sign error survived two sanity checks: the head read `fwd -2.0` and the
freely hanging left hand read `fwd +6.4`, and both are small enough to look
plausible either way. What caught it was `Ab-R-Breast` reading 4.7 cm BEHIND the
spine, which is anatomically impossible.

**Calibrate on a bone whose answer cannot be argued with.** A breast bone must
be in front of the ribcage; a head being slightly forward or slightly back is
not evidence of anything.

## Measure the elbow, not just the hand

A cost function that scores only the wrist position is satisfied by
anatomically absurd arms. Optimising one produced this, scored at 6.1 cm and
called good:

```
shoulder    right +11.5   up +10.1   fwd  +1.5
elbow       right +26.3   up +22.6   fwd +13.7     <- 12.5 cm ABOVE the shoulder
hand        right +11.2   up  +6.9   fwd  +8.0
```

On screen that is a chicken wing: the whole arm flung up and out with the
forearm folded back so the wrist happens to land near the target.

So the score also pays for:

| quantity | definition | want |
| --- | --- | --- |
| drop | `shoulder.up - elbow.up` | +18 to +25 |
| flare | `elbow.right - shoulder.right` | -2 to +6 |

Confirmed against reference footage (`reference/frames/pz_336s.jpg`): the upper
arm hangs down the ribs with the elbow at about waist level, and the forearm
angles forward from there.

## Her arm, as measured

Upper arm and forearm are both **24.2 cm**. Identity rotation on tracks 48/49 is
a T-pose, arm straight out to her right, hand at `right +59.7`.

| control | effect at identity | what it is |
| --- | --- | --- |
| shoulder pitch (track 48) | elbow does not move | twist about the upper-arm axis |
| shoulder yaw | elbow drops `24.2 * sin(yaw)` | abduction, swings the arm down |
| shoulder roll | elbow back `24.2 * sin(roll)` | swings the arm backward |
| elbow roll (track 49) | hand back `24.2 * sin(roll)` | flexion |
| wrist (track 50) | wrist stays, fingers move 5-8 cm | hand orientation |

`yaw ~= 90` hangs the arm straight down the ribs. Once it is down, shoulder
PITCH becomes the control that aims which way the elbow folds, tracing the hand
around a cone; at flexion 120 that circle has radius ~21.5 cm centred at
`(right 14.0, fwd -1.7)`, so `pitch ~= 180` is what brings the hand in front.

Solved pose for a right hand on her right breast:

```
track 48 (shoulder)  pitch 180  yaw 85  roll -20
track 49 (elbow)     roll 135
  -> hand right +14.4  up -3.1  fwd +12.6    drop 23.0   flare 3.7
```

## Hand orientation is a separate problem

Nothing about wrist position constrains which way the palm faces, and an
unposed wrist reads on screen as fingers splayed forward holding an invisible
ball rather than a hand cupping anything. No distance metric can see this.

`./palm` builds a frame from the knuckles (Biped naming: Finger0 thumb,
Finger1 index, Finger4 pinky):

```
along   wrist -> middle fingertip        the direction the fingers point
across  index knuckle -> pinky knuckle
normal  cross(across, along)             the direction the PALM faces
```

`cross(along, across)` is the back of the hand. Check on a real right hand held
palm-down with fingers forward: along = forward, across = right, and
forward x right points up, which is the knuckles.

From reference, a hand cupping a breast from the outside:

- the hand arrives from **outside and below**, not from the front
- the **palm faces the midline**, roughly `right -0.8`, and tips back into the
  chest, `fwd -0.55`
- the fingers point **up and inward**, spread, wrapping over the front
- the thumb sits above, on the inner side

Unposed, her palm faces up (`up +0.62`) and back, which is 60.7 degrees off.
Rolling the wrist alone never gets below 60 degrees: roll spins the palm through
up / forward / back but never swings it toward the midline. That needs all three
axes.

## Measuring anything on a character

The idle animation moves her hand 20-40 cm on its own, which swamps most
effects worth finding. Four consecutive reads of an unchanged pose once gave
47.5, 42.1, 31.0 and 5.4 cm.

1. `./sblove exec "slomo 0.01"` first, unless the tracks being measured are
   already pinned to a constant, in which case the arm no longer drifts and
   normal speed reads stable to under 1 cm.
2. Sample the same bone several times before changing anything, and confirm the
   noise floor really is near zero.
3. Alternate on and off more than once. A single before-and-after cannot tell an
   effect from the character still settling.
4. `./sblove exec "slomo 1.0"` afterwards.
