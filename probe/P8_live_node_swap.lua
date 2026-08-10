--[[
    SBLoveFramework -- live node swap (P8)
    ------------------------------------------------------------------
    WHAT P7 PROVED (both verified by reading the value back)

      - TArray growth WORKS:  node.PlaySequences[1] = anim   grew 0 -> 1
      - Pointer write WORKS:  node.Sequence = anim           read back as anim

    So the anim graph is writable from Lua. The problem is not capability.

    WHY INJECTING INTO CustomAnimNode STILL DID NOTHING

    The node is gated by CustomAnimAlpha, and that alpha is not ours to set.
    The anim blueprint's event graph assigns it every frame from the character:

        CustomAnimAlpha = GetCurrentCustomAnimAlpha(0)

    and the character-side state behind that getter is native C++ with no
    UProperty, so it cannot be written. The order each frame is:

        1. event graph sets CustomAnimAlpha = 0
        2. graph evaluates, sees 0, ignores CustomAnimNode
        3. our timer writes 1.0        <-- too late, every time
        4. repeat

    P6 read the alpha back as 1.0 and I took that as success. It was only 1.0
    between our write and the next update. At evaluation it was always 0.
    Winning that race needs a hook on BlueprintUpdateAnimation, and hooks switch
    on UE4SS's global ProcessInternal interception, measured at 1-3 fps last
    project. Not acceptable.

    THE APPROACH THAT USES ONLY PROVEN CAPABILITIES

    Stop trying to wake a dormant node. Instead find the node the graph is
    ALREADY playing and swap its sequence out from under it. A pointer write is
    all that needs, and pointer writes are proven.

    FAnimNode_AssetPlayerBase gives the detector for free:

        float BlendWeight              > 0 means the graph is using this node
        float InternalTimeAccumulator  advances only if it is actually playing

    Two samples of the accumulator separate "weighted" from "genuinely running",
    which matters because a node can be blended in at weight 0 and frozen.

    STAGES
      1  scan all 86 asset-player nodes, twice, and report the live ones
      2  swap Sequence on the highest-weight live node
      3  measure bone travel against an idle baseline
      4  restore the original sequence

    This also produces, as a side effect, a map of which node drives Eve's idle,
    which the framework needs regardless of how playback ends up working.

    SAFETY
    No single-node mode (that crashed the game in P4). One pointer write, read
    back, restored. If the swap looks wrong on screen it lasts about 2 seconds.

    WHAT TO DO
      Load a save. Stand still. Wait ~30 seconds. Quit.
--]]

local ModName    = "SBLoveP8"
local OutputFile = "ue4ss/SBLoveFramework_probe.txt"

local TEST_ANIM =
    "/Game/Art/Character/NPC/CH_NPC_TachyNPC/Animation/" ..
    "P_Eve_Tachy_Battle_Jog.P_Eve_Tachy_Battle_Jog"

local SAMPLES = 4

--- Every asset-player node on CH_P_EVE_01_AnimBP_New_C, from the generated
--- header. These are the only node types that carry a playable sequence.
local NODES = {
    "AnimGraphNode_SequencePlayer_33",
    "AnimGraphNode_RandomPlayer",
    "AnimGraphNode_SequencePlayer_32",
    "AnimGraphNode_SequencePlayer_31",
    "AnimGraphNode_SequencePlayer_30",
    "AnimGraphNode_SequencePlayer_29",
    "SBAnimGraphNode_SequenceBlendedPlayer_8",
    "SBAnimGraphNode_BlendSpacePlayer_16",
    "AnimGraphNode_SequencePlayer_28",
    "SBAnimGraphNode_BlendSpacePlayer_15",
    "SBAnimGraphNode_BlendSpacePlayer_14",
    "SBAnimGraphNode_SequenceBlendedPlayer_7",
    "AnimGraphNode_SequencePlayer_27",
    "AnimGraphNode_SequencePlayer_26",
    "SBAnimGraphNode_SequenceBlendedPlayer_6",
    "SBAnimGraphNode_CustomBlendSpacePlayer",
    "AnimGraphNode_SequencePlayer_25",
    "AnimGraphNode_SequencePlayer_24",
    "AnimGraphNode_SequencePlayer_23",
    "AnimGraphNode_SequencePlayer_22",
    "SBAnimGraphNode_SequenceBlendedPlayer_5",
    "SBAnimGraphNode_SequenceBlendedPlayer_4",
    "SBAnimGraphNode_SequenceBlendedPlayer_3",
    "SBAnimGraphNode_BlendSpacePlayer_13",
    "AnimGraphNode_SequencePlayer_21",
    "AnimGraphNode_SequencePlayer_20",
    "AnimGraphNode_SequencePlayer_19",
    "AnimGraphNode_SequencePlayer_18",
    "SBAnimGraphNode_BlendSpacePlayer_12",
    "AnimGraphNode_SequencePlayer_17",
    "AnimGraphNode_SequencePlayer_16",
    "SBAnimGraphNode_BlendSpacePlayer_11",
    "AnimGraphNode_SequencePlayer_15",
    "AnimGraphNode_SequencePlayer_14",
    "AnimGraphNode_SequencePlayer_13",
    "AnimGraphNode_SequencePlayer_12",
    "AnimGraphNode_SequencePlayer_11",
    "AnimGraphNode_SequencePlayer_10",
    "AnimGraphNode_SequencePlayer_9",
    "AnimGraphNode_SequencePlayer_8",
    "SBAnimGraphNode_BlendSpacePlayer_10",
    "SBAnimGraphNode_BlendSpacePlayer_9",
    "AnimGraphNode_BlendSpacePlayer_15",
    "AnimGraphNode_BlendSpacePlayer_14",
    "AnimGraphNode_BlendSpacePlayer_13",
    "AnimGraphNode_SequencePlayer_7",
    "AnimGraphNode_SequencePlayer_6",
    "AnimGraphNode_BlendSpacePlayer_12",
    "AnimGraphNode_BlendSpacePlayer_11",
    "AnimGraphNode_BlendSpacePlayer_10",
    "AnimGraphNode_SequencePlayer_5",
    "AnimGraphNode_SequencePlayer_4",
    "AnimGraphNode_BlendSpacePlayer_9",
    "AnimGraphNode_BlendSpacePlayer_8",
    "AnimGraphNode_BlendSpacePlayer_7",
    "AnimGraphNode_BlendSpacePlayer_6",
    "AnimGraphNode_BlendSpacePlayer_5",
    "SBAnimGraphNode_BlendSpacePlayer_8",
    "SBAnimGraphNode_BlendSpacePlayer_7",
    "SBAnimGraphNode_BlendSpacePlayer_6",
    "AnimGraphNode_SequencePlayer_3",
    "AnimGraphNode_SequencePlayer_2",
    "SBAnimGraphNode_SBSequencePlayer_1",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_4",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_3",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_2",
    "SBAnimGraphNode_BlendSpacePlayer_5",
    "SBAnimGraphNode_BlendSpacePlayer_4",
    "SBAnimGraphNode_BlendSpacePlayer_3",
    "AnimGraphNode_SequencePlayer_1",
    "SBAnimGraphNode_SBSequencePlayer",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer_1",
    "SBAnimGraphNode_OverriddenBlendSpacePlayer",
    "AnimGraphNode_BlendSpacePlayer_4",
    "SBAnimGraphNode_BlendSpacePlayer_2",
    "SBAnimGraphNode_BlendSpacePlayer_1",
    "AnimGraphNode_BlendSpacePlayer_3",
    "AnimGraphNode_BlendSpacePlayer_2",
    "AnimGraphNode_BlendSpacePlayer_1",
    "AnimGraphNode_BlendSpacePlayer",
    "SBAnimGraphNode_SBMotionPlayer",
    "SBAnimGraphNode_BlendSpacePlayer",
    "AnimGraphNode_SequencePlayer",
    "SBAnimGraphNode_SequenceBlendedPlayer_2",
    "SBAnimGraphNode_SequenceBlendedPlayer_1",
    "SBAnimGraphNode_SequenceBlendedPlayer",}

-- ------------------------------------------------------------------- output

local Handle = nil

local function Out(text)
    print(string.format("[%s] %s\n", ModName, text))
    if not Handle then
        local ok, handle = pcall(io.open, OutputFile, "w")
        if ok then Handle = handle end
    end
    if Handle then Handle:write(text, "\n") Handle:flush() end
end

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function IsLive(object)
    if not object then return false end
    return Try(function() return object:IsValid() end) == true
end

local function NameOf(object)
    return Try(function() return object:GetFullName() end) or "<unnamed>"
end

local function ShortName(object)
    local full = NameOf(object)
    return full:match("([^%.]+)$") or full
end

-- ----------------------------------------------------------------- helpers

local function GetPlayerPawn()
    local controller = Try(FindFirstOf, "SBPlayerController")
    if not IsLive(controller) then return nil end
    local pawn = Try(function() return controller.Pawn end)
    if not IsLive(pawn) then
        pawn = Try(function() return controller:K2_GetPawn() end)
    end
    return IsLive(pawn) and pawn or nil
end

local function InGameplay()
    local pawn = GetPlayerPawn()
    if not pawn then return nil, "no player pawn yet" end
    local path = NameOf(pawn)
    if path:lower():find("lobby", 1, true) then
        return nil, "in Lobby (main menu), waiting for a loaded save"
    end
    return pawn, path
end

local function VecOf(value)
    if not value then return nil end
    local x = Try(function() return value.X end)
    if not x then return nil end
    return { X = x, Y = Try(function() return value.Y end),
                    Z = Try(function() return value.Z end) }
end

local function Distance(a, b)
    if not a or not b then return 0.0 end
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

-- ------------------------------------------------------------------- state

local Eve, Mesh, Instance, TestBone
local Chosen, ChosenOriginal = nil, nil
local FirstScan = {}

local function RelativeBonePosition()
    if not TestBone then return nil end
    local world = VecOf(Try(function()
        return Mesh:GetSocketLocation(FName(TestBone)) end))
    local origin = VecOf(Try(function() return Eve:K2_GetActorLocation() end))
    if not world or not origin then return nil end
    return { X = world.X - origin.X, Y = world.Y - origin.Y,
             Z = world.Z - origin.Z }
end

local function FreshAnim()
    local anim = Try(StaticFindObject, TEST_ANIM)
    if not IsLive(anim) and type(LoadAsset) == "function" then
        anim = Try(LoadAsset, TEST_ANIM)
    end
    return IsLive(anim) and anim or nil
end

local function Setup()
    Eve = GetPlayerPawn()
    Mesh = IsLive(Eve) and Try(function()
        return Eve:GetSBSkeletalMeshComponent(0) end) or nil
    if not IsLive(Mesh) then Out("  ABORT: no body mesh") return false end
    Instance = Try(function() return Mesh:GetAnimInstance() end)
    if not IsLive(Instance) then Out("  ABORT: no anim instance") return false end
    for _, want in ipairs({ "Bip001-R-Hand", "Bip001_R_Hand", "hand_r" }) do
        if VecOf(Try(function()
            return Mesh:GetSocketLocation(FName(want)) end)) then
            TestBone = want break
        end
    end
    if not TestBone then Out("  ABORT: no usable bone") return false end
    Out("")
    Out("################ SETUP ################")
    Out("  bone  " .. TestBone .. "   nodes to scan: " .. tostring(#NODES))
    return true
end

-- --------------------------------------------------------------- node scan

--- Snapshot BlendWeight and InternalTimeAccumulator for every node.
local function ScanNodes()
    local snapshot = {}
    for _, prop in ipairs(NODES) do
        local node = Try(function() return Instance[prop] end)
        if node ~= nil then
            snapshot[prop] = {
                weight = Try(function() return node.BlendWeight end),
                time   = Try(function() return node.InternalTimeAccumulator end),
                seq    = Try(function() return node.Sequence end),
            }
        end
    end
    return snapshot
end

local function ReportLiveNodes(second)
    Out("")
    Out("################ 1. LIVE NODES ################")
    Out("  property                                  weight   dTime   sequence")

    local best, bestWeight = nil, -1
    local live = 0

    for _, prop in ipairs(NODES) do
        local a, b = FirstScan[prop], second[prop]
        if a and b then
            local weight = b.weight or 0.0
            local delta  = (type(b.time) == "number" and type(a.time) == "number")
                and (b.time - a.time) or 0.0
            local playing = (type(weight) == "number" and weight > 0.001)
                or math.abs(delta) > 0.0001

            if playing then
                live = live + 1
                Out(string.format("  %-40s %6.3f  %+6.3f  %s", prop,
                    type(weight) == "number" and weight or 0.0, delta,
                    IsLive(b.seq) and ShortName(b.seq) or "-"))
                -- Prefer a weighted node that also carries a real sequence,
                -- since only those can be swapped by pointer.
                if type(weight) == "number" and weight > bestWeight
                    and IsLive(b.seq) then
                    best, bestWeight = prop, weight
                end
            end
        end
    end

    if live == 0 then Out("  (none reported weight or advancing time)") end
    Chosen = best
    Out("")
    Out("  chosen for swap: " .. tostring(Chosen) ..
        (Chosen and string.format("  (weight %.3f)", bestWeight) or ""))
    return Chosen ~= nil
end

-- ------------------------------------------------------------- measurement

local Measure = { last = nil, total = 0.0 }

local function BeginMeasure()
    Measure.last, Measure.total = RelativeBonePosition(), 0.0
end

local function StepMeasure()
    local now = RelativeBonePosition()
    if now and Measure.last then
        Measure.total = Measure.total + Distance(now, Measure.last)
    end
    Measure.last = now
end

-- -------------------------------------------------------------- the swap

local function DoSwap()
    Out("")
    Out("################ 2. SWAP ################")
    local anim = FreshAnim()
    if not anim then Out("  ABORT: anim unavailable") return false end

    local node = Try(function() return Instance[Chosen] end)
    if node == nil then Out("  ABORT: node unreadable") return false end

    ChosenOriginal = Try(function() return node.Sequence end)
    Out("  node   " .. Chosen)
    Out("  before " .. (IsLive(ChosenOriginal) and ShortName(ChosenOriginal) or "-"))

    Try(function() node.Sequence = anim end)

    local after = Try(function() return node.Sequence end)
    Out("  after  " .. (IsLive(after) and ShortName(after) or "-"))

    local took = IsLive(after) and NameOf(after) == NameOf(anim)
    Out("  write took: " .. tostring(took))
    return took
end

local function RestoreSwap()
    if not Chosen or not IsLive(ChosenOriginal) then return end
    local node = Try(function() return Instance[Chosen] end)
    if node ~= nil then
        Try(function() node.Sequence = ChosenOriginal end)
        Out("  restored " .. ShortName(ChosenOriginal))
    end
end

-- -------------------------------------------------------------------- driver

local Baseline, Swapped = nil, nil
local Phase, LastWait = 0, nil

local function Tick()
    Phase = Phase + 1

    if Phase == 1 then
        local pawn, why = InGameplay()
        if not pawn then
            if why ~= LastWait then Out("waiting: " .. why) LastWait = why end
            Phase = 0
            return
        end
        Out("")
        Out("SBLoveFramework live node swap P8")
        Out("in gameplay: " .. why)
        return
    end

    if Phase == 2 then if not Setup() then Phase = 900 end return end

    if Phase == 3 then FirstScan = ScanNodes() return end
    if Phase == 4 then
        if not ReportLiveNodes(ScanNodes()) then
            Out("  no swappable live node found")
            Phase = 899
        end
        return
    end

    if Phase == 5 then
        Out("")
        Out("################ BASELINE ################")
        BeginMeasure()
        return
    end
    if Phase >= 6 and Phase < 6 + SAMPLES then StepMeasure() return end
    if Phase == 6 + SAMPLES then
        Baseline = Measure.total
        Out(string.format("  baseline idle  %.1f units", Baseline))
        return
    end

    if Phase == 7 + SAMPLES then
        if not DoSwap() then Phase = 899 else BeginMeasure() end
        return
    end
    if Phase > 7 + SAMPLES and Phase < 7 + SAMPLES * 2 then StepMeasure() return end
    if Phase == 7 + SAMPLES * 2 then
        Swapped = Measure.total
        Out(string.format("  swapped travel %.1f units", Swapped))
        RestoreSwap()
        return
    end

    if Phase == 8 + SAMPLES * 2 then
        Out("")
        Out("################ VERDICT ################")
        Out(string.format("  baseline %.1f   swapped %.1f",
            Baseline or 0.0, Swapped or 0.0))
        if Baseline and Swapped and Swapped > Baseline * 2.0 and Swapped > 5.0 then
            Out("  >> PLAYBACK SOLVED. Swapping the sequence on a live node")
            Out("     drives the skeleton. The framework plays animations by")
            Out("     pointer-swapping whichever node is currently weighted.")
        else
            Out("  >> No movement. The live-node table above is still the key")
            Out("     result: it names which nodes actually drive Eve's idle.")
        end
        Phase = 900
        return
    end

    if Phase == 901 then
        RestoreSwap()
        Out("")
        Out("ALL DONE -- you can quit. Results in " .. OutputFile)
        return
    end
    if Phase > 901 then Phase = 902 end
end

Out("probe P8 loaded, waiting for gameplay")

pcall(LoopAsync, 500, function()
    ExecuteInGameThread(Tick)
    return false
end)
