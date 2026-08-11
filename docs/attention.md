# Attention map: what a hand is drawn to

A scene should not need every act hand-authored. Given a body and an intent, the
framework should know **where hands want to go** and how strongly. That is what
makes a scene interactive rather than a fixed set of animations.

The magnet already solves "put the palm HERE". This is the layer above it:
choosing the HERE, and weighting it.

## Tiers

| tier | targets | weight |
| --- | --- | --- |
| 1 | nipple, breast, vagina, rectum | strongest |
| 2 | exposed skin, anything not covered by costume | medium |
| 3 | everything else | weak, mostly avoidance |

Tier 3 matters as much as tier 1: it is what stops a hand routing through her
thigh on the way somewhere else. `./clearance` already measures that, against
36 collision bodies read out of the physics asset.

## What the rig gives, and what has to be derived

Measured on the live skeleton:

```
Ab-L/R-Breast, Dm-*-Breast-Point, Ab-*-Breast-Link    8 bones
Ab-L/R-Hip, Ab-L/R-Hip-Reg                            4 bones
Bip001-Pelvis                                         1 bone
```

There are **no** nipple, vagina or rectum bones. Those are derived anchors:

```
nipple  = Ab-R-Breast + outwardNormal * breastRadius
vagina  = Bip001-Pelvis + (0, -down, +forward) * pelvisRadius
rectum  = Bip001-Pelvis + (0, -down, -back)    * pelvisRadius
```

Every term on the right is read from the loaded PhysicsAsset (`--bodies`), so
the anchors follow whatever body is equipped rather than being constants. That
matters: an outfit mod can replace the body entirely.

**The body is not always stock.** The DOAXVV Slipstream CNS costume declares
`"FitMeshType": "Body"` and ships `DOAXVV_Slipstream_Malfunction_PhysicsAsset`,
so both the mesh AND its collision bodies are the mod's. Radii read from
`CH_P_EVE_01_Physics` describe a body that is not on screen. Anchors must come
from the LOADED asset, which is what `K2_GetClosestPointOnPhysicsAsset` gives
for free at runtime.

## Exposed skin

Tier 2 needs to know what the costume covers. Ideas, cheapest first:

1. **Material sections.** A skeletal mesh is split into sections, each with a
   material. Skin materials and cloth materials are distinguishable by name --
   the Slipstream mod ships `SLST_Body_Inst`. A section using a skin material is
   exposed. This is readable from the mesh asset with no runtime support.
2. **Costume mesh occlusion.** The outfit is a separate mesh; body vertices
   inside it are covered. Exact, and much more expensive.
3. **Texture opacity.** Only helps where coverage is painted rather than
   modelled.

Option 1 is the one worth building: it is static per outfit, so it can be
computed once and cached alongside the anchors.

## Why this is the right shape

An act then declares intent rather than geometry:

```
act "grope"     magnet R-Hand -> tier1.breast.right
act "tease"     magnet R-Hand -> tier2.nearest, dwell 3s
```

and the same act works on a different body, a different costume, or a second
actor, because every target resolves against the loaded assets.
