--[[
    SBLoveFramework -- addon registry
    ------------------------------------------------------------------
    Finds, parses and validates the scene packs that supply this framework's
    content. The framework ships no animations of its own, exactly as BG3SX
    ships none: everything comes from addons.

    WHERE ADDONS LIVE

        Content/Paks/~mods/SBLoveFramework/Scenes/<name>.sblove.json

    That mirrors CNS's layout (Content/Paks/~mods/CustomNanosuitSystem/
    Animations/<name>.dekani.json) on purpose. Anyone who has shipped a CNS
    animation pack already knows where these go, and both sit beside the pak
    that carries the actual animation assets.

    THE FORMAT

        {
          "id":      "author.packname",        required, must be unique
          "name":    "Display Name",
          "author":  "who made it",
          "scenes": [
            {
              "id":          "embrace_standing",
              "displayName": "Embrace",
              "tags":        ["standing", "paired"],
              "actors":      { "A": "Eve", "B": "Adam" },
              "stages": [
                {
                  "id":        "stage1",
                  "alignment": { "forward": 60, "right": 0, "up": 0, "yaw": 180 },
                  "loops": [
                    { "A": "/Game/.../a_L1", "B": "/Game/.../b_L1" },
                    { "A": "/Game/.../a_L2", "B": "/Game/.../b_L2" }
                  ]
                }
              ]
            }
          ]
        }

    `loops` is the intensity axis, gentlest first. `alignment` is measured in
    the ANCHOR's frame in centimetres, and belongs to the animation: two clips
    authored separately never line up from a formula, so whoever made them
    records the offset that fits.

    VALIDATION IS STRICT AND PER FILE

    A malformed addon is reported with its file, its scene and a line number,
    and then skipped. It never takes down the framework or the other addons,
    because a user with twenty packs installed should not lose all of them to
    one stray comma. Errors are collected rather than raised for the same
    reason.
--]]

local Json = require("json")

local Registry = {}

--- Where addon files are looked for, relative to the ~mods directory.
Registry.SUBDIR = "SBLoveFramework/Scenes"
Registry.SUFFIX = ".sblove.json"

-- ------------------------------------------------------------------- state

local packs   = {}      -- id -> pack
local scenes  = {}      -- array of scene definitions, each with .pack
local errors  = {}      -- array of human-readable problems

function Registry.Packs()  return packs  end
function Registry.Scenes() return scenes end
function Registry.Errors() return errors end

local function Problem(format, ...)
    errors[#errors + 1] = string.format(format, ...)
end

-- -------------------------------------------------------------- validation

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

--- An animation path must look like UE's object syntax, "/Game/Path/Asset.Asset".
--- Checking this here turns a silent no-op at scene start into a clear message
--- at load, which is the difference between an addon author fixing it and an
--- addon author giving up.
local function LooksLikeAssetPath(value)
    if not IsNonEmptyString(value) then return false end
    if value:sub(1, 1) ~= "/" then return false end
    return value:find("%.") ~= nil
end

local function ValidateStage(stage, where)
    if type(stage) ~= "table" then
        return nil, where .. ": stage is not an object"
    end
    if not IsNonEmptyString(stage.id) then
        return nil, where .. ": stage has no id"
    end

    local at = where .. " stage '" .. stage.id .. "'"

    if type(stage.loops) ~= "table" or #stage.loops == 0 then
        return nil, at .. ": needs at least one entry in 'loops'"
    end

    for level, loop in ipairs(stage.loops) do
        if type(loop) ~= "table" then
            return nil, string.format("%s loop %d: not an object", at, level)
        end
        if not LooksLikeAssetPath(loop.A) then
            return nil, string.format(
                "%s loop %d: 'A' must be an asset path like " ..
                "/Game/Path/Anim.Anim, got %s", at, level, tostring(loop.A))
        end
        if loop.B ~= nil and not LooksLikeAssetPath(loop.B) then
            return nil, string.format(
                "%s loop %d: 'B' is present but not an asset path (%s)",
                at, level, tostring(loop.B))
        end
    end

    local alignment = stage.alignment
    if alignment ~= nil and type(alignment) ~= "table" then
        return nil, at .. ": 'alignment' must be an object"
    end

    return {
        id          = stage.id,
        displayName = stage.displayName or stage.id,
        tags        = stage.tags or {},
        alignment   = alignment or { forward = 0, right = 0, up = 0, yaw = 180 },
        loops       = stage.loops,
    }
end

local function ValidateScene(scene, packId, index)
    local where = string.format("%s scene %d", packId, index)
    if type(scene) ~= "table" then return nil, where .. ": not an object" end
    if not IsNonEmptyString(scene.id) then return nil, where .. ": has no id" end

    where = packId .. "/" .. scene.id

    if type(scene.stages) ~= "table" or #scene.stages == 0 then
        return nil, where .. ": needs at least one stage"
    end

    local stages = {}
    for position, raw in ipairs(scene.stages) do
        local stage, err = ValidateStage(raw, where)
        if not stage then return nil, err end
        stages[position] = stage
    end

    -- A scene naming a B animation but no B actor cannot be started, and the
    -- failure would otherwise appear much later as a missing partner.
    local wantsPartner = false
    for _, stage in ipairs(stages) do
        for _, loop in ipairs(stage.loops) do
            if loop.B then wantsPartner = true break end
        end
    end
    local actors = scene.actors or {}
    if wantsPartner and not IsNonEmptyString(actors.B) then
        return nil, where ..
            ": has 'B' animations but no actors.B saying who plays them"
    end

    return {
        id          = scene.id,
        displayName = scene.displayName or scene.id,
        tags        = scene.tags or {},
        actors      = actors,
        stages      = stages,
        pack        = packId,
    }
end

--- Validate a whole pack. Returns the pack, or nil plus a message.
function Registry.ValidatePack(document, source)
    if type(document) ~= "table" then
        return nil, source .. ": top level must be an object"
    end
    if not IsNonEmptyString(document.id) then
        return nil, source .. ": missing 'id'"
    end
    if type(document.scenes) ~= "table" or #document.scenes == 0 then
        return nil, source .. ": needs at least one scene"
    end

    local pack = {
        id     = document.id,
        name   = document.name or document.id,
        author = document.author or "unknown",
        source = source,
        scenes = {},
    }

    for index, raw in ipairs(document.scenes) do
        local scene, err = ValidateScene(raw, document.id, index)
        if not scene then return nil, err end
        pack.scenes[#pack.scenes + 1] = scene
    end

    return pack
end

-- -------------------------------------------------------------------- load

function Registry.LoadFile(path)
    local document, err = Json.decodeFile(path)
    if not document then
        Problem("%s", tostring(err))
        return nil
    end

    local pack, invalid = Registry.ValidatePack(document, path)
    if not pack then
        Problem("%s", tostring(invalid))
        return nil
    end

    -- Two packs claiming one id would make scene references ambiguous, so the
    -- first wins and the second is reported rather than silently shadowing it.
    if packs[pack.id] then
        Problem("duplicate pack id '%s' in %s (already loaded from %s)",
            pack.id, path, packs[pack.id].source)
        return nil
    end

    packs[pack.id] = pack
    for _, scene in ipairs(pack.scenes) do
        scenes[#scenes + 1] = scene
    end
    return pack
end

--- Find the ~mods directory the way CNS does, by walking the game's own
--- directory listing rather than assuming a path. Case varies between installs.
local function ModsDirectory()
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or not dirs then return nil, "could not list game directories" end

    local paks = dirs.Game and dirs.Game.Content and dirs.Game.Content.Paks
    if not paks then return nil, "Content/Paks not found" end

    local mods = paks["~mods"] or paks["~Mods"] or paks["~MODS"]
    if not mods then return nil, "Content/Paks/~mods not found" end
    return mods
end

--- ASCII-only check. Non-ASCII directory names come back mangled through this
--- API and the resulting path cannot be opened, so they are skipped with a
--- message rather than producing a confusing "cannot open file" later. CNS does
--- the same, for the same reason.
local function IsAscii(text)
    return not string.find(text, "[^\x20-\x7E]")
end

--- Scan for addon files and load them all.
--- Returns scenes loaded, problems, and how many candidate files were seen.
---
--- The shape of this tree is not obvious and getting it wrong is silent: files
--- hang off `dir.__files`, each with `__name` and `__absolute_path`, while
--- subdirectories are the keys that do NOT begin with "__". A first attempt
--- looked for `__absolute_path` directly on every table, found nothing, and
--- reported "0 files found" while the addon sat exactly where it belonged.
function Registry.ScanAll()
    packs, scenes, errors = {}, {}, {}

    local mods, err = ModsDirectory()
    if not mods then
        Problem("%s", tostring(err))
        return 0, #errors, 0
    end

    -- The whole ~mods tree is walked rather than only the canonical
    -- subdirectory, because installers vary and archives get unpacked in odd
    -- places. Anything whose name ends in the suffix counts.
    local found = 0

    local function walk(dir, name, depth)
        if type(dir) ~= "table" or depth > 8 then return end
        if name and not IsAscii(name) then
            Problem("skipped folder with non-ASCII name: %s", name)
            return
        end

        for _, file in pairs(dir.__files or {}) do
            local fileName = file.__name or ""
            if fileName:sub(-#Registry.SUFFIX) == Registry.SUFFIX then
                found = found + 1
                Registry.LoadFile(file.__absolute_path)
            end
        end

        for key, sub in pairs(dir) do
            if type(sub) == "table" and type(key) == "string"
                and not key:match("^__") then
                walk(sub, key, depth + 1)
            end
        end
    end

    local ok, walkError = pcall(walk, mods, nil, 0)
    if not ok then Problem("scan failed: %s", tostring(walkError)) end

    return #scenes, #errors, found
end

-- ------------------------------------------------------------------ lookup

function Registry.SceneById(id)
    for _, scene in ipairs(scenes) do
        if scene.id == id then return scene end
    end
    return nil
end

--- Scenes carrying every one of the given tags. Matching is case-insensitive,
--- because tags are typed by hand by many different authors.
function Registry.FindByTags(wanted)
    if type(wanted) ~= "table" or #wanted == 0 then return scenes end

    local matched = {}
    for _, scene in ipairs(scenes) do
        local present = {}
        for _, tag in ipairs(scene.tags or {}) do
            if type(tag) == "string" then present[tag:lower()] = true end
        end

        local all = true
        for _, tag in ipairs(wanted) do
            if not present[tostring(tag):lower()] then all = false break end
        end
        if all then matched[#matched + 1] = scene end
    end
    return matched
end

--- Scenes playable with the actors currently in the world. `resolver` is a
--- function taking a character name and returning an actor or nil, so this
--- module stays independent of actors.lua and remains testable offline.
function Registry.Playable(resolver)
    local playable = {}
    for _, scene in ipairs(scenes) do
        local actors = scene.actors or {}
        local okA = not actors.A or resolver(actors.A) ~= nil
        local okB = not actors.B or resolver(actors.B) ~= nil
        if okA and okB then playable[#playable + 1] = scene end
    end
    return playable
end

function Registry.Summary()
    local packCount = 0
    for _ in pairs(packs) do packCount = packCount + 1 end
    return string.format("%d pack%s, %d scene%s, %d problem%s",
        packCount, packCount == 1 and "" or "s",
        #scenes,   #scenes   == 1 and "" or "s",
        #errors,   #errors   == 1 and "" or "s")
end

return Registry
