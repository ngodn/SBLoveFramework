--[[
    SBLoveFramework -- scene engine
    ------------------------------------------------------------------
    A scene is a state machine over STAGES, each with an INTENSITY axis. It is
    not a list of animations you pick from.

    WHY THIS SHAPE

    BG3SX models a scene as a dropdown: choose an animation, it plays, choose
    another. That is a pose viewer with extra steps.

    Analysis of 171 clip names across two commercial titles showed a different
    structure: 13 core stages, each with 4 seamless intensity loops plus
    transition clips, across 2 routes, bracketed by act transitions and endings.

        A02  loop_a loop_b loop_c loop_d      escalating, each seamlessly looped
             sub1 .. sub9                     transitions and reactions

    The insight is that a scene has an axis you move ALONG, not a list you pick
    FROM. That is what makes it read as a scene. So the controls here are four
    verbs, not a menu:

        next / previous stage
        intensity up / down
        swap roles
        end scene

    HOW PLAYBACK HAPPENS

    Through playback.lua, which replaces every sample inside the BlendSpace the
    character is actually playing. See docs/09-playback-solved.md. Confirmed in
    game: Eve plays a replacement animation cleanly.

    A BlendSpace is a SHARED asset. Two actors of different types (Eve, Adam,
    Lily) have different anim blueprints and therefore different BlendSpaces, so
    they do not interfere. Two actors of the SAME type would share one, and one
    would overwrite the other; that case is detected and refused rather than
    silently producing two characters doing the same thing.

    RESTORE

    Everything this touches is recorded and put back: BlendSpace samples, actor
    transforms, movement blocking, scale. A scene that ends badly must leave the
    game exactly as it found it, because a shared BlendSpace left edited stays
    broken for the rest of the session.
--]]

local Playback = require("playback")
local Actors   = require("actors")
local Physics  = require("physics")

local Scene = {}

--- Couple secondary motion to the intensity axis.
---
--- Set false to leave the game's shipped physics untouched, for anyone who
--- prefers it or is chasing a bug. See the notes in physics.lua for why this is
--- a ramp driven by intensity rather than a preset the user picks: soft tissue
--- is a mass-spring-damper whose natural frequency is a property of the tissue,
--- so what escalates with intensity is the displacement ceiling, not the
--- spring.
Scene.PHYSICS_FOLLOWS_INTENSITY = true

local Try, IsLive = Actors.Try, Actors.IsLive

-- ------------------------------------------------------------------- state

--- Only one scene at a time. Two concurrent scenes would fight over shared
--- BlendSpace assets and neither could be restored reliably.
local current = nil

function Scene.Current() return current end
function Scene.IsActive() return current ~= nil end

-- -------------------------------------------------------------- definitions

--- A stage definition, as it arrives from a .sblove.json addon:
---
---   {
---     id          = "embrace_standing",
---     displayName = "Embrace",
---     tags        = { "standing", "paired" },
---     alignment   = { forward = 60, right = 0, up = 0, yaw = 180 },
---     loops       = {
---       { A = "/Game/.../embrace_a_0", B = "/Game/.../embrace_b_0" },
---       { A = "/Game/.../embrace_a_1", B = "/Game/.../embrace_b_1" },
---     },
---   }
---
--- alignment is in the ANCHOR's frame, in centimetres, and belongs to the
--- animation rather than being computed. Two clips authored separately never
--- line up from a formula, so whoever authored them records the offset that
--- fits, and the UI lets them nudge it live to find it.
local function ValidateStage(stage, index)
    if type(stage) ~= "table" then
        return false, string.format("stage %d is not a table", index)
    end
    if type(stage.id) ~= "string" then
        return false, string.format("stage %d has no id", index)
    end
    if type(stage.loops) ~= "table" or #stage.loops == 0 then
        return false, string.format("stage '%s' has no loops", stage.id)
    end
    for level, entry in ipairs(stage.loops) do
        if type(entry) ~= "table" or type(entry.A) ~= "string" then
            return false, string.format(
                "stage '%s' loop %d has no A animation", stage.id, level)
        end
    end
    return true
end

function Scene.Validate(definition)
    if type(definition) ~= "table" then return false, "definition is not a table" end
    if type(definition.stages) ~= "table" or #definition.stages == 0 then
        return false, "definition has no stages"
    end
    for index, stage in ipairs(definition.stages) do
        local ok, err = ValidateStage(stage, index)
        if not ok then return false, err end
    end
    return true
end

-- ------------------------------------------------------------------ actors

--- The BlendSpace an actor's body is currently playing, plus the anim instance
--- it belongs to.
local function ResolveTarget(actor)
    local instance = Playback.GetAnimInstance(actor)
    if not instance then return nil, "no anim instance" end

    local spaces = Playback.FindLiveBlendSpaces(instance)
    if #spaces == 0 then
        return nil, "no live blend space (is the character in the world and idle?)"
    end
    return { instance = instance, node = spaces[1] }
end

-- ------------------------------------------------------------------- apply

--- Push the animations for the current stage and intensity onto both actors.
local function ApplyCurrentLoop()
    if not current then return false, "no scene" end

    local stage = current.definition.stages[current.stage]
    local loop  = stage.loops[current.intensity]
    if not loop then return false, "no such intensity" end

    local applied, failures = 0, {}

    for _, role in ipairs({ "A", "B" }) do
        local slot = current.roles[role]
        local path = loop[role]
        if slot and path then
            local ok, err = Playback.SwapBlendSpace(slot.target.node.blendSpace, path)
            if ok then applied = applied + 1
            else failures[#failures + 1] = role .. ": " .. tostring(err) end
        end
    end

    if applied == 0 then
        return false, table.concat(failures, "; ")
    end

    -- Secondary motion rides the same axis as the animation, so the escalation
    -- is felt rather than only seen. Every actor in the scene gets it, since a
    -- partner whose physics stayed static would look inert next to one whose
    -- did not.
    if Scene.PHYSICS_FOLLOWS_INTENSITY then
        local count = #stage.loops
        for _, slot in pairs(current.roles) do
            Try(function()
                Physics.SetIntensityLevel(slot.target.instance,
                    current.intensity, count)
            end)
        end
    end

    return true, applied, failures
end

--- Place the partner relative to the anchor for the current stage.
local function ApplyAlignment()
    if not current then return end
    local stage = current.definition.stages[current.stage]
    local a = current.roles.A
    local b = current.roles.B
    if not a or not b then return end

    local alignment = stage.alignment or {}
    Actors.Align(a.actor, b.actor, alignment, alignment.yaw)
end

-- ------------------------------------------------------------------- start

--- Begin a scene.
---
--- actorA is the anchor: it stays where it is and the partner is placed
--- relative to it.
function Scene.Start(definition, actorA, actorB)
    if current then return false, "a scene is already running" end

    local ok, err = Scene.Validate(definition)
    if not ok then return false, err end
    if not IsLive(actorA) then return false, "anchor actor is not valid" end

    -- Two actors of the same type share one BlendSpace asset, so one swap would
    -- drive both and neither could be restored independently. Refuse rather
    -- than produce a confusing result.
    if IsLive(actorB) then
        local classA = Try(function() return actorA:GetClass():GetFName():ToString() end)
        local classB = Try(function() return actorB:GetClass():GetFName():ToString() end)
        if classA and classB and classA == classB then
            return false, "both actors are " .. classA ..
                " and would share one BlendSpace; pick different characters"
        end
    end

    local targetA, errA = ResolveTarget(actorA)
    if not targetA then return false, "anchor: " .. tostring(errA) end

    local roles = { A = { actor = actorA, target = targetA } }

    if IsLive(actorB) then
        local targetB, errB = ResolveTarget(actorB)
        if not targetB then return false, "partner: " .. tostring(errB) end
        roles.B = { actor = actorB, target = targetB }
    end

    current = {
        definition = definition,
        roles      = roles,
        stage      = 1,
        intensity  = 1,
    }

    -- Capture before changing anything, so restore has something to go back to.
    for _, slot in pairs(roles) do
        Actors.Capture(slot.actor)
        Actors.Neutralise(slot.actor)
    end

    ApplyAlignment()

    local applied, appliedErr = ApplyCurrentLoop()
    if not applied then
        Scene.Stop()
        return false, "could not start playback: " .. tostring(appliedErr)
    end

    return true
end

-- ----------------------------------------------------------------- controls

function Scene.StageCount()
    if not current then return 0 end
    return #current.definition.stages
end

function Scene.IntensityCount()
    if not current then return 0 end
    return #current.definition.stages[current.stage].loops
end

--- Move along the intensity axis. Clamped, not wrapped: running the top loop
--- back round to the gentlest one is jarring and never what was wanted.
function Scene.SetIntensity(level)
    if not current then return false, "no scene" end
    local count = Scene.IntensityCount()
    level = math.max(1, math.min(count, level))
    if level == current.intensity then return true end
    current.intensity = level
    return ApplyCurrentLoop()
end

function Scene.IntensityUp()   return Scene.SetIntensity(current and current.intensity + 1 or 1) end
function Scene.IntensityDown() return Scene.SetIntensity(current and current.intensity - 1 or 1) end

--- Change stage. Intensity resets, because a stage's loops are its own and
--- level 4 of one stage has nothing to do with level 4 of another.
function Scene.SetStage(index)
    if not current then return false, "no scene" end
    local count = Scene.StageCount()
    if index < 1 or index > count then return false, "no such stage" end

    current.stage = index
    current.intensity = 1
    ApplyAlignment()
    return ApplyCurrentLoop()
end

function Scene.NextStage()
    if not current then return false, "no scene" end
    local nextIndex = current.stage + 1
    if nextIndex > Scene.StageCount() then nextIndex = 1 end
    return Scene.SetStage(nextIndex)
end

function Scene.PrevStage()
    if not current then return false, "no scene" end
    local prevIndex = current.stage - 1
    if prevIndex < 1 then prevIndex = Scene.StageCount() end
    return Scene.SetStage(prevIndex)
end

--- Exchange which actor is the anchor and which is the partner.
function Scene.SwapRoles()
    if not current then return false, "no scene" end
    if not current.roles.B then return false, "scene has only one actor" end

    current.roles.A, current.roles.B = current.roles.B, current.roles.A
    ApplyAlignment()
    return ApplyCurrentLoop()
end

-- -------------------------------------------------------------------- stop

--- End the scene and put everything back.
---
--- Deliberately tolerant: it runs every restore step even if earlier ones fail,
--- because a half-restored scene leaves a shared BlendSpace edited for the rest
--- of the session and that is far worse than a Lua error.
function Scene.Stop()
    if not current then return false, "no scene" end

    for _, slot in pairs(current.roles) do
        if slot.target and slot.target.node then
            Try(function()
                Playback.RestoreBlendSpace(slot.target.node.blendSpace) end)
        end
        if slot.target and slot.target.instance then
            Try(function() Physics.Restore(slot.target.instance) end)
        end
        Try(function() Actors.Restore(slot.actor) end)
    end

    -- Belt and braces: anything this module missed, the modules themselves undo.
    -- Physics settings live on a live anim instance and a BlendSpace is a shared
    -- asset, so either left edited stays wrong for the rest of the session.
    Try(function() Playback.RestoreEverything() end)
    Try(function() Physics.RestoreAll() end)

    current = nil
    return true
end

--- Describe the scene for a UI or a log.
function Scene.Describe()
    if not current then return "no scene" end
    local stage = current.definition.stages[current.stage]
    local names = {}
    for role, slot in pairs(current.roles) do
        names[#names + 1] = role .. "=" ..
            (Actors.FullName(slot.actor):match("([^%.]+)$") or "?")
    end
    table.sort(names)
    return string.format("%s  stage %d/%d '%s'  intensity %d/%d  [%s]",
        current.definition.id or "scene",
        current.stage, Scene.StageCount(), stage.id,
        current.intensity, Scene.IntensityCount(),
        table.concat(names, " "))
end

--- Called every tick by the host. Ends the scene if an actor disappears, so a
--- level change or a death cannot strand an edited BlendSpace.
function Scene.Tick()
    if not current then return end
    for _, slot in pairs(current.roles) do
        if not IsLive(slot.actor) then
            Scene.Stop()
            return
        end
    end
    if not Actors.InGameplay() then Scene.Stop() end
end

return Scene
