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

--- Samples taken on earlier ticks, keyed by actor.
---
--- Identifying a live sequence node needs two samples A FRAME APART, to tell a
--- genuinely running node from a weighted but frozen one. Taking both inside
--- one tick, microseconds apart, leaves the time accumulator unmoved and
--- nothing ever looks live. That is why a scene failed to start on Eve during
--- combat, where she has no weighted BlendSpace to fall back on.
---
--- So the host samples on the ticks leading up to the start, and the value from
--- the previous tick is what resolution compares against.
--- Keyed by OBJECT PATH, not by the actor.
---
--- UE4SS hands back a distinct Lua wrapper for the same UObject on every call,
--- so a table keyed by the actor writes under a new key every tick and reads
--- back nothing. That is the same trap that once made NearbyCharacters offer
--- Eve as her own partner, and it silently defeated this sampler too: samples
--- were being stored every tick and none were ever found again.
local priorSamples = {}

--- Call once per tick for any actor a scene might use.
--- Keeps TWO generations, and hands out the older one.
---
--- Storing a single sample is not enough, because this runs earlier in the same
--- tick that starts a scene: the fresh sample overwrites the old one and the
--- comparison ends up being a frame against itself. Every node then reports
--- dT = +0.000 and nothing looks alive, which is exactly what the diagnostics
--- showed: four nodes at weight 1.00 and not one of them counted.
function Scene.PreSample(actor)
    if not IsLive(actor) then return end
    local instance = Playback.GetAnimInstance(actor)
    if not instance then return end

    local key = Actors.FullName(actor)
    local slot = priorSamples[key]
    if not slot then slot = {} priorSamples[key] = slot end

    slot.previous = slot.current
    slot.current  = Playback.Sample(instance)
end

function Scene.ClearSamples() priorSamples = {} end

--- Non-fatal problems from the last apply. A scene can start with playback
--- working and physics failing, and that combination is invisible unless it is
--- recorded: the run that exposed this bug looked entirely successful.
local lastProblems = {}

function Scene.Current() return current end
function Scene.IsActive() return current ~= nil end
function Scene.LastProblems() return lastProblems end

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

--- What an actor's body is currently playing, and how to take it over.
---
--- Two kinds of actor need two different routes, and which one applies is a
--- property of the character rather than a preference:
---
---   BLENDSPACE  Eve drives her body from a locomotion BlendSpace, because she
---               walks, runs and sprints. Every sample in it is replaced.
---
---   SEQUENCE    A standing NPC has no locomotion to blend, so its idle comes
---               straight from a SequencePlayer. There is no BlendSpace with
---               any weight, and looking only for one reports the character as
---               unusable when it is perfectly drivable.
---
--- BlendSpace is tried first because it covers the whole body. The sequence
--- route needs two samples a frame apart to tell a genuinely playing node from
--- a weighted but frozen one, so callers pass the previous sample in.
local function ResolveTarget(actor)
    local instance = Playback.GetAnimInstance(actor)
    if not instance then return nil, "no anim instance" end

    local spaces = Playback.FindLiveBlendSpaces(instance)
    if #spaces > 0 then
        return { instance = instance, kind = "blendspace", node = spaces[1] }
    end

    -- No BlendSpace: fall back to whichever sequence node is actually running,
    -- compared against a sample from an EARLIER TICK.
    local slot = priorSamples[Actors.FullName(actor)]
    local earlier = slot and slot.previous
    local now = Playback.Sample(instance)

    -- Preferred: a node that is both weighted and genuinely advancing.
    if earlier then
        local live = Playback.FindLive(earlier, now, { absoluteOnly = true })
        if #live > 0 then
            return { instance = instance, kind = "sequence",
                     property = live[1].property, node = live[1] }
        end
    end

    -- Fallback: weight alone.
    --
    -- A character can hold a static pose with nodes weighted at 1.00 and no
    -- clock advancing at all, which is what happens in scripted states. The
    -- advancing check exists to avoid choosing a frozen node when a live one is
    -- available; when EVERYTHING is frozen it rejects the very node driving the
    -- pose. Measured in game: four nodes at weight 1.00, every dT exactly
    -- +0.000, and the pose plainly on screen.
    local best, bestWeight = nil, 0.001
    for prop, sample in pairs(now) do
        local weight = type(sample.weight) == "number" and sample.weight or 0.0
        if weight > bestWeight
            and Playback.IsLive(sample.sequence)
            and Playback.IsAbsolute(sample.sequence) then
            best, bestWeight = prop, weight
        end
    end

    if best then
        return { instance = instance, kind = "sequence", property = best,
                 node = { property = best, weight = bestWeight } }
    end

    return nil, "no usable node" ..
        Scene.DescribeNodes(instance, earlier)
end

--- What IS happening on this anim instance, for when resolution fails.
---
--- Guessing at these one at a time has cost several rounds. A failure that
--- names the nodes, their weights and whether their time advanced is worth far
--- more than one that says "nothing was live".
function Scene.DescribeNodes(instance, earlier)
    local now = Playback.Sample(instance)
    local rows, total = {}, 0

    for prop, sample in pairs(now) do
        total = total + 1
        local before = earlier and earlier[prop]
        local delta = (before and type(sample.time) == "number"
            and type(before.time) == "number") and (sample.time - before.time) or 0
        if (sample.weight or 0) > 0.001 or math.abs(delta) > 0.0001 then
            rows[#rows + 1] = { prop = prop, weight = sample.weight or 0,
                                delta = delta,
                                seq = Playback.IsLive(sample.sequence) and
                                      (Playback.FullName(sample.sequence)
                                       :match("([^%.]+)$")) or "-" }
        end
    end

    table.sort(rows, function(a, b) return a.weight > b.weight end)

    local lines = { string.format(" (%d nodes scanned, %d showing activity)",
        total, #rows) }
    for index, row in ipairs(rows) do
        if index > 6 then break end
        lines[#lines + 1] = string.format("\n      %-42s w=%.2f dT=%+.3f %s",
            row.prop, row.weight, row.delta, row.seq)
    end
    return table.concat(lines)
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
            local ok, err
            if slot.target.kind == "blendspace" then
                ok, err = Playback.SwapBlendSpace(slot.target.node.blendSpace, path)
            else
                ok, err = Playback.Swap(slot.target.instance,
                                        slot.target.property, path)
            end
            if ok then applied = applied + 1
            else failures[#failures + 1] = role .. ": " .. tostring(err) end
        end
    end

    if applied == 0 then
        lastProblems = failures
        return false, table.concat(failures, "; ")
    end

    -- Secondary motion rides the same axis as the animation, so the escalation
    -- is felt rather than only seen. Every actor in the scene gets it, since a
    -- partner whose physics stayed static would look inert next to one whose
    -- did not.
    -- NOT wrapped in a silent Try. An earlier version was, and when the
    -- scene-start apply failed the swallowed error was the only thing that
    -- could have said why: levels 2..4 ramped correctly because they arrive
    -- through SetIntensity, while level 1 silently kept the shipped values.
    -- A pcall whose error is discarded is a pcall that hides the bug it exists
    -- to survive, so failures are collected and reported instead.
    if Scene.PHYSICS_FOLLOWS_INTENSITY then
        local count = #stage.loops
        for role, slot in pairs(current.roles) do
            local instance = slot.target and slot.target.instance
            if not instance then
                failures[#failures + 1] = role .. ": no anim instance for physics"
            else
                local ok, err = pcall(Physics.SetIntensityLevel,
                    instance, current.intensity, count)
                if not ok then
                    failures[#failures + 1] = role .. ": physics threw " .. tostring(err)
                elseif err == false then
                    failures[#failures + 1] = role .. ": physics refused"
                end
            end
        end
    end

    lastProblems = failures
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

    -- A sequence node can only be identified from two samples a frame apart,
    -- so an actor with no BlendSpace needs a second look. Sampling here and
    -- retrying immediately is enough, because the samples are taken either side
    -- of the anchor's own resolution.
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
        if slot.target then
            if slot.target.kind == "blendspace" and slot.target.node then
                Try(function()
                    Playback.RestoreBlendSpace(slot.target.node.blendSpace) end)
            elseif slot.target.instance then
                Try(function() Playback.Restore(slot.target.instance) end)
            end
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
