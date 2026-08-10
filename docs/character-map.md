# Resolving any character in Stellar Blade

How to go from a character's name to the Blueprint class you can `FindAllOf`.
This is fully offline and does not need the game running.

## The method

Two DataTables hold everything:

- `/Game/Local/Data/CharacterTable` — stats, rank, tribe, keyed by character ID
- `/Game/Local/Data/CharacterAppearanceTable` — **`CharacterAssetPath`**, the
  Blueprint asset for that character

Both are extractable from the shipped paks with no AES key.

```bash
cd /home/eins0fx/development/mods/stellar-blade
P="/mnt/eins0fxE/SteamLibrary/steamapps/common/StellarBlade/SB/Content/Paks"
R=./tools/retoc-build/release/retoc
M=./research/StellarBlade_retail_dumped.usmap

# pull the table out of the paks (Zen -> legacy .uasset)
$R to-legacy --no-shaders -f CharacterAppearanceTable "$P" /tmp/tables

A=/tmp/tables/SB/Content/Local/Data/CharacterAppearanceTable.uasset

# find a character by name
dotnet run --project tools/SBTableTool -- grep "$A" "$M" Raven

# read its blueprint path
dotnet run --project tools/SBTableTool -- dump "$A" "$M" M_Raven | grep CharacterAssetPath
```

`CharacterAppearanceTable` has **212 rows**, so every character in the game is
resolvable this way.

The runtime class name is the asset name with `_C` appended, because these are
Blueprint generated classes:

```
/Game/Art/Character/Monster/CH_M_NA_53/Blueprints/CH_M_NA_53_Blueprint
                                                  ^^^^^^^^^^^^^^^^^^^^
FindAllOf("CH_M_NA_53_Blueprint_C")
```

## Why this method is trustworthy

It was validated against known-good answers before being used for anything new.
CNS hardcodes Adam and Lily, having found them by other means, and the table
agrees exactly:

| Character | CNS hardcodes | Table says | Match |
| --- | --- | --- | --- |
| Adam | `CH_NPC_Adam_01_Blueprint_C` | `.../CH_NPC_Adam_01/Blueprints/CH_NPC_Adam_01_Blueprint` | yes |
| Lily | `CH_NPC_01_Blueprint_C` | `.../CH_NPC_01/Blueprints/CH_NPC_01_Blueprint` | yes |

Two independent sources agreeing is the control. Last session's worst mistakes
came from trusting an instrument that was never checked against a known answer,
so this check is not optional.

## The map

### SBLoveFramework's four characters

| Name | Table row | Blueprint class for `FindAllOf` |
| --- | --- | --- |
| **Eve** | *(player)* | not by class — use `UEHelpers.GetPlayer()` |
| **Adam** | `N_Adam` | `CH_NPC_Adam_01_Blueprint_C` |
| **Lily** | `N_Lily` | `CH_NPC_01_Blueprint_C` |
| **Raven** | `M_Raven` | `CH_M_NA_53_Blueprint_C` |

Eve is the player pawn, so she is fetched from the controller rather than
scanned for. That is what CNS does and it is both faster and unambiguous.

### Raven specifics

Raven has **two bodies**, and a scene targeting the wrong one gets nothing:

| Form | Row | Blueprint class |
| --- | --- | --- |
| Humanoid Raven | `M_Raven` | `CH_M_NA_53_Blueprint_C` |
| Raven Beast | `M_RavenBeast` | `CH_M_NA_42_Blueprint_C` |

From `CharacterTable`, `M_Raven` is `Rank = Boss`, `Tribe = Monster`,
`Flag = Raven`, 248304 max HP. Related rows exist for encounter variants
(`NST_M_Raven_01`, `XION_M_RavenBeast_01`, `CHAL_*` challenge versions,
`N_Raven_Seq` for cutscenes).

**She is a boss, not a persistent NPC.** Unlike Adam and Lily she is not
standing around in the world, so `FindAllOf` returns nothing except during her
encounters or in a cutscene. The framework must treat "actor not present" as a
normal state for her and say so in the UI rather than failing silently.

### Others worth knowing

Resolved with the same method while validating it:

| Name | Row | Blueprint class |
| --- | --- | --- |
| Tachy | `N_TachyNPC` | `CH_NPC_TachyNPC_Blueprint_C` |
| Orcal | `N_Orcal` | `CH_NPC_XionElder_Blueprint_C` |
| Drone | *(CNS)* | `CH_Drone_BP_C` |

Note Orcal's asset is named `XionElder`, which is exactly why guessing class
names from character names does not work and the table is necessary.

## Naming conventions

Now that the pattern is visible, the whole content tree reads easily:

| Prefix | Meaning | Lives under |
| --- | --- | --- |
| `N_` | named NPC | `/Game/Art/Character/NPC/` |
| `M_` | monster / Naytiba, including humanoid bosses | `/Game/Art/Character/Monster/` |
| `P_` | player | `/Game/Art/Character/PC/` |
| `CH_M_NA_NN` | Naytiba number NN, up to at least 53 | |
| `NST_`, `XION_`, `SD_` | encounter/location variant of a base row | |
| `CHAL_` | Boss Challenge version | |
| `_Seq` | cutscene-only version | |

## Reusable artifacts produced

| File | What |
| --- | --- |
| `research/pak-index/asset_paths.txt` | **199,707** package paths, every asset in the game |
| `research/pak-index/pakchunk{0..3}.json` | raw retoc manifests |
| `research/datatables.txt` | all **153** DataTable names under `/Game/Local/Data/` |
| `tools/retoc-build/release/retoc` | built retoc binary |

`asset_paths.txt` answers "does asset X exist and what is its exact path"
instantly, which is what `AniFilePath` entries in animation configs need.

Note cargo's default target dir on this machine is volatile and was wiped
mid-session, so retoc is built with an explicit
`CARGO_TARGET_DIR=tools/retoc-build`. Build it with:

```bash
cd tools/retoc && CARGO_TARGET_DIR=../retoc-build cargo build --release
```
