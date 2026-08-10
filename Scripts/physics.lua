--[[
    SBLoveFramework -- secondary motion
    ------------------------------------------------------------------
    Runtime control of the physics that makes a character read as flesh rather
    than a rig: overshoot, settle, and contact response.

    WHAT STELLAR BLADE ACTUALLY HAS

    Eve's anim graph carries, as writable node properties:

        FAnimNode_KawaiiPhysics  AnimGraphNode_KawaiiPhysics          x1
        FAnimNode_SpringBone     AnimGraphNode_SpringBone_1 .. _26    x27

    Node property writes are proven (see docs/09-playback-solved.md), so all of
    this is reachable without hooks.

    KAWAII PHYSICS

    An open source UE plugin (pafuhana1213). Fake, non-PhysX secondary motion
    driven by a bone chain. Parameters and the author's reference ranges:

        Damping               0.1 - 0.3    resistance. LOWER = acceleration
                                           shows more, so it overshoots further
        Stiffness             0.05 - 0.2   how much the pre-physics pose is
                                           preserved. LOWER = looser, more sway
        WorldDampingLocation  0.5 - 0.8    how much the mesh's world movement
                                           feeds in. LOWER = more inertia when
                                           the character moves
        WorldDampingRotation  0.5 - 0.8    same for rotation
        Radius                             per-bone collision sphere size
        LimitAngle                         rotation clamp; stops it going wild

    bUpdatePhysicsSettingsInGame must be true or edits are ignored at runtime.

    The collision limits (SphericalLimits, CapsuleLimits, PlanarLimits) are the
    contact layer: they are what stops soft chains passing through the body and
    what makes them displace against it instead.

    SPRING BONES

    UE's own simpler system, 27 chains here:

        SpringStiffness     spring constant, higher snaps back harder
        SpringDamping       higher kills oscillation sooner
        MaxDisplacement     clamp on how far a bone may travel
        bLimitDisplacement  whether that clamp applies

    WHY MULTIPLIERS, NOT ABSOLUTE VALUES

    Shift Up tuned these per bone chain, and those values carry the character's
    look. Writing absolute numbers throws that away and makes everything feel
    identical. So a preset here is a set of SCALE FACTORS applied to whatever
    the game shipped, which preserves the relative tuning between chains while
    shifting the overall feel.

    RESTORE

    Every original is recorded before the first write and restored exactly.
    These are node properties on a live anim instance, so a bad value persists
    until the level reloads.
--]]

local Physics = {}

-- ------------------------------------------------------------------ helpers

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function IsLive(object)
    if not object then return false end
    return Try(function() return object:IsValid() end) == true
end

-- ------------------------------------------------------------------- nodes

Physics.KAWAII_NODE = "AnimGraphNode_KawaiiPhysics"

--- The 27 spring bone chains on Eve, plus the unsuffixed one.
Physics.SPRING_NODES = (function()
    local list = { "AnimGraphNode_SpringBone" }
    for i = 1, 26 do
        list[#list + 1] = "AnimGraphNode_SpringBone_" .. i
    end
    return list
end)()

--- Fields scaled on the KawaiiPhysics PhysicsSettings struct.
local KAWAII_FIELDS = {
    "Damping", "Stiffness", "WorldDampingLocation", "WorldDampingRotation",
    "Radius", "LimitAngle",
}

--- Fields scaled on each SpringBone node.
local SPRING_FIELDS = { "SpringStiffness", "SpringDamping", "MaxDisplacement" }

-- ----------------------------------------------------------------- presets

--- Scale factors, applied to the game's shipped values. 1.0 leaves a field
--- untouched. Anything not listed is left alone.
---
--- The direction of each is deliberate. To make secondary motion looser and
--- more responsive you LOWER stiffness and damping, because both resist
--- movement, and you lower world damping so the character's own motion feeds
--- through more strongly.
Physics.PRESETS = {
    --- Put everything back exactly as shipped.
    default = {},

    --- Looser and more responsive. More overshoot, longer settle.
    soft = {
        Stiffness            = 0.55,
        Damping              = 0.70,
        WorldDampingLocation = 0.75,
        WorldDampingRotation = 0.75,
        SpringStiffness      = 0.60,
        SpringDamping        = 0.75,
        MaxDisplacement      = 1.40,
    },

    --- Heavier. Slower to start, slower to stop, reads as more mass.
    weighty = {
        Stiffness            = 0.70,
        Damping              = 0.55,
        WorldDampingLocation = 0.60,
        WorldDampingRotation = 0.60,
        SpringStiffness      = 0.70,
        SpringDamping        = 0.60,
        MaxDisplacement      = 1.60,
    },

    --- Tighter and calmer than shipped. Useful when an animation is already
    --- energetic and the secondary motion starts fighting it.
    firm = {
        Stiffness            = 1.50,
        Damping              = 1.40,
        SpringStiffness      = 1.40,
        SpringDamping        = 1.30,
        MaxDisplacement      = 0.75,
    },
}

-- ------------------------------------------------------- capture / restore

--- { [instance] = { kawaii = {field=value}, springs = { [prop] = {field=value} } } }
local originals = setmetatable({}, { __mode = "k" })

local function KawaiiSettings(instance)
    local node = Try(function() return instance[Physics.KAWAII_NODE] end)
    if node == nil then return nil, nil end
    local settings = Try(function() return node.PhysicsSettings end)
    return node, settings
end

--- Record the shipped values once, before anything is written.
local function Capture(instance)
    if originals[instance] then return originals[instance] end

    local record = { kawaii = {}, springs = {}, updateFlag = nil }

    local node, settings = KawaiiSettings(instance)
    if settings ~= nil then
        for _, field in ipairs(KAWAII_FIELDS) do
            record.kawaii[field] = Try(function() return settings[field] end)
        end
        record.updateFlag = Try(function()
            return node.bUpdatePhysicsSettingsInGame end)
    end

    for _, prop in ipairs(Physics.SPRING_NODES) do
        local spring = Try(function() return instance[prop] end)
        if spring ~= nil then
            local fields = {}
            for _, field in ipairs(SPRING_FIELDS) do
                fields[field] = Try(function() return spring[field] end)
            end
            record.springs[prop] = fields
        end
    end

    originals[instance] = record
    return record
end

Physics.Capture = Capture

-- ------------------------------------------------------------------- apply

--- Apply a preset, or a table of scale factors, to one character.
---
--- Always scales from the CAPTURED originals rather than from the current
--- values, so applying two presets in a row does not compound. Applying `soft`
--- then `firm` gives firm, not soft-times-firm.
function Physics.Apply(instance, preset)
    if not IsLive(instance) then return false, "anim instance is gone" end

    local scales = type(preset) == "string" and Physics.PRESETS[preset] or preset
    if type(scales) ~= "table" then
        return false, "unknown preset: " .. tostring(preset)
    end

    local record = Capture(instance)
    local written = 0
    Physics.lastMiss = nil     -- reflects this call only

    local node, settings = KawaiiSettings(instance)
    if settings ~= nil then
        -- Without this the plugin ignores runtime edits entirely.
        Try(function() node.bUpdatePhysicsSettingsInGame = true end)

        for _, field in ipairs(KAWAII_FIELDS) do
            local base = record.kawaii[field]
            local scale = scales[field]
            if type(base) == "number" and type(scale) == "number" then
                local want = base * scale
                Try(function() settings[field] = want end)

                -- Read back through a FRESH struct fetch, not through the
                -- local. UE4SS may hand back a copy of a nested struct rather
                -- than a reference, in which case writes land on the copy and
                -- vanish. Reading the same local would confirm the write and
                -- prove nothing, which is exactly the trap that made a scene
                -- with failed physics report success.
                local fresh = Try(function() return node.PhysicsSettings end)
                local got = fresh and Try(function() return fresh[field] end)
                if type(got) == "number" and math.abs(got - want) < 0.0001 then
                    written = written + 1
                else
                    Physics.lastMiss = string.format(
                        "%s: wrote %.4f, read back %s", field, want, tostring(got))
                end
            elseif type(base) == "number" then
                Try(function() settings[field] = base end)   -- unscaled: reset
            end
        end
    end

    for prop, fields in pairs(record.springs) do
        local spring = Try(function() return instance[prop] end)
        if spring ~= nil then
            for _, field in ipairs(SPRING_FIELDS) do
                local base = fields[field]
                local scale = scales[field]
                if type(base) == "number" and type(scale) == "number" then
                    Try(function() spring[field] = base * scale end)
                    written = written + 1
                elseif type(base) == "number" then
                    Try(function() spring[field] = base end)
                end
            end
        end
    end

    return true, written
end

function Physics.Restore(instance)
    local record = originals[instance]
    if not record or not IsLive(instance) then return false end

    local node, settings = KawaiiSettings(instance)
    if settings ~= nil then
        for field, value in pairs(record.kawaii) do
            if type(value) == "number" then
                Try(function() settings[field] = value end)
            end
        end
        if record.updateFlag ~= nil then
            Try(function() node.bUpdatePhysicsSettingsInGame = record.updateFlag end)
        end
    end

    for prop, fields in pairs(record.springs) do
        local spring = Try(function() return instance[prop] end)
        if spring ~= nil then
            for field, value in pairs(fields) do
                if type(value) == "number" then
                    Try(function() spring[field] = value end)
                end
            end
        end
    end

    originals[instance] = nil
    return true
end

function Physics.RestoreAll()
    local count = 0
    for instance in pairs(originals) do
        if IsLive(instance) and Physics.Restore(instance) then count = count + 1 end
    end
    return count
end

-- ---------------------------------------------------------------- intensity

--[[
    DYNAMIC RESPONSE, DRIVEN BY THE SCENE

    A fixed preset is the wrong model. Real soft tissue is a mass-spring-damper,
    and the literature on breast biomechanics models it exactly that way (3D
    dynamic FE models, piecewise mass-spring-damper). Two consequences matter
    here, and they point in different directions to the obvious guess:

    1. NATURAL FREQUENCY IS A TISSUE PROPERTY.
       It comes from mass and stiffness, and it does not change because the
       motion driving it got harder. So Stiffness should stay close to constant
       across intensity levels. Swinging it would make the same body appear to
       change material, which reads as wrong even when nobody can say why.

    2. AMPLITUDE FOLLOWS DRIVING ACCELERATION.
       A harder, faster motion produces a larger response on its own. This is
       already true in KawaiiPhysics: its own documentation says that as Damping
       gets smaller, "acceleration is more reflected in the physical behaviour".

    So the escalation the scene needs mostly happens FOR FREE, provided the
    animation actually carries more acceleration at higher intensity. What has
    to move with intensity is the CEILING, not the spring:

        MaxDisplacement   a hard clamp on travel. Left low, a harder motion
                          produces the same capped result and the escalation is
                          invisible.
        LimitAngle        the rotational equivalent.
        Damping           eased down a little, so more of the extra
                          acceleration shows through rather than being absorbed.

    Stiffness is deliberately barely touched.

    This is why the framework couples physics to the scene's intensity axis
    rather than offering a preset dropdown.
--]]

--- Scale factors at the two ends of the intensity axis. Interpolated, never
--- switched, so moving up a level is a ramp rather than a jolt.
Physics.INTENSITY_LOW = {
    Stiffness       = 1.05,   -- a touch firmer when things are calm
    Damping         = 1.15,   -- settles sooner
    MaxDisplacement = 0.85,
    LimitAngle      = 0.90,
}

Physics.INTENSITY_HIGH = {
    Stiffness       = 0.95,   -- near-constant: natural frequency is a property
    Damping         = 0.65,   -- let acceleration through
    MaxDisplacement = 1.75,   -- lift the ceiling so escalation is visible
    LimitAngle      = 1.35,
    SpringDamping   = 0.70,
    SpringStiffness = 0.90,
}

local function Lerp(a, b, t) return a + (b - a) * t end

--- Set the response for a normalised intensity, 0 = gentlest, 1 = hardest.
---
--- Call this whenever the scene's intensity level changes. It scales from the
--- captured shipped values, so repeated calls do not compound.
function Physics.SetIntensity(instance, t)
    if not IsLive(instance) then return false, "anim instance is gone" end
    t = math.max(0.0, math.min(1.0, tonumber(t) or 0.0))

    local blended = {}
    local low, high = Physics.INTENSITY_LOW, Physics.INTENSITY_HIGH

    -- Any field named at either end participates; a field missing from one end
    -- is treated as 1.0 there, meaning "unscaled".
    local fields = {}
    for field in pairs(low)  do fields[field] = true end
    for field in pairs(high) do fields[field] = true end

    for field in pairs(fields) do
        blended[field] = Lerp(low[field] or 1.0, high[field] or 1.0, t)
    end

    return Physics.Apply(instance, blended)
end

--- Convenience for the scene engine: level 1..count mapped onto 0..1.
--- A single-level stage sits at the gentle end rather than dividing by zero.
function Physics.SetIntensityLevel(instance, level, count)
    if type(count) ~= "number" or count < 2 then
        return Physics.SetIntensity(instance, 0.0)
    end
    return Physics.SetIntensity(instance, (level - 1) / (count - 1))
end

-- --------------------------------------------------------- chains by side

--[[
    ASYMMETRY

    Secondary motion is not uniform across a body. A chain that is constrained,
    supported or in contact behaves differently from one hanging free, and
    applying one global setting to all 27 chains flattens that away.

    Each FAnimNode_SpringBone names the bone it drives:

        FBoneReference SpringBone     -> BoneName

    Eve's skeleton uses Bip001-L-* and Bip001-R-* naming (confirmed at runtime:
    the hand reads as "Bip001-R-Hand"), so left and right chains are separately
    addressable, as is anything matched by name.
--]]

--- Which bone each spring chain drives. Cached per instance.
local chainBones = setmetatable({}, { __mode = "k" })

function Physics.MapChains(instance)
    if not IsLive(instance) then return {} end
    local cached = chainBones[instance]
    if cached then return cached end

    local map = {}
    for _, prop in ipairs(Physics.SPRING_NODES) do
        local node = Try(function() return instance[prop] end)
        if node ~= nil then
            local reference = Try(function() return node.SpringBone end)
            local name = reference and Try(function()
                return reference.BoneName:ToString() end)
            map[#map + 1] = { property = prop, bone = name or "?" }
        end
    end

    chainBones[instance] = map
    return map
end

--- "L", "R" or nil, from the bone name.
function Physics.SideOf(boneName)
    if type(boneName) ~= "string" then return nil end
    if boneName:find("-L-", 1, true) or boneName:find("_L_", 1, true) then return "L" end
    if boneName:find("-R-", 1, true) or boneName:find("_R_", 1, true) then return "R" end
    return nil
end

--- Apply scale factors to only those chains whose bone name matches.
---
--- `match` is either a side ("L" / "R") or a Lua pattern tested against the
--- bone name. Scales are relative to the captured shipped values, as everywhere
--- else, so this composes with the intensity ramp rather than fighting it.
---
--- The use for this is a chain that is being held or supported: raise its
--- stiffness and damping so it moves less, while its opposite number keeps
--- swinging freely. That asymmetry is most of what makes contact read as
--- contact rather than as two things happening near each other.
function Physics.ApplyToChains(instance, match, scales)
    if not IsLive(instance) then return false, "anim instance is gone" end
    if type(scales) ~= "table" then return false, "scales must be a table" end

    local record = Capture(instance)
    local touched = 0

    for _, entry in ipairs(Physics.MapChains(instance)) do
        local hit
        if match == "L" or match == "R" then
            hit = Physics.SideOf(entry.bone) == match
        else
            hit = entry.bone:find(match) ~= nil
        end

        if hit then
            local node = Try(function() return instance[entry.property] end)
            local base = record.springs[entry.property]
            if node ~= nil and base then
                for _, field in ipairs(SPRING_FIELDS) do
                    local original, scale = base[field], scales[field]
                    if type(original) == "number" and type(scale) == "number" then
                        Try(function() node[field] = original * scale end)
                        touched = touched + 1
                    end
                end
            end
        end
    end

    return true, touched
end

-- ------------------------------------------------------------------ report

--- Current values, for a UI or a log. Reports what is actually on the node, so
--- it doubles as verification that a write took.
function Physics.Describe(instance)
    if not IsLive(instance) then return "no anim instance" end
    local lines = {}

    local node, settings = KawaiiSettings(instance)
    if settings == nil then
        lines[#lines + 1] = "  KawaiiPhysics: not present"
    else
        lines[#lines + 1] = string.format("  KawaiiPhysics (liveUpdate=%s)",
            tostring(Try(function() return node.bUpdatePhysicsSettingsInGame end)))
        for _, field in ipairs(KAWAII_FIELDS) do
            lines[#lines + 1] = string.format("    %-22s %s", field,
                tostring(Try(function() return settings[field] end)))
        end
    end

    local springs = 0
    for _, prop in ipairs(Physics.SPRING_NODES) do
        if Try(function() return instance[prop] end) ~= nil then
            springs = springs + 1
        end
    end
    lines[#lines + 1] = string.format("  SpringBone chains present: %d", springs)

    return table.concat(lines, "\n")
end

return Physics
