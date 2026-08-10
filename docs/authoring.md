# Authoring animations: the engine route is closed

Established 2026-08-11.

## UE 4.26 cannot be built from source any more

Not by us, not by anyone. Epic has retired the dependency packs for every
version before UE 5.2.

Measured against the **official** `EpicGames/UnrealEngine` manifests, with a
GitHub account linked to Epic and full repo access:

| tag | first dependency pack |
| --- | --- |
| 4.26.2-release | **403** |
| 4.27.2-release | **403** |
| 5.0.3-release | **403** |
| 5.1.1-release | **403** |
| 5.2.1-release | 200 |
| 5.8.1-release | 200 |

The retirement is by pack format. Old packs look like
`UnrealEngine-14666150-a3df5ef1b6e548ecb11ff536eabb1049`; current ones look
like `UnrealEngine-25328963`. Everything in the old format is gone.

Things checked and ruled out along the way, so nobody repeats them:

- **Not our network.** The same URL returns 403 from an unrelated network.
- **Not the fork.** `ngodn/UnrealEngine-4.26` carries byte-identical
  `RemotePath` values to Epic's official 4.26.2 manifest. The fork was fine.
- **Not a stale manifest.** The official manifest has the same dead `BaseUrl`,
  `http://cdn.unrealengine.com/dependencies`.
- **Not http-vs-https, not the user agent, not a pruned single blob.** All
  packs, all hosts, root included.
- **No prebuilt exists.** Epic never shipped UE4 binaries for Linux; their
  Linux download is UE5 only, which is why the AUR's `unreal-engine-bin` is
  5.x. The AUR's `unreal-engine-4` is 4.27.2 and builds from source, so it hits
  the same wall. Anything else advertising a prebuilt UE4 is redistributing
  Epic's engine against their EULA, which is not a category worth trusting with
  a binary.

A newer engine does not help. A cooked `.uasset` carries the engine's package
and custom version numbers, so an asset cooked by 5.2+ will not load in a 4.26
game.

## What the clone is now for

`native/UnrealEngine` stays. Without dependencies it cannot build, but it is
the complete and authoritative C++ **specification** of the format we need to
write:

```
Engine/Source/Runtime/Engine/Private/Animation/AnimSequence.cpp
Engine/Source/Runtime/Engine/Public/AnimEncoding.h
Engine/Source/Runtime/Engine/Public/AnimEncoding_ConstantKeyLerp.h
Engine/Source/Runtime/Engine/Public/AnimEncoding_PerTrackCompression.h
Engine/Source/Runtime/Engine/Public/AnimEncoding_VariableKeyLerp.h
```

There is no ACL plugin in 4.26, so Stellar Blade's animations use one of the
built-in codecs above, and each is fully described in that source.

## The remaining route: UAssetAPI

Build the `AnimSequence` directly, with no engine.

UAssetAPI reads and writes cooked `.uasset` files given a `.usmap` schema, and
this project already depends on it: `tools/SBTableTool` is built on it, and it
is how `CharacterTable` was read and how the `SBAutoParry` pak was produced.

```
an existing Eve AnimSequence   (correct skeleton, correct format)
  -> UAssetAPI decode
  -> replace the bone track data
  -> UAssetAPI encode
  -> retoc to-zen  ->  .utoc/.ucas/.pak
```

The hard part is the compressed bone tracks. Keyframes are quantised by one of
the codecs above rather than stored as a plain array, so writing them back
correctly is real reverse-engineering, with the 4.26 source as the reference.

This is no longer the fallback. It is the only route.

## What already works, and does not need any of this

Worth stating so the scope stays honest. The framework can already **play** any
animation the game ships, via the BlendSpace sample swap in
[playback.md](playback.md), and hold values against the anim graph via the
native `ProcessEvent` hook. What is missing is only the ability to introduce a
pose the game does not already contain.

## First recon: the codec is the stock one

`Proto_Walk.uasset` extracted from the shipped paks references:

```
/Engine/Animation/DefaultAnimBoneCompressionSettings
/Engine/Animation/DefaultAnimCurveCompressionSettings
/Game/Art/Character/PC/CH_P_EVE_01/CH_P_EVE_01_Skeleton
```

This is the best case available. Stellar Blade did not ship a custom codec or
ACL; it uses Unreal's stock 4.26 bone compression, which the cloned source
describes in full. The asset is small too, 3 KB of header and 49 KB of track
data, so the payload is one animation's worth of quantised keys rather than
anything exotic.

Skeleton to author against: `CH_P_EVE_01_Skeleton`.

## Decoded: the format is fully readable without the engine

`tools/SBAnimTool` reads a shipped Stellar Blade `AnimSequence` end to end.
UAssetAPI handles the UObject property list; everything after it is the block
written by `FCompressedAnimSequence::SerializeCompressedData`, reimplemented
from the 4.26 source.

`Proto_Walk`, from the shipped paks:

```
CompressedRawDataSize        88320
tracks                       138
CompressedCurveNames         0
bUseBulkDataForLoad          0
CompressedByteStream         37308 bytes
BoneCodecDDCHandle           AnimCompress_PerTrackCompression_6
CompressedNumberOfFrames     37
KeyEncodingFormat            2  (AKF_PerTrackCompression)
```

### Layout, as measured rather than assumed

The compressed block starts **22 bytes** into UAssetAPI's trailing data:

```
16 bytes   skeleton GUID          not shown by UAnimSequence::Serialize
 2 bytes   FStripDataFlags
 4 bytes   bSerializeCompressedData
```

Two things the source alone would have got wrong, both found by hexdump:

- The 16-byte GUID is not visible in `UAnimSequence::Serialize`.
- `bUseBulkDataForLoad` costs **4** bytes, not 1. UE serialises `bool` through
  `FArchive` as `int32`. The same applies to `bSerializeCompressedData`.

The parser rejects every offset whose values fail a sanity check and reports
which it rejected, so a wrong guess cannot masquerade as a successful parse.
Offsets 0, 2 and 6 were all rejected before 22 succeeded.

### What this means for authoring

The codec is `AnimCompress_PerTrackCompression` with `AKF_PerTrackCompression`,
and 4.26 describes it completely in
`Engine/Source/Runtime/Engine/Public/AnimEncoding_PerTrackCompression.h` and
its `.cpp`. Per-track compression stores a format per track inside the byte
stream, which is why the three global format fields read `ACF_Identity`.

138 tracks across 37 frames in 37308 bytes is roughly 7 bytes per track per
frame, consistent with quantised keys rather than raw floats.

Reading is solved. Writing is the next step: decode the per-track offsets and
key data, replace the tracks for the arm chain, and re-encode.

### Track data, fully decoded

The 37308-byte buffer slices exactly, with no bytes left over:

```
CompressedTrackOffsets       276 int32   = 2 per track, translation then rotation
ScaleOffsets.OffsetData      138 int32   = 1 per track, StripSize 1
key stream                 35652 bytes
                           ------
                           37308        matches the buffer exactly
```

`-1` in an offset means the track has no data of that kind. Each track's entry
in the key stream opens with a packed int32 header, decomposed per
`FAnimationCompression_PerTrackUtils::DecomposeHeader`
(AnimationCompression.h:788):

```
NumKeys     = Header & 0x00FFFFFF
FormatFlags = (Header >> 24) & 0x0F
KeyFormat   = (Header >> 28) & 0x0F
```

`Proto_Walk`, first tracks:

```
track 0   rot   keys=  1  ACF_Fixed48NoW          root, constant, no translation
track 1   trans keys= 37  ACF_Float96NoW
          rot   keys= 37  ACF_Fixed48NoW
track 4   trans keys=  4  ACF_IntervalFixed32NoW  key-reduced
track 6   trans keys=  2  ACF_Float96NoW
```

Key counts of 1, 2, 4 and 37 against a 37-frame sequence are what key reduction
produces, and 37 matches `CompressedNumberOfFrames` exactly. Per-track formats
differ track by track, which is why the three global format fields read
`ACF_Identity`.

A first attempt had the header fields the wrong way round and reported key
counts in the millions. That is why the layout above was read out of the source
rather than inferred from plausible-looking output.

## State: reading is finished

A shipped animation can now be taken apart completely, with no engine, from
asset header down to per-track key formats. What remains for authoring is the
write side: decode the individual keys for a chosen track, substitute new
values, re-encode, and repack.

## The size model is complete: 17/17 animations, every track exact

Each track's data must end exactly where the next track's begins. That is a
whole-file consistency check the data itself provides, and it is unforgiving: a
single wrong rule shows up immediately.

```
Proto_Walk and 16 siblings   374/374, 572/572, 571/571 ...
exact: 17    mismatched: 0
```

Per track, from `GetAllSizesFromFormat` (AnimationCompression.h:741) with
`CompressedRotationStrides` and `PerTrackNumComponentTable` (AnimEncoding.cpp:42
and :69):

```
size  = 4                                  packed header
      + fixedBytes                         IntervalFixed32NoW only: min/range pairs
      + bytesPerKey * numKeys
pad to 4
      + numKeys * (numFrames > 255 ? 2 : 1)   if FormatFlags & 0x08
pad to 4
```

Three rules came only from the data disagreeing, not from reading the source:

- **Scale tracks share the key stream.** `ScaleOffsets.OffsetData` addresses the
  same buffer as the translation and rotation offsets. Ignoring them made every
  track preceding a scale track look undersized: 104/374.
- **Keys are padded before the time table**, not only at the end. Without the
  inner alignment, two tracks came out exactly 4 bytes short: 372/374.
- **The time table is 2 bytes per entry above 255 frames.** Only
  `Proto_Walk_END_R`, at 281 frames, exposed this: 264/374 on that file alone.

Each was found by a check that reported which track failed and by how much,
rather than by a parser that accepted whatever it read.

`ACF_Float96NoW` is three uncompressed 32-bit floats per key. Authoring a track
in that format needs no quantisation at all, which is the natural choice for a
hand-built pose.
