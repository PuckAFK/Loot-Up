--[[
    PuckAFK Hub · Loot Up
    Comprehensive smart autofarm built from the supplied 2026-09-12 place snapshot + runtime remote log.

    Game place inspected: 83622406313819 (Loot Up)
    Shared UI: https://raw.githubusercontent.com/PuckAFK/Puck-Loader/main/ui/PuckUI.lua

    Design goals:
      • Reuse the game's live controllers/data modules instead of duplicating combat math.
      • One coordinated movement/combat planner so world farm, quests, dungeons and tower do not fight.
      • Progression-aware world/zone selection, stat spending, equipment, forge, enchants, runes, skills, pets and trees.
      • Server-rate-friendly batching / throttling.
      • Never auto-purchase Robux/premium products. Awakening is opt-in because it resets progression.
      • PuckUI built-in Settings + Configs support and clean unload/re-execute behavior.
]]

local compiler = loadstring or load
if type(compiler) ~= "function" then
    return warn("[PuckAFK Loot Up] loadstring/load unavailable")
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer
local ENV = (getgenv and getgenv()) or _G

if ENV.__PUCKAFK_LOOTUP_UNLOAD then
    pcall(ENV.__PUCKAFK_LOOTUP_UNLOAD)
end

local VERSION = "1.5.1"
local SCRIPT_KEY = "__PUCKAFK_LOOTUP_RUNTIME"

local Runtime = {
    Alive = true,
    Connections = {},
    OriginalCollision = setmetatable({}, {__mode = "k"}),
    Last = {},
    Target = nil,
    TargetName = "None",
    Activity = "World",
    DungeonSession = nil,
    DungeonConfig = nil,
    TowerSession = nil,
    TowerPadState = nil,
    LiveEventActive = false,
    LiveEventAvailable = false,
    LiveEventSessionId = nil,
    LiveEventJoiningUntil = 0,
    PotentialOffer = nil,
    PotentialLastOpen = 0,
    PotentialLastChoice = 0,
    PotentialLastUpgrade = 0,
    NpcStatesLoadedAt = -math.huge,
    NpcStatesPrimed = false,
    NpcStateRefreshInFlight = false,
    LastNpcStateChange = 0,
    CurrentNpcQuest = nil,
    CurrentQuestEnemy = nil,
    BestNpcQuest = nil,
    BestNpcQuestScore = nil,
    BestNpcQuestGiver = nil,
    BestFarmEnemy = nil,
    BestFarmEnemyWorld = nil,
    BestFarmEnemyLevel = nil,
    PendingNpcQuest = nil,
    PendingNpcQuestUntil = 0,
    QuestReplaceFrom = nil,
    QuestReplaceTo = nil,
    QuestReplaceStartedAt = 0,
    QuestReplaceCooldownUntil = 0,
    QuestAcquiring = false,
    QuestAcquireUntil = 0,
    LastQuestAcceptId = nil,
    LastQuestAcceptAt = 0,
    EnemyKillStats = {},
    EnemyDeathStats = {},
    RecentCombatDeaths = {},
    TargetStartedAt = setmetatable({}, {__mode = "k"}),
    LastError = "None",
    RotationChoice = "Dungeons",
    CachedPads = {},
    LastPlannedWorld = nil,
    LastPlannedZone = nil,
    PositionTarget = nil,
    CurrentHoverHeight = nil,
    TargetBodyHeight = nil,
    TargetBodyWidth = nil,
    DownFacingActive = false,
    DownFacingTarget = nil,
    DownFacingHumanoid = nil,
    DownFacingOriginalAutoRotate = true,
    DownFacingHasOriginalAutoRotate = false,
    AutoSwingState = nil,
    RaceRerollPending = false,
    RaceRerollPendingUntil = 0,
    LastRaceResult = nil,
    LastRaceResultAt = 0,
    NextSkillSlot = 1,
    GoldMerchantStock = nil,
    GoldMerchantStockAt = 0,
    TokenPrices = nil,
    TokenPricesAt = 0,
    LastTokenPurchase = nil,
    TutorialSkipSentAt = 0,
    DungeonSmartDifficulty = "Normal",
    DungeonDifficultyStats = {},
    DungeonLastDifficulty = nil,
    DungeonSmartTested = {},
    DungeonRunStartedAt = 0,
    DungeonRunDifficulty = nil,
    DungeonRunGamemode = nil,
    DungeonRunRewarded = false,
    DungeonSurvivalWave = 0,
    DungeonLastReward = nil,
    TowerFloor = 0,
    TowerUpgradeStacks = {},
    TowerLastUpgrade = nil,
    EventChestPending = false,
    EventChestPendingUntil = 0,
    PlayerBankState = nil,
    PlayerBankCapacity = 750,
    PlayerBankLastRefresh = 0,
    PlayerBankLastDeposit = 0,
    PlayerBankLastWithdraw = 0,
    PerformanceModeApplied = false,
    ChestSweepUntil = 0,
    ChestAttempted = setmetatable({}, {__mode = "k"}),
    ChestLastReset = 0,
    -- v1.4.2: movement/travel ownership. Intentional world travel temporarily
    -- pauses combat so the per-frame enemy position lock cannot snap us back.
    TravelUntil = 0,
    TravelWorld = nil,
    TravelZone = nil,
    TravelReason = nil,
    LastTravelAt = 0,
    LastTravelWorld = nil,
    LastTravelZone = nil,
    DungeonSmartGamemode = "3Worlds",
    Window = nil,
}
ENV[SCRIPT_KEY] = Runtime
Runtime.VirtualUser = game:GetService("VirtualUser")

local function now()
    return os.clock()
end

local function safe(fn, ...)
    local packed = table.pack(pcall(fn, ...))
    if packed[1] then
        return table.unpack(packed, 2, packed.n)
    end
    Runtime.LastError = tostring(packed[2])
    return nil
end

local function connect(signal, fn)
    local c = signal:Connect(fn)
    Runtime.Connections[#Runtime.Connections + 1] = c
    return c
end

local function throttle(key, delay)
    local t = now()
    local old = Runtime.Last[key] or 0
    if t - old < delay then
        return false
    end
    Runtime.Last[key] = t
    return true
end

local function waitFor(parent, name, timeout)
    return parent:WaitForChild(name, timeout or 15)
end

-- Load exact current shared PuckUI.
local okUISource, uiSource = pcall(function()
    return game:HttpGet("https://raw.githubusercontent.com/PuckAFK/Puck-Loader/main/ui/PuckUI.lua")
end)
if not okUISource or type(uiSource) ~= "string" or #uiSource < 100 then
    return warn("[PuckAFK Loot Up] failed to download PuckUI")
end

local uiChunk, uiCompileError = compiler(uiSource)
if not uiChunk then
    return warn("[PuckAFK Loot Up] PuckUI compile failed: " .. tostring(uiCompileError))
end
local okUI, PuckUI = pcall(uiChunk)
if not okUI or type(PuckUI) ~= "table" or type(PuckUI.CreateWindow) ~= "function" then
    return warn("[PuckAFK Loot Up] invalid PuckUI")
end

-- Game controller/data bootstrap. Do not call Boot() again: we reuse the live singleton graph.
local Client = waitFor(ReplicatedFirst, "Client")
local Core = Client and waitFor(Client, "Core")
local BootstrapModule = Core and waitFor(Core, "Bootstrap")
if not BootstrapModule then
    return warn("[PuckAFK Loot Up] bootstrap not found")
end

local Bootstrap = require(BootstrapModule)
local bootDeadline = now() + 20
while Runtime.Alive and type(Bootstrap.Controllers) ~= "table" and now() < bootDeadline do
    task.wait(0.1)
end
if type(Bootstrap.Controllers) ~= "table" then
    return warn("[PuckAFK Loot Up] live controllers were not ready")
end

local Controllers = Bootstrap.Controllers

local Shared = waitFor(ReplicatedStorage, "Shared")
local DataFolder = Shared and waitFor(Shared, "Data")
local CoreFolder = Shared and waitFor(Shared, "Core")
if not Shared or not DataFolder or not CoreFolder then
    return warn("[PuckAFK Loot Up] shared data missing")
end

local Net = require(waitFor(CoreFolder, "Net"))
local function dataModule(name)
    local m = DataFolder:FindFirstChild(name)
    return m and require(m) or nil
end

local D = {
    Enemies = dataModule("Enemies") or {},
    Worlds = dataModule("Worlds") or {},
    Items = dataModule("Items") or {},
    Leveling = dataModule("Leveling") or {},
    QuestDefs = dataModule("Quests") or {},
    SkillDefs = dataModule("Skills") or {},
    SkillEvolutions = dataModule("SkillEvolutions") or {},
    SkillTree = dataModule("SkillTree") or {},
    PotentialTree = dataModule("PotentialTree") or {},
    ForgeData = dataModule("Forge") or {},
    MagicForgeData = dataModule("MagicForge") or {},
    ExpertForgeData = dataModule("ExpertForge") or {},
    EnchantData = dataModule("Enchant") or {},
    RunesData = dataModule("Runes") or {},
    DungeonShopData = dataModule("DungeonShop") or {},
    GoldMerchantData = dataModule("GoldMerchant") or {},
    ItemVariants = dataModule("ItemVariants") or {},
    LootPool = dataModule("LootPool") or {},
    PlaytimeRewards = dataModule("PlaytimeRewards") or {},
    NPCQuestDialog = dataModule("NPCQuestDialog") or {},
    PetsData = dataModule("Pets") or {},
    AwakeningData = dataModule("Awakening") or {},
    RacesData = dataModule("Races") or {},
    SeasonPassData = dataModule("SeasonPass") or {},
    CodesData = dataModule("Codes") or {},
    DungeonsData = dataModule("Dungeons") or {},
    InfiniteTowerData = dataModule("InfiniteTower") or {},
    Gamepasses = dataModule("Gamepasses") or {},
    ShopTokenProducts = dataModule("ShopTokenProducts") or {},
    GamepassBenefits = dataModule("GamepassBenefits") or {},
    InventoryCapacity = dataModule("InventoryCapacity") or {},
    LimitedScaling = dataModule("LimitedScaling") or {},
    SpinWheelData = dataModule("SpinWheel") or {},
    ChristmasEvent = dataModule("ChristmasEvent") or {},
    EasterEvent = dataModule("EasterEvent") or {},
}

local Events = {}
local function event(name)
    if Events[name] == nil then
        Events[name] = Net:GetEvent(name) or false
    end
    return Events[name] ~= false and Events[name] or nil
end

local Funcs = {}
local function func(name)
    if Funcs[name] == nil then
        Funcs[name] = Net:GetFunc(name) or false
    end
    return Funcs[name] ~= false and Funcs[name] or nil
end

local RemotesFolder = Shared:FindFirstChild("Remotes")
local NPCQuestFolder = RemotesFolder and RemotesFolder:FindFirstChild("NPCQuest")
local NPCQuestAccept = NPCQuestFolder and NPCQuestFolder:FindFirstChild("Accept")

local E = {
    Inventory = event("Inventory"),
    StatChange = event("StatChange"),
    Quest = event("Quest"),
    LootDrop = event("LootDrop"),
    SkillRoll = event("SkillRoll"),
    SkillEvolution = event("SkillEvolution"),
    SkillTree = event("SkillTree"),
    Forge = event("Forge"),
    MagicForge = event("MagicForge"),
    ExpertForge = event("ExpertForge"),
    Enchant = event("Enchant"),
    EnchantArmor = event("EnchantArmor"),
    RuneRoll = event("RuneRoll"),
    DungeonShop = event("DungeonShop"),
    GoldMerchant = event("GoldMerchant"),
    Pet = event("Pet"),
    Reward = event("Reward"),
    TeleportZone = event("TeleportZone"),
    UnlockWorld = event("UnlockWorld"),
    SpinWheel = event("SpinWheel"),
    SeasonSpin = event("SeasonSpin"),
    SeasonPass = event("SeasonPass"),
    DungeonPad = event("DungeonPad"),
    DungeonSession = event("DungeonSession"),
    InfiniteTowerPad = event("InfiniteTowerPad"),
    InfiniteTowerSession = event("InfiniteTowerSession"),
    Awakening = event("Awakening"),
    Potion = event("Potion"),
    LiveEvent = event("LiveEvent"),
    Tutorial = event("Tutorial"),
    Market = event("Market"),
}

local function getData(key)
    if not Controllers.Replication or type(Controllers.Replication.GetKey) ~= "function" then
        return nil
    end
    return Controllers.Replication:GetKey("Data", key)
end

local function numData(key)
    return tonumber(getData(key)) or 0
end

local function tableData(key)
    local v = getData(key)
    return type(v) == "table" and v or {}
end

local function getCharacter()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not humanoid or humanoid.Health <= 0 or not root then
        return nil, nil, nil
    end
    return character, humanoid, root
end

local Settings = {
    Master = false,
    ActivityMode = "World Farm",
    FarmStrategy = "Smart",
    QuestPriority = true,
    NPCQuestPriority = true,
    EventBossPriority = true,
    AutoSkills = true,
    DynamicEnemyHeight = true,
    HoverHeight = 6,
    HeightSmoothing = 14,
    BehindDistance = 3,
    PerfectDownFacing = true,
    Noclip = true,
    AntiStuck = true,
    AntiAFK = true,
    AFKPerformanceMode = true,

    AutoLoot = true,
    AutoEquip = true,
    AutoSell = true,
    SellBelow = "Rare",
    KeepSpareBest = 1,
    EmergencyInventoryCleanup = true,
    InventoryCleanupAt = 92,
    AutoBankOverflow = true,
    AutoRetrieveVariantBank = true,
    AutoBankAt = 86,
    AutoForge = true,
    ForgeTarget = 10,
    ForgeProtection = false,
    SmartForgeProtection = true,
    ForgeProtectionBelow = 45,
    ReserveWorldCurrency = true,
    AutoGoldMerchant = true,
    AutoEnchantWeapon = true,
    WeaponEnchantMin = "Epic",
    AutoEnchantArmor = true,
    ArmorEnchantMin = "Epic",
    AutoRunes = true,
    RuneMinRarity = "Epic",
    AutoUsePotions = true,
    PotionStrategy = "Smart",
    AutoBuyPotions = true,
    SoulCrystalReserve = 10000,
    AutoDungeonShopDeals = true,
    AutoDungeonGear = true,
    AutoVariantUpgrade = true,
    VariantMinRarity = "Epic",
    AutoBalanceWorldCurrency = true,

    AutoWorlds = true,
    AutoStats = true,
    StatBuild = "Smart",
    AutoQuests = true,
    AutoChestQuests = true,
    AutoNPCQuests = true,
    NPCQuestMode = "Best Progression",
    QuestMatchBestEnemy = true,
    QuestTravelToGiver = true,
    SmartQuestReplacement = true,
    AdaptiveQuestScoring = true,
    QuestSwitchMinImprovement = 25,
    QuestKeepProgress = 35,
    AutoSkillTree = true,
    AutoPotentialTree = true,
    PotentialBranch = "Farming First",
    AutoPotentialUpgrade = true,
    AutoPotentialReroll = true,
    PotentialRerollMin = "Epic",
    AutoSkillRoll = true,
    SkillMinRarity = "Epic",
    SmartSkillQuality = true,
    SkillQualityAncientReserve = 2,
    AutoSkillEvolve = true,
    AutoPets = true,
    AutoSkipTutorial = true,
    AutoTokenUpgrades = true,
    AutoEventChests = true,
    AutoAwaken = false,
    AutoRaceReroll = false,
    RaceTarget = "Smart Farming (Angel)",

    AutoDaily = true,
    AutoPlaytime = true,
    AutoSeason = true,
    AutoBasicSpin = true,
    AutoPremiumFreeSpin = true,
    AutoSeasonSpin = true,
    AutoCodes = true,
    AutoGroupReward = true,
    AutoClanQuests = true,
    AutoClanRewards = true,
    AutoLiveEvent = true,
    LiveEventPriority = true,

    AdaptiveDungeonPlanning = true,
    DungeonDifficulty = "Smart",
    DungeonGamemode = "Smart",
    DungeonPlayers = 1,
    DungeonFriendsOnly = false,
    TowerUpgrade = "Smart",
    Tower2xIfOwned = true,
}

Runtime.ApplyAFKPerformanceMode = function(enabled)
    local windows = Controllers.UI and Controllers.UI.Windows
    if type(windows) ~= "table" then return false end
    local controller = windows.Settings
    if type(controller) ~= "table" or type(controller.ApplyPerformanceMode) ~= "function" then
        for _, candidate in pairs(windows) do
            if type(candidate) == "table" and type(candidate.ApplyPerformanceMode) == "function" then
                controller = candidate
                break
            end
        end
    end
    if type(controller) ~= "table" or type(controller.ApplyPerformanceMode) ~= "function" then return false end

    if enabled then
        if not Runtime.PerformanceOriginalSettings then
            local gameSettings = tableData("Settings")
            Runtime.PerformanceOriginalSettings = {
                BetterPerformance = gameSettings.BetterPerformance == true,
                HideAllVfx = gameSettings.HideAllVfx == true,
                HideRaceAccessories = gameSettings.HideRaceAccessories == true,
            }
        end
        safe(controller.ApplyPerformanceMode, controller, true)
        Runtime.PerformanceModeApplied = true
        return true
    end

    if Runtime.PerformanceModeApplied then
        local original = Runtime.PerformanceOriginalSettings or {}
        if original.BetterPerformance ~= true then
            safe(controller.ApplyPerformanceMode, controller, false)
        end
        if type(controller._setters) == "table" then
            if type(controller._setters.HideAllVfx) == "function" then
                safe(controller._setters.HideAllVfx, original.HideAllVfx == true)
            end
            if type(controller._setters.HideRaceAccessories) == "function" then
                safe(controller._setters.HideRaceAccessories, original.HideRaceAccessories == true)
            end
        end
        Runtime.PerformanceModeApplied = false
    end
    return true
end

connect(LocalPlayer.Idled, function()
    if not Runtime.Alive or Settings.AntiAFK ~= true then return end
    pcall(function()
        Runtime.VirtualUser:CaptureController()
        local camera = workspace.CurrentCamera
        local cf = camera and camera.CFrame or CFrame.new()
        Runtime.VirtualUser:Button2Down(Vector2.new(0, 0), cf)
        task.wait(0.05)
        Runtime.VirtualUser:Button2Up(Vector2.new(0, 0), cf)
    end)
end)

local equipmentRarityNames = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
    Legendary = 5,
    Mythic = 6,
    Divine = 7,
}

-- Skills, runes and enchants use a separate five-tier scale in Loot Up.
local rollRarityNames = {
    Common = 1,
    Rare = 2,
    Epic = 3,
    Legendary = 4,
    Mythical = 5,
    Mythic = 5, -- v1.0 config migration alias
}

-- Clamp the skill target to rarities that can actually roll in this snapshot.
-- Evolved / Unique skills have weight 0 and are not part of the normal scroll pool.
Runtime.MaxRollableSkillRarity = 1
for _, info in pairs(type(D.SkillDefs.All) == "table" and D.SkillDefs.All or {}) do
    if type(info) == "table" and (tonumber(info.weight) or 0) > 0 then
        Runtime.MaxRollableSkillRarity = math.max(Runtime.MaxRollableSkillRarity, tonumber(info.rarity) or 1)
    end
end
Runtime.SkillRarityOptions = {"Rare", "Epic", "Legendary"}
if Runtime.MaxRollableSkillRarity >= 5 then
    Runtime.SkillRarityOptions[#Runtime.SkillRarityOptions + 1] = "Mythical"
end
if (rollRarityNames[Settings.SkillMinRarity] or 3) > Runtime.MaxRollableSkillRarity then
    Settings.SkillMinRarity = Runtime.MaxRollableSkillRarity >= 5 and "Mythical"
        or Runtime.MaxRollableSkillRarity >= 4 and "Legendary"
        or Runtime.MaxRollableSkillRarity >= 3 and "Epic"
        or "Rare"
end

local function normalizeChoice(v)
    if type(v) == "table" then
        return v[1]
    end
    return v
end

local function isMasterFeatureEnabled(flag)
    return Runtime.Alive and Settings.Master and Settings[flag] == true
end

-- World helpers ----------------------------------------------------------------
local orderedWorlds = {}
for worldId, config in pairs(D.Worlds) do
    local n = type(worldId) == "string" and tonumber(worldId:match("^World(%d+)$")) or nil
    if n and type(config) == "table" then
        orderedWorlds[#orderedWorlds + 1] = {id = worldId, n = n, config = config}
    end
end
table.sort(orderedWorlds, function(a, b) return a.n < b.n end)

local function worldUnlocked(worldId)
    if worldId == "World1" then
        return true
    end
    local unlocked = tableData("Worlds")
    return unlocked[worldId] == true
end

local function requirementsMet(worldInfo)
    if not worldInfo or type(worldInfo.config.requirements) ~= "table" then
        return true
    end
    for key, raw in pairs(worldInfo.config.requirements) do
        local amount = type(raw) == "table" and tonumber(raw[1]) or tonumber(raw)
        if amount and numData(key) < amount then
            return false
        end
    end
    return true
end

local function highestUnlockedWorld()
    local result = orderedWorlds[1]
    for _, info in ipairs(orderedWorlds) do
        if worldUnlocked(info.id) then
            result = info
        end
    end
    return result
end

local function nextLockedWorld()
    for _, info in ipairs(orderedWorlds) do
        if not worldUnlocked(info.id) then
            return info
        end
    end
    return nil
end

local function bestZone(worldInfo, level)
    if not worldInfo or type(worldInfo.config.zones) ~= "table" then
        return 1
    end
    local best = 1
    for i, zone in ipairs(worldInfo.config.zones) do
        local req = tonumber(zone.level) or 1
        if req <= level then
            best = i
        end
    end
    return best
end

local function reserveForNextWorld()
    if not Settings.ReserveWorldCurrency or not Settings.AutoWorlds then
        return 0, 0
    end
    local nextWorld = nextLockedWorld()
    local req = nextWorld and nextWorld.config and nextWorld.config.requirements
    if type(req) ~= "table" then
        return 0, 0
    end
    local gold = req.Gold
    local shards = req.Shards
    return type(gold) == "table" and tonumber(gold[1]) or tonumber(gold) or 0,
        type(shards) == "table" and tonumber(shards[1]) or tonumber(shards) or 0
end

local function requirementAmount(req, key)
    if type(req) ~= "table" then return 0 end
    local raw = req[key]
    return type(raw) == "table" and tonumber(raw[1]) or tonumber(raw) or 0
end

-- Reserve currencies for the next world and, at max awakening, for a requested
-- in-game race reroll.  Merchant purchases must never steal progression gates.
Runtime.GetMajorCurrencyReserve = function()
    local goldReserve, shardReserve = reserveForNextWorld()
    if Settings.AutoRaceReroll then
        local maxAwakening = tonumber(D.AwakeningData.MAX_AWAKENING) or 3
        if math.floor(numData("Awakening")) >= maxAwakening then
            local choice = tostring(Settings.RaceTarget or "Keep Current")
            local target
            if choice ~= "Keep Current" then
                if choice:find("Angel", 1, true) then target = "angel"
                elseif choice:find("Elf", 1, true) then target = "elf"
                elseif choice:find("Wizard", 1, true) then target = "wizard"
                elseif choice:find("Dwarf", 1, true) then target = "dwarf" end
            end
            if target and getData("Race") ~= target then
                local req = type(D.AwakeningData.Reroll) == "table" and D.AwakeningData.Reroll or {}
                goldReserve = math.max(goldReserve, tonumber(req.Gold) or 0)
                shardReserve = math.max(shardReserve, tonumber(req.Shards) or 0)
            end
        end
    end
    return goldReserve, shardReserve
end

Runtime.OwnsPermanentPass = function(id)
    id = tostring(id)
    local bundle = tostring((D.GamepassBenefits and D.GamepassBenefits.AllGamepassesProductId) or "3475764387")
    if Controllers.Replication and type(Controllers.Replication.OwnsPass) == "function" then
        if safe(Controllers.Replication.OwnsPass, Controllers.Replication, id) == true then return true end
        if id ~= bundle and safe(Controllers.Replication.OwnsPass, Controllers.Replication, bundle) == true then return true end
    end
    local owned = tableData("OwnedPasses")
    if owned[id] == true or owned[tonumber(id)] == true then return true end
    return id ~= bundle and (owned[bundle] == true or owned[tonumber(bundle)] == true) or false
end

local function autoBalanceWorldCurrency()
    if not Settings.AutoBalanceWorldCurrency or not E.GoldMerchant then return false end
    local nextWorld = nextLockedWorld()
    local req = nextWorld and nextWorld.config and nextWorld.config.requirements
    if type(req) ~= "table" then return false end

    -- Do not pay the merchant's 10% conversion tax before level is the only
    -- remaining non-currency gate.
    local levelReq = requirementAmount(req, "Level")
    if levelReq > 0 and numData("Level") < levelReq then return false end

    local goldReq = requirementAmount(req, "Gold")
    local shardReq = requirementAmount(req, "Shards")
    if goldReq <= 0 or shardReq <= 0 then return false end

    local gold = numData("Gold")
    local shards = numData("Shards")
    local tax = tonumber(D.GoldMerchantData.ConversionTax) or 0.1
    local efficiency = math.clamp(1 - tax, 0.01, 1)

    if gold >= goldReq and shards < shardReq then
        local surplus = math.floor(gold - goldReq)
        local deficit = shardReq - shards
        local amount = math.min(surplus, math.ceil(deficit / efficiency))
        if amount >= 1 then
            E.GoldMerchant:FireServer("Convert", "GoldToShards", amount)
            return true
        end
    elseif shards >= shardReq and gold < goldReq then
        local surplus = math.floor(shards - shardReq)
        local deficit = goldReq - gold
        local amount = math.min(surplus, math.ceil(deficit / efficiency))
        if amount >= 1 then
            E.GoldMerchant:FireServer("Convert", "ShardsToGold", amount)
            return true
        end
    end
    return false
end

-- Quest helpers ----------------------------------------------------------------
local function questStateFor(id)
    local q = tableData("Quests")
    if type(q[id]) == "table" then return q[id] end
    for _, bucket in pairs(q) do
        if type(bucket) == "table" and type(bucket[id]) == "table" then
            return bucket[id]
        end
    end
    return nil
end

local function questTargetName(def)
    if type(def) ~= "table" then return nil end
    if type(def.enemyName) == "string" and def.enemyName ~= "" then
        return def.enemyName
    end
    if type(def.id) == "string" then
        local name = def.id:match("^slay_(.+)$")
        if name then return name:gsub("_", " ") end
    end
    return nil
end

local function getIncompleteWorldQuestTarget()
    if not Settings.QuestPriority then return nil, nil end
    local list = D.QuestDefs.World
    if type(list) ~= "table" then return nil, nil end
    -- Quests.World is keyed by quest id in the live data module, not an array.
    -- Using ipairs silently skipped every standard quest in earlier builds.
    for _, def in pairs(list) do
        if type(def) == "table" and def.active ~= false then
            local state = questStateFor(def.id)
            if type(state) == "table" and not state.claimed then
            local current = tonumber(state.current or state.Current or state.progress) or 0
            local target = tonumber(def.target) or 0
            local enemyName = questTargetName(def)
                if enemyName and current < target then
                    return enemyName, def.worldId
                end
            end
        end
    end
    return nil, nil
end

local function seasonNeedsMinibossKills()
    if not Settings.AutoSeason then return false end
    local season = tableData("SeasonPass")
    local daily = type(season.Daily) == "table" and season.Daily or {}
    local quests = type(daily.Quests) == "table" and daily.Quests or {}
    local defs = type(D.SeasonPassData.Quests) == "table" and D.SeasonPassData.Quests or {}
    for _, state in pairs(quests) do
        if type(state) == "table" and state.Id == "miniboss_kills" and state.Claimed ~= true then
            local def = defs[state.Id]
            local target = type(def) == "table" and tonumber(def.Target) or nil
            if target and (tonumber(state.Progress) or 0) < target then return true end
        end
    end
    return false
end

local function standardQuestIncomplete(id)
    local def = (type(D.QuestDefs.World) == "table" and D.QuestDefs.World[id])
        or (type(D.QuestDefs.Weekly) == "table" and D.QuestDefs.Weekly[id])
    if type(def) ~= "table" or def.active == false then return false end
    local state = questStateFor(id)
    if type(state) ~= "table" or state.claimed == true then return false end
    local current = tonumber(state.current or state.Current) or 0
    local target = math.max(1, tonumber(def.target) or 1)
    return current < target
end

local function standardQuestCombatStrategy()
    if not Settings.QuestPriority then return nil end
    -- Daily objectives are intentionally checked before the much larger weekly
    -- counters so the short reset window is not wasted. Both still progress from
    -- the same kills whenever their enemy class overlaps.
    if standardQuestIncomplete("daily_defeat_3_mini_bosses") then
        return "MiniBosses"
    end
    if standardQuestIncomplete("defeat_50_mini_boss") then
        return "MiniBosses"
    end
    if standardQuestIncomplete("defeat_25_final_boss") then
        return "Bosses"
    end
    return nil
end

-- Chest discovery quests use the live NormalChest / SpecialChest world models,
-- not the paid Boss Chest. The saved place contains 18 ChestSpots and server-spawned
-- chest models at Workspace level. Touch/prompt the real chest and then immediately
-- yield movement back to normal quest farming.
Runtime.ChestQuestNeeded = function()
    if not Settings.AutoQuests or not Settings.AutoChestQuests then return false end
    return standardQuestIncomplete("daily_discover_2_chests")
        or standardQuestIncomplete("discover_10_chests")
end

Runtime.FindWorldChests = function()
    local found = {}
    local function consider(obj)
        if not obj or not obj:IsA("Model") then return end
        if obj.Name ~= "NormalChest" and obj.Name ~= "SpecialChest" then return end
        if not obj.Parent then return end
        found[#found + 1] = obj
    end
    for _, obj in ipairs(workspace:GetChildren()) do consider(obj) end
    local folder = workspace:FindFirstChild("Chests")
    if folder then
        for _, obj in ipairs(folder:GetChildren()) do consider(obj) end
    end
    return found
end

Runtime.AutoChestQuestTick = function()
    if not Runtime.ChestQuestNeeded() then return false end
    if Settings.ActivityMode ~= "World Farm" or Runtime.Activity ~= "World" then return false end
    if Runtime.LiveEventActive or now() < (Runtime.LiveEventJoiningUntil or 0) then return false end
    if Runtime.QuestAcquiring or now() < (Runtime.TravelUntil or 0) then return false end

    if now() - (tonumber(Runtime.ChestLastReset) or 0) > 45 then
        Runtime.ChestAttempted = setmetatable({}, {__mode = "k"})
        Runtime.ChestLastReset = now()
    end

    local _, _, root = getCharacter()
    if not root then return false end
    local best, bestPart, bestDistance
    for _, model in ipairs(Runtime.FindWorldChests()) do
        if not Runtime.ChestAttempted[model] then
            local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
            if part then
                local distance = (part.Position - root.Position).Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestPart, bestDistance = model, part, distance
                end
            end
        end
    end
    if not best or not bestPart then return false end

    Runtime.ChestAttempted[best] = now()

    -- v1.4.2: chest quests must never own character movement. The previous build
    -- hard-set HumanoidRootPart.CFrame to every discovered chest, which looked like
    -- a random teleport before combat immediately moved back to the enemy. Executor
    -- interaction helpers can trigger the live chest without moving the character.
    -- If no helper is available we simply leave the chest for a later/nearby pass.
    local interacted = false
    if type(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, bestPart, 0)
        task.wait(0.04)
        pcall(firetouchinterest, root, bestPart, 1)
        interacted = true
    end
    for _, obj in ipairs(best:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and obj.Enabled and type(fireproximityprompt) == "function" then
            pcall(fireproximityprompt, obj)
            interacted = true
        elseif obj:IsA("ClickDetector") and type(fireclickdetector) == "function" then
            pcall(fireclickdetector, obj)
            interacted = true
        end
    end
    return interacted
end

local NPCController = Controllers.UI and Controllers.UI.NPCQuestPrompts
local NPCQuestWorldById = {}
local NPCQuestGiverById = {}
local NPCQuestGiverNameById = {}
do
    local worldNPCs = type(D.NPCQuestDialog.WorldNPCs) == "table" and D.NPCQuestDialog.WorldNPCs or {}
    for npcId, cfg in pairs(worldNPCs) do
        local n = type(npcId) == "string" and tonumber(npcId:match("^NPCQuestW(%d+)_")) or nil
        if n and type(cfg) == "table" and type(cfg.questIds) == "table" then
            for _, questId in ipairs(cfg.questIds) do
                NPCQuestWorldById[questId] = "World" .. n
                NPCQuestGiverById[questId] = npcId
                NPCQuestGiverNameById[questId] = cfg.giverName or npcId
            end
        end
    end
end

-- NPC quest rewards are not comparable by level requirement alone.  These
-- utility weights let the planner value scarce progression materials as well
-- as raw XP while still keeping XP/hour as the dominant signal.
local NPCQuestItemUtility = {
    st_1 = 18,   -- Enchant Stone
    st_2 = 95,   -- True Enchant Stone
    st_3 = 16,   -- Forgeguard
    st_4 = 24,   -- Skill Scroll
    st_5 = 110,  -- Ancient Skill Scroll
    st_6 = 5,    -- Golden Ring / event currency
    st_9 = 85,   -- ForgeShard
    st_11 = 45,  -- EXP Potion
    st_12 = 40,  -- Coins/Shards Potion
    st_13 = 45,  -- Damage Potion
    st_14 = 105, -- rare rune die
    st_15 = 36,  -- normal rune die
    st_16 = 52,  -- Magic Ore
}

local NPCQuestEnemyMeta = {}
for _, enemyDef in pairs(D.Enemies) do
    if type(enemyDef) == "table" and type(enemyDef.name) == "string" then
        NPCQuestEnemyMeta[enemyDef.name] = enemyDef
    end
end

local function npcQuestCooldown(state)
    if type(state) ~= "table" then return 0 end
    local remaining = math.max(0, tonumber(state.cooldownRemaining) or 0)
    local availableAt = tonumber(state.availableAt) or 0
    if availableAt > 0 then
        remaining = math.max(remaining, availableAt - os.time())
    end
    return remaining
end

local function npcQuestRewardUtility(def)
    local rewards = type(def) == "table" and type(def.rewards) == "table" and def.rewards or {}
    local utility = 0
    local items = type(rewards.Items) == "table" and rewards.Items or {}
    for itemId, amount in pairs(items) do
        utility = utility + (NPCQuestItemUtility[itemId] or 8) * math.max(0, tonumber(amount) or 0)
    end
    utility = utility + math.max(0, tonumber(rewards.ClanScore) or 0) * 22
    return utility
end

local function npcQuestMetrics(questId, def)
    if type(def) ~= "table" or type(def.objectives) ~= "table" then return nil end
    local worldId = NPCQuestWorldById[questId]
    if not worldId or not worldUnlocked(worldId) then return nil end

    local totalKills, totalHealth, totalRespawn = 0, 0, 0
    local nativeExp, nativeGold, nativeShards = 0, 0, 0
    local highestEnemyLevel = 0
    local bossObjectives = 0
    local observedRatioWeighted, observedKills = 0, 0
    for _, objective in ipairs(def.objectives) do
        local enemyName = objective.enemy or objective.enemyName or objective.id
        local target = math.max(0, tonumber(objective.target or objective.amount) or 0)
        local enemyDef = enemyName and NPCQuestEnemyMeta[enemyName] or nil
        if target <= 0 or type(enemyDef) ~= "table" then return nil end
        if enemyDef.world and enemyDef.world ~= worldId then return nil end
        if enemyDef.world and not worldUnlocked(enemyDef.world) then return nil end

        totalKills = totalKills + target
        totalHealth = totalHealth + math.max(1, tonumber(enemyDef.health) or 1) * target
        totalRespawn = totalRespawn + math.max(0, tonumber(enemyDef.respawn) or 0) * math.min(target, 2)
        nativeExp = nativeExp + math.max(0, tonumber(enemyDef.exp) or 0) * target
        nativeGold = nativeGold + math.max(0, tonumber(enemyDef.gold) or 0) * target
        nativeShards = nativeShards + math.max(0, tonumber(enemyDef.shards) or 0) * target
        highestEnemyLevel = math.max(highestEnemyLevel, tonumber(enemyDef.level) or 0)
        if enemyDef.boss or enemyDef.isBoss or enemyDef.miniboss or enemyDef.miniBoss or enemyDef.isMiniboss then
            bossObjectives = bossObjectives + 1
        end

        -- Learn how quickly this account actually kills each enemy. Static HP is a
        -- useful cold-start proxy, but observed TTK makes "best" personalized to the
        -- player's current gear/skills after only a few kills.
        local observed = Runtime.EnemyKillStats[enemyName]
        if Settings.AdaptiveQuestScoring and type(observed) == "table" and tonumber(observed.ema) then
            local staticProxy = math.max(0.35, math.log10(math.max(1, tonumber(enemyDef.health) or 1) + 10))
            local ratio = math.clamp((tonumber(observed.ema) or staticProxy) / staticProxy, 0.25, 4.0)
            observedRatioWeighted = observedRatioWeighted + ratio * target
            observedKills = observedKills + target
        end
    end
    if totalKills <= 0 then return nil end
    return {
        world = worldId,
        worldNumber = tonumber(worldId:match("World(%d+)$")) or 0,
        totalKills = totalKills,
        totalHealth = totalHealth,
        totalRespawn = totalRespawn,
        nativeExp = nativeExp,
        nativeGold = nativeGold,
        nativeShards = nativeShards,
        highestEnemyLevel = highestEnemyLevel,
        bossObjectives = bossObjectives,
        observedRatio = observedKills > 0 and (observedRatioWeighted / observedKills) or nil,
        observedCoverage = observedKills / math.max(totalKills, 1),
    }
end

local function scoreNpcQuest(questId, def, state)
    local level = numData("Level")
    local req = math.max(1, tonumber(def.levelRequired or def.level) or 1)
    if req > level or npcQuestCooldown(state) > 0 then return nil end

    local m = npcQuestMetrics(questId, def)
    if not m then return nil end
    local rewards = type(def.rewards) == "table" and def.rewards or {}
    local questExp = math.max(0, tonumber(rewards.Exp) or 0)
    local itemUtility = npcQuestRewardUtility(def)
    local totalProgressExp = questExp + m.nativeExp * 0.20
    local expPerKill = totalProgressExp / math.max(m.totalKills, 1)
    local avgHealth = m.totalHealth / math.max(m.totalKills, 1)

    -- Work is deliberately sub-linear in health: once the player is overgeared,
    -- kill count / respawn dominates; near progression level, tankier targets still
    -- receive a meaningful penalty.  A quest accepted by the game remains feasible
    -- even when its target's displayed level is slightly above the player.
    local healthWork = math.log10(avgHealth + 10)
    local levelOver = math.max(0, m.highestEnemyLevel - level)
    local work = m.totalKills * (1 + healthWork * 0.42) + m.totalRespawn * 0.055 + levelOver * 0.08
    if Settings.AdaptiveQuestScoring and m.observedRatio then
        local coverage = math.clamp(tonumber(m.observedCoverage) or 0, 0, 1)
        local learnedFactor = 1 + (math.clamp(m.observedRatio, 0.35, 2.75) - 1) * coverage
        work = work * math.clamp(learnedFactor, 0.45, 2.5)
    end
    local efficiency = totalProgressExp / math.max(work, 1)

    local mode = Settings.NPCQuestMode
    local score
    if mode == "Highest XP" then
        score = math.log10(questExp + 10) * 700 + math.log10(expPerKill + 10) * 420
    elseif mode == "Fastest Completion" then
        score = 150000 / math.max(work, 1) + math.log10(questExp + 10) * 120
    elseif mode == "Highest Level" then
        score = req * 35 + m.worldNumber * 800 + math.log10(questExp + 10) * 100
    else -- Best Progression
        score = math.log10(totalProgressExp + 10) * 560
            + math.log10(efficiency + 10) * 520
            + itemUtility * 7.5
            + m.worldNumber * 75
            + m.bossObjectives * 90
    end

    -- Prefer a partially progressed quest if state was retained by the server.
    if type(state) == "table" and type(state.progress) == "table" then
        local done = 0
        for _, objective in ipairs(def.objectives) do
            local enemy = objective.enemy or objective.enemyName or objective.id
            done = done + math.min(tonumber(state.progress[enemy]) or 0, tonumber(objective.target or objective.amount) or 0)
        end
        score = score + (done / math.max(m.totalKills, 1)) * 500
    end

    return score, m
end

-- Enemy-first NPC quest planner -------------------------------------------------
-- "Best quest" follows the enemy we actually want to farm.  This prevents a
-- high-reward but weaker quest from pulling World Farm away from the strongest
-- progression enemy the account can currently handle.
Runtime.QuestTargetsEnemy = function(def, enemyName)
    if type(def) ~= "table" or type(enemyName) ~= "string" then return false end
    for _, objective in ipairs(def.objectives or {}) do
        local objectiveEnemy = objective.enemy or objective.enemyName or objective.id
        if objectiveEnemy == enemyName then return true end
    end
    return false
end

Runtime.FindQuestForEnemy = function(enemyName)
    if not NPCController or type(enemyName) ~= "string" then return nil end
    local best
    for questId, qdef in pairs(D.NPCQuestDialog) do
        if type(questId) == "string" and questId:match("^NPCQuest%d+$")
            and type(qdef) == "table"
            and Runtime.QuestTargetsEnemy(qdef, enemyName) then
            local state = NPCController.States and NPCController.States[questId]
            local acceptedElsewhere = type(state) == "table"
                and state.accepted == true
                and NPCController.ActiveQuestId ~= questId
            if not acceptedElsewhere then
                local score, metrics = scoreNpcQuest(questId, qdef, state)
                if score and metrics then
                    local row = {
                        id = questId,
                        def = qdef,
                        state = state,
                        score = score,
                        metrics = metrics,
                        world = metrics.world,
                        giverId = NPCQuestGiverById[questId],
                        giverName = NPCQuestGiverNameById[questId] or qdef.name or questId,
                        matchedEnemy = enemyName,
                    }
                    if not best
                        or row.score > best.score
                        or (math.abs(row.score - best.score) < 0.001
                            and (tonumber(qdef.levelRequired) or 1) > (tonumber(best.def.levelRequired) or 1)) then
                        best = row
                    end
                end
            end
        end
    end
    return best
end

-- Estimate this account's real world-farm DPS from completed kills. This lets
-- the quest/enemy planner predict whether a newly unlocked target is practical
-- before wasting a long first fight on it. Median DPS is used to resist outliers.
Runtime.EstimateFarmDPS = function()
    local samples = {}
    for enemyName, row in pairs(Runtime.EnemyKillStats) do
        local enemyDef = NPCQuestEnemyMeta[enemyName]
        local elapsed = type(row) == "table" and tonumber(row.ema) or nil
        local health = type(enemyDef) == "table" and tonumber(enemyDef.health) or nil
        if elapsed and elapsed > 0.05 and health and health > 0 then
            samples[#samples + 1] = health / elapsed
        end
    end
    if #samples == 0 then return nil, 0 end
    table.sort(samples)
    local middle = math.floor((#samples + 1) / 2)
    local dps
    if #samples % 2 == 0 then
        dps = (samples[middle] + samples[middle + 1]) * 0.5
    else
        dps = samples[middle]
    end
    Runtime.EstimatedFarmDPS = dps
    Runtime.EstimatedFarmDPSSamples = #samples
    return dps, #samples
end

Runtime.EstimateEnemyTTK = function(enemyName, enemyDef)
    local observed = Runtime.EnemyKillStats[enemyName]
    if type(observed) == "table" and tonumber(observed.ema) then
        return tonumber(observed.ema), true
    end
    local dps, sampleCount = Runtime.EstimateFarmDPS()
    local health = type(enemyDef) == "table" and math.max(1, tonumber(enemyDef.health) or 1) or 1
    if dps and dps > 0 and sampleCount >= 2 then
        return health / dps, false
    end
    return nil, false
end

Runtime.EnemyLootUtility = function(enemyDef)
    if type(enemyDef) ~= "table" or type(enemyDef.lootPool) ~= "table"
        or type(D.LootPool.GetDropChances) ~= "function" then return 0 end
    local total = 0
    for _, poolId in ipairs(enemyDef.lootPool) do
        local chances = safe(D.LootPool.GetDropChances, D.LootPool, poolId, enemyDef.guaranteedDrop == true)
        if type(chances) == "table" then
            for itemId, percent in pairs(chances) do
                local itemValue = NPCQuestItemUtility[itemId] or 0
                local info = type(D.Items.Lookup) == "function" and safe(D.Items.Lookup, D.Items, itemId) or nil
                if type(info) == "table" and info.type == "Equipment" then
                    local rarity = tonumber(info.rarity) or 1
                    local rarityValue = ({2, 5, 12, 30, 80, 190, 420})[math.clamp(rarity, 1, 7)] or 2
                    itemValue = math.max(itemValue, rarityValue)
                elseif itemValue <= 0 and type(itemId) == "string" and itemId:match("^st_") then
                    itemValue = 8
                end
                total = total + math.max(0, tonumber(percent) or 0) * itemValue / 100
            end
        end
    end
    -- LootDropGui shows two independent global 0.5% rare-material drops on
    -- every normal enemy except Chicken. Include their expected value too.
    if enemyDef.name ~= "Chicken" then
        total = total + 0.005 * ((NPCQuestItemUtility.st_2 or 95) + (NPCQuestItemUtility.st_5 or 110))
    end
    return total
end

Runtime.EnemyDeathPenalty = function(enemyName)
    local row = Runtime.EnemyDeathStats[enemyName]
    if type(row) ~= "table" then return 0 end
    local deaths = math.max(0, tonumber(row.deaths) or 0)
    if deaths <= 0 then return 0 end

    local levelNow = numData("Level")
    local dpsNow = select(1, Runtime.EstimateFarmDPS())
    local strongerByLevel = levelNow >= (tonumber(row.level) or levelNow) + 25
    local oldDps = tonumber(row.dps)
    local strongerByDps = oldDps and oldDps > 0 and dpsNow and dpsNow >= oldDps * 1.25
    if strongerByLevel or strongerByDps then
        Runtime.EnemyDeathStats[enemyName] = nil
        return 0
    end

    if deaths >= 2 then return math.huge end
    return 45000
end

Runtime.SelectBestEnemyQuestPair = function()
    if not Settings.QuestMatchBestEnemy or not NPCController then
        Runtime.BestFarmEnemy = nil
        Runtime.BestFarmEnemyWorld = nil
        Runtime.BestFarmEnemyLevel = nil
        Runtime.BestFarmEnemyTTK = nil
        Runtime.BestFarmEnemyTTKObserved = false
        return nil
    end

    local playerLevel = numData("Level")
    local candidates = {}
    for enemyName, enemyDef in pairs(NPCQuestEnemyMeta) do
        if type(enemyDef) == "table" and type(enemyName) == "string" then
            local worldId = enemyDef.world
            local enemyLevel = math.max(1, tonumber(enemyDef.level) or 1)
            local behavior = tostring(enemyDef.behavior or "")
            -- Quest availability is the authoritative fightability gate. Loot Up
            -- intentionally unlocks some quests before the target's display level.
            local normalWorldEnemy = type(worldId) == "string"
                and D.Worlds[worldId] ~= nil
                and worldUnlocked(worldId)
            local eventOnly = behavior == "MageOfDarkness"
                or behavior == "Krampus"
                or behavior == "EasterBunny"
                or enemyDef.liveEvent == true
                or enemyDef.eventOnly == true

            local boss = enemyDef.boss or enemyDef.isBoss
            local mini = enemyDef.miniboss or enemyDef.miniBoss or enemyDef.isMiniboss
            local strategyAllowed = Settings.FarmStrategy ~= "Bosses" or boss or mini

            if normalWorldEnemy and not eventOnly and strategyAllowed then
                local quest = Runtime.FindQuestForEnemy(enemyName)
                if quest then
                    local worldNumber = tonumber(worldId:match("World(%d+)$")) or 0
                    local bossTier = boss and 2 or mini and 1 or 0
                    local lootUtility = Runtime.EnemyLootUtility(enemyDef)
                    local reward = math.max(0, tonumber(enemyDef.exp) or 0)
                        + math.max(0, tonumber(enemyDef.gold) or 0) * 0.45
                        + math.max(0, tonumber(enemyDef.shards) or 0) * 2.5
                    local health = math.max(1, tonumber(enemyDef.health) or 1)
                    local ttk, ttkObserved = Runtime.EstimateEnemyTTK(enemyName, enemyDef)
                    local deathPenalty = Runtime.EnemyDeathPenalty(enemyName)
                    -- Actual evidence wins. For unseen targets, two or more prior kill
                    -- samples provide a useful first-fight estimate. Targets predicted
                    -- to take over 75 seconds are deferred until the build improves.
                    -- Two real deaths temporarily mark the target impractical until the
                    -- account gains ~25 levels or ~25% measured DPS.
                    local practicalFight = (not ttk or ttk <= 75) and deathPenalty < math.huge
                    local respawn = math.max(0, tonumber(enemyDef.respawn) or 0)
                    local questScore = tonumber(quest.score) or 0

                    local combatScore
                    if Settings.FarmStrategy == "Highest Level" then
                        combatScore = worldNumber * 1000000000000
                            + enemyLevel * 100000000
                            + bossTier * 1000000
                            - math.min(ttk or 0, 180) * 100
                            - deathPenalty
                    else
                        -- Smart stays in the highest useful world, then balances enemy
                        -- progression level against predicted clear time, respawn and the
                        -- matching quest's own progression value. This avoids a tanky
                        -- nominally-higher enemy reducing real XP/materials per minute.
                        local clearPenalty = math.min(ttk or 0, 180) * 320
                        local respawnPenalty = respawn * 35
                        combatScore = worldNumber * 1000000000000
                            + enemyLevel * 12000
                            + bossTier * 1800
                            + math.log(1 + reward) * 1400
                            + (reward / health) * 3500
                            + lootUtility * 600
                            + questScore * 0.75
                            - clearPenalty
                            - respawnPenalty
                            - deathPenalty
                    end

                    if practicalFight then
                        candidates[#candidates + 1] = {
                            enemy = enemyName,
                            enemyDef = enemyDef,
                            enemyLevel = enemyLevel,
                            world = worldId,
                            score = combatScore,
                            quest = quest,
                            estimatedTTK = ttk,
                            ttkObserved = ttkObserved,
                        }
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if math.abs(a.score - b.score) > 0.001 then return a.score > b.score end
        if a.enemyLevel ~= b.enemyLevel then return a.enemyLevel > b.enemyLevel end
        return a.enemy < b.enemy
    end)

    local pair = candidates[1]
    Runtime.BestFarmEnemy = pair and pair.enemy or nil
    Runtime.BestFarmEnemyWorld = pair and pair.world or nil
    Runtime.BestFarmEnemyLevel = pair and pair.enemyLevel or nil
    Runtime.BestFarmEnemyTTK = pair and pair.estimatedTTK or nil
    Runtime.BestFarmEnemyTTKObserved = pair and pair.ttkObserved or false
    if pair and pair.quest then
        pair.quest.matchedEnemy = pair.enemy
        pair.quest.enemyScore = pair.score
    end
    return pair
end

local function bestAvailableNpcQuest()
    if not NPCController then return nil end

    if Settings.QuestMatchBestEnemy then
        local pair = Runtime.SelectBestEnemyQuestPair()
        -- Enemy-sync mode is strict: never fall back to an unrelated quest.
        -- If every matching quest is cooling down/unavailable, simply keep
        -- farming rather than letting quest scoring choose the wrong enemy.
        return pair and pair.quest or nil
    end

    local candidates = {}
    for questId, qdef in pairs(D.NPCQuestDialog) do
        if type(questId) == "string" and questId:match("^NPCQuest%d+$")
            and type(qdef) == "table" and type(qdef.objectives) == "table" then
            local state = NPCController.States and NPCController.States[questId]
            if not (type(state) == "table" and state.accepted == true) then
                local score, metrics = scoreNpcQuest(questId, qdef, state)
                if score then
                    candidates[#candidates + 1] = {
                        id = questId, def = qdef, state = state, score = score, metrics = metrics,
                        world = metrics.world, giverId = NPCQuestGiverById[questId],
                        giverName = NPCQuestGiverNameById[questId] or qdef.name or questId,
                    }
                end
            end
        end
    end
    -- "Best Progression" should not drag an endgame player back several worlds
    -- just because an old repeatable quest has an unusually valuable consumable.
    -- First select the highest unlocked world that has an available quest, then
    -- optimize reward/work inside that progression tier. Other explicit modes keep
    -- their literal cross-world behavior.
    if Settings.NPCQuestMode == "Best Progression" and #candidates > 1 then
        local highestWorld = 0
        for _, row in ipairs(candidates) do
            highestWorld = math.max(highestWorld, row.metrics and row.metrics.worldNumber or 0)
        end
        if highestWorld > 0 then
            local filtered = {}
            for _, row in ipairs(candidates) do
                if row.metrics and row.metrics.worldNumber == highestWorld then
                    filtered[#filtered + 1] = row
                end
            end
            if #filtered > 0 then candidates = filtered end
        end
    end

    table.sort(candidates, function(a, b)
        if math.abs(a.score - b.score) > 0.001 then return a.score > b.score end
        local ar = tonumber(a.def.levelRequired) or 1
        local br = tonumber(b.def.levelRequired) or 1
        if ar ~= br then return ar > br end
        return a.id < b.id
    end)
    return candidates[1]
end

local function refreshBestNpcQuestPlan()
    if not Settings.AutoNPCQuests then
        Runtime.BestNpcQuest = nil
        Runtime.BestNpcQuestScore = nil
        Runtime.BestNpcQuestGiver = nil
        Runtime.BestFarmEnemy = nil
        Runtime.BestFarmEnemyWorld = nil
        Runtime.BestFarmEnemyLevel = nil
        return nil
    end
    local plan = bestAvailableNpcQuest()
    Runtime.BestNpcQuest = plan and plan.id or nil
    Runtime.BestNpcQuestScore = plan and plan.score or nil
    Runtime.BestNpcQuestGiver = plan and plan.giverName or nil
    return plan
end

local function refreshAllNpcQuestStates(force)
    if not NPCController or type(NPCController.RequestAllStates) ~= "function" then return false end
    if Runtime.NpcStateRefreshInFlight then return false end
    if not force and now() - (Runtime.NpcStatesLoadedAt or -math.huge) < 120 then return false end

    Runtime.NpcStateRefreshInFlight = true
    Runtime.NpcStatesLoadedAt = now()
    task.spawn(function()
        local ok = safe(NPCController.RequestAllStates, NPCController) == true
        Runtime.NpcStateRefreshInFlight = false
        Runtime.NpcStatesPrimed = Runtime.NpcStatesPrimed or ok
        Runtime.LastNpcStateChange = now()
        if Runtime.Alive and Settings.AutoNPCQuests then
            refreshBestNpcQuestPlan()
        end
    end)
    return true
end

-- The game already hydrates these states on controller startup, but an autofarm
-- can be injected before that pass has completed. Re-score instantly whenever the
-- game's own controller changes, and force one non-blocking hydration immediately.
if NPCController and NPCController.Changed then
    connect(NPCController.Changed, function()
        Runtime.LastNpcStateChange = now()
        Runtime.NpcStatesPrimed = true
        if Runtime.PendingNpcQuest and NPCController.ActiveQuestId == Runtime.PendingNpcQuest then
            Runtime.PendingNpcQuest = nil
            Runtime.PendingNpcQuestUntil = 0
            Runtime.QuestReplaceFrom = nil
            Runtime.QuestReplaceTo = nil
            Runtime.QuestReplaceStartedAt = 0
            Runtime.QuestReplaceCooldownUntil = 0
            Runtime.QuestAcquiring = false
        elseif Runtime.QuestReplaceFrom and NPCController.ActiveQuestId ~= Runtime.QuestReplaceFrom then
            -- The old quest has actually stopped being active. Release combat/travel
            -- ownership so the next NPC tick can travel to and accept the replacement.
            Runtime.QuestAcquiring = false
            Runtime.QuestAcquireUntil = 0
        end
        if Settings.AutoNPCQuests then
            task.defer(function()
                if Runtime.Alive then refreshBestNpcQuestPlan() end
            end)
        end
    end)
end
refreshAllNpcQuestStates(true)
local function npcQuestCompletion(state, def)
    if type(state) ~= "table" or type(def) ~= "table" then return false end
    if state.completed == true then return true end
    local progress = type(state.progress) == "table" and state.progress or {}
    for _, objective in ipairs(def.objectives or {}) do
        local enemy = objective.enemy or objective.enemyName or objective.id
        local target = tonumber(objective.target or objective.amount) or 0
        local current = tonumber(progress[enemy]) or 0
        if current < target then return false end
    end
    return true
end

local function npcQuestProgressRatio(state, def)
    if type(state) ~= "table" or type(def) ~= "table" then return 0 end
    if state.completed == true then return 1 end
    local progress = type(state.progress) == "table" and state.progress or {}
    local done, total = 0, 0
    for _, objective in ipairs(def.objectives or {}) do
        local enemy = objective.enemy or objective.enemyName or objective.id
        local target = math.max(0, tonumber(objective.target or objective.amount) or 0)
        if enemy and target > 0 then
            total = total + target
            done = done + math.min(target, math.max(0, tonumber(progress[enemy]) or 0))
        end
    end
    if total <= 0 then return 0 end
    return math.clamp(done / total, 0, 1)
end

local function shouldReplaceActiveNpcQuest(activeId, activeDef, activeState)
    if not Settings.SmartQuestReplacement or npcQuestCompletion(activeState, activeDef) then
        return nil
    end
    local keepAt = math.clamp((tonumber(Settings.QuestKeepProgress) or 35) / 100, 0, 1)
    local progress = npcQuestProgressRatio(activeState, activeDef)
    if progress >= keepAt then return nil end

    local activeScore, activeMetrics = scoreNpcQuest(activeId, activeDef, activeState)
    local alternative = bestAvailableNpcQuest()
    if not activeScore or not alternative or alternative.id == activeId then return nil end

    local improvement = (alternative.score - activeScore) / math.max(math.abs(activeScore), 1) * 100
    local minimum = math.max(0, tonumber(Settings.QuestSwitchMinImprovement) or 25)
    local enemyUpgrade = Settings.QuestMatchBestEnemy == true
        and type(Runtime.BestFarmEnemy) == "string"
        and Runtime.QuestTargetsEnemy(alternative.def, Runtime.BestFarmEnemy)
        and not Runtime.QuestTargetsEnemy(activeDef, Runtime.BestFarmEnemy)
    local progressionAdvance = Settings.NPCQuestMode == "Best Progression"
        and type(activeMetrics) == "table"
        and type(alternative.metrics) == "table"
        and (alternative.metrics.worldNumber or 0) > (activeMetrics.worldNumber or 0)

    if not enemyUpgrade and not progressionAdvance and improvement < minimum then return nil end

    alternative.enemyUpgrade = enemyUpgrade
    alternative.progressionAdvance = progressionAdvance
    alternative.improvement = (enemyUpgrade or progressionAdvance) and math.max(improvement, minimum + 1) or improvement
    alternative.activeProgress = progress
    return alternative
end

local function activeNpcQuest()
    if not NPCController then return nil end
    local id = NPCController.ActiveQuestId
    if not id and type(NPCController.RecomputeActiveQuestId) == "function" then
        id = safe(NPCController.RecomputeActiveQuestId, NPCController)
    end
    if type(id) ~= "string" then return nil end
    local def = D.NPCQuestDialog[id]
    local state = NPCController.States and NPCController.States[id]
    if type(def) ~= "table" or type(state) ~= "table" then return nil end
    return id, def, state
end

local function getNpcTarget()
    if not Settings.NPCQuestPriority then
        Runtime.CurrentNpcQuest = nil
        Runtime.CurrentQuestEnemy = nil
        return nil, nil
    end
    local id, def, state = activeNpcQuest()
    Runtime.CurrentNpcQuest = id
    if not id then return nil, nil end
    local progress = type(state.progress) == "table" and state.progress or {}

    -- When this quest was selected to match the best farm enemy, kill that enemy
    -- first even if it is not the first objective in a multi-objective quest.
    local preferredEnemy = Settings.QuestMatchBestEnemy and Runtime.BestFarmEnemy or nil
    if preferredEnemy and Runtime.QuestTargetsEnemy(def, preferredEnemy) then
        for _, objective in ipairs(def.objectives or {}) do
            local enemy = objective.enemy or objective.enemyName or objective.id
            local target = tonumber(objective.target or objective.amount) or 0
            if enemy == preferredEnemy and (tonumber(progress[enemy]) or 0) < target then
                Runtime.CurrentQuestEnemy = enemy
                return enemy, def.world or def.worldId or NPCQuestWorldById[id]
            end
        end
    end

    for _, objective in ipairs(def.objectives or {}) do
        local enemy = objective.enemy or objective.enemyName or objective.id
        local target = tonumber(objective.target or objective.amount) or 0
        if enemy and (tonumber(progress[enemy]) or 0) < target then
            Runtime.CurrentQuestEnemy = enemy
            return enemy, def.world or def.worldId or NPCQuestWorldById[id]
        end
    end
    Runtime.CurrentQuestEnemy = nil
    return nil, def.world or def.worldId or NPCQuestWorldById[id]
end

-- Enemy / farm planner ----------------------------------------------------------
local EnemyByName = {}
for _, def in pairs(D.Enemies) do
    if type(def) == "table" then
        if type(def.name) == "string" then EnemyByName[def.name] = def end
        if type(def.modelName) == "string" then EnemyByName[def.modelName] = def end
    end
end

local function getEnemyDefinition(model)
    if not model then return nil end
    local direct = D.Enemies[model.Name]
    if type(direct) == "table" then return direct end
    return EnemyByName[model.Name]
end

Runtime.BindCharacterDeath = function(character)
    if not character then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 8)
    if not humanoid then return end
    connect(humanoid.Died, function()
        if not Runtime.Alive or not Settings.Master then return end
        Runtime.RecentCombatDeaths[#Runtime.RecentCombatDeaths + 1] = now()
        local target = Runtime.Target
        if target then
            local def = getEnemyDefinition(target)
            local enemyName = def and def.name or target.Name
            if type(enemyName) == "string" and enemyName ~= "" then
                local row = Runtime.EnemyDeathStats[enemyName] or {deaths = 0}
                row.deaths = (tonumber(row.deaths) or 0) + 1
                row.level = numData("Level")
                row.dps = select(1, Runtime.EstimateFarmDPS())
                row.at = now()
                Runtime.EnemyDeathStats[enemyName] = row
            end
        end
        Runtime.Target = nil
    end)
end

if LocalPlayer.Character then task.defer(Runtime.BindCharacterDeath, LocalPlayer.Character) end
connect(LocalPlayer.CharacterAdded, function(character)
    task.defer(Runtime.BindCharacterDeath, character)
end)

local function beginTargetTiming(model)
    if not Settings.AdaptiveQuestScoring or Runtime.Activity ~= "World" or not model or Runtime.TargetStartedAt[model] then return end
    Runtime.TargetStartedAt[model] = now()
end

local function finishTargetTiming(model)
    if not model then return end
    local started = Runtime.TargetStartedAt[model]
    Runtime.TargetStartedAt[model] = nil
    if not started or not Settings.AdaptiveQuestScoring then return end

    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health > 0 then return end
    local elapsed = now() - started
    if elapsed < 0.05 or elapsed > 180 then return end

    local def = getEnemyDefinition(model)
    local name = def and def.name or model.Name
    if type(name) ~= "string" or name == "" then return end
    local row = Runtime.EnemyKillStats[name]
    if type(row) ~= "table" then
        row = {ema = elapsed, kills = 0}
        Runtime.EnemyKillStats[name] = row
    else
        row.ema = tonumber(row.ema) and (row.ema * 0.72 + elapsed * 0.28) or elapsed
    end
    row.kills = (tonumber(row.kills) or 0) + 1
    row.last = elapsed
end

local function getLiveEnemies()
    local list, seen = {}, {}
    if Controllers.Enemy and type(Controllers.Enemy.Registry) == "table" then
        for model in pairs(Controllers.Enemy.Registry) do
            if typeof(model) == "Instance" and model:IsA("Model") then
                seen[model] = true
                list[#list + 1] = model
            end
        end
    end
    for _, model in ipairs(CollectionService:GetTagged("Enemy")) do
        if typeof(model) == "Instance" and model:IsA("Model") and not seen[model] then
            seen[model] = true
            list[#list + 1] = model
        end
    end
    local folder = workspace:FindFirstChild("Enemies")
    if folder then
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and not seen[model] then
                list[#list + 1] = model
            end
        end
    end
    return list
end

local function liveEnemy(model)
    if not model or not model.Parent then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart")
    return hum ~= nil and root ~= nil and hum.Health > 0
end

local function enemyScore(model, strategy, root, desiredName, desiredWorld)
    if not liveEnemy(model) then return -math.huge end
    local hrp = model.HumanoidRootPart
    local dist = root and (hrp.Position - root.Position).Magnitude or 0
    local isLiveEventBoss = model:GetAttribute("LiveEventBoss") == true
    if Runtime.LiveEventActive then
        return isLiveEventBoss and (1000000 - dist) or -math.huge
    elseif isLiveEventBoss and Settings.LiveEventPriority then
        return 900000 - dist
    end
    local def = getEnemyDefinition(model)
    if desiredName and model.Name ~= desiredName and not (def and def.name == desiredName) then
        return -math.huge
    end
    if desiredWorld and def and def.world and def.world ~= desiredWorld then
        return -math.huge
    end
    if Runtime.Activity ~= "World" then
        return 100000 - dist
    end
    local playerLevel = numData("Level")
    local behavior = def and tostring(def.behavior or "") or ""
    local specialEventBoss = Settings.EventBossPriority == true and (
        behavior == "MageOfDarkness" or behavior == "Krampus" or behavior == "EasterBunny"
    )
    if def and tonumber(def.level) and tonumber(def.level) > playerLevel and not specialEventBoss and not desiredName then
        return -math.huge
    end
    -- These global bosses intentionally use level 1000 in data. If one actually
    -- exists as a live enemy, it is an event opportunity rather than an invalid target.
    if specialEventBoss then
        return 250000 - dist
    end
    if strategy == "Closest" then
        return -dist
    end
    if strategy == "Highest Level" then
        return (def and tonumber(def.level) or 0) * 1000 - dist
    end
    if strategy == "MiniBosses" then
        local mini = def and (def.miniboss or def.miniBoss or def.isMiniboss)
        if not mini then return -math.huge end
        return 120000 + (def and tonumber(def.level) or 0) * 100 - dist
    end
    if strategy == "Bosses" then
        local boss = def and (def.boss or def.isBoss)
        local mini = def and (def.miniboss or def.miniBoss or def.isMiniboss)
        return (boss and 100000 or mini and 50000 or 0) + (def and tonumber(def.level) or 0) * 100 - dist
    end
    local level = def and tonumber(def.level) or 0
    local exp = def and tonumber(def.exp) or 0
    local gold = def and tonumber(def.gold) or 0
    local shards = def and tonumber(def.shards) or 0
    local health = def and tonumber(def.health) or 1
    local reward = exp + gold * 0.45 + shards * 2.5
    local efficiency = reward / math.max(health, 1)
    local bossBonus = def and ((def.boss or def.isBoss) and 140 or (def.miniboss or def.isMiniboss or def.miniBoss) and 60 or 0) or 0
    return level * 7 + math.log(1 + math.max(reward, 0)) * 18 + efficiency * 35 + bossBonus - dist * 0.045
end

local function chooseEnemy()
    local _, _, root = getCharacter()
    if not root then return nil end
    local desiredName, desiredWorld
    if Runtime.Activity == "World" then
        -- During a smart quest switch, route combat toward the enemy the pending
        -- quest was chosen for instead of letting the old active quest pull us back.
        if Settings.QuestMatchBestEnemy and Runtime.PendingNpcQuest and Runtime.BestFarmEnemy then
            desiredName = Runtime.BestFarmEnemy
            desiredWorld = Runtime.BestFarmEnemyWorld or NPCQuestWorldById[Runtime.PendingNpcQuest]
        else
            desiredName, desiredWorld = getNpcTarget()
        end
        if not desiredName and Settings.QuestMatchBestEnemy and Runtime.BestFarmEnemy then
            desiredName = Runtime.BestFarmEnemy
            desiredWorld = Runtime.BestFarmEnemyWorld
        end
        if not desiredName then
            desiredName, desiredWorld = getIncompleteWorldQuestTarget()
        end
        if not desiredWorld then
            local current = getData("CurrentWorld")
            if type(current) == "string" and D.Worlds[current] and worldUnlocked(current) then
                desiredWorld = current
            else
                local highest = highestUnlockedWorld()
                desiredWorld = highest and highest.id or nil
            end
        end
    end
    local strategy = Settings.FarmStrategy
    if Runtime.Activity == "World" and not desiredName then
        local questStrategy = standardQuestCombatStrategy()
        if questStrategy then
            strategy = questStrategy
        elseif seasonNeedsMinibossKills() then
            strategy = "MiniBosses"
        end
    end
    local best, bestScore = nil, -math.huge
    for _, model in ipairs(getLiveEnemies()) do
        local score = enemyScore(model, strategy, root, desiredName, desiredWorld)
        if score > bestScore then
            bestScore = score
            best = model
        end
    end
    if not best and desiredName then
        for _, model in ipairs(getLiveEnemies()) do
            local score = enemyScore(model, strategy, root, nil, desiredWorld)
            if score > bestScore then
                bestScore = score
                best = model
            end
        end
    end
    return best
end

local function setNoclip(on)
    local character = LocalPlayer.Character
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            if on then
                if Runtime.OriginalCollision[part] == nil then
                    Runtime.OriginalCollision[part] = part.CanCollide
                end
                part.CanCollide = false
            elseif Runtime.OriginalCollision[part] ~= nil then
                part.CanCollide = Runtime.OriginalCollision[part]
                Runtime.OriginalCollision[part] = nil
            end
        end
    end
end

local DOWN_FACING_RIGHT = Vector3.new(1, 0, 0)
local DOWN_FACING_UP = Vector3.new(0, 0, -1)
local DOWN_FACING_BACK = Vector3.new(0, 1, 0)

local function releaseDownFacingLock()
    local humanoid = Runtime.DownFacingHumanoid
    if Runtime.DownFacingHasOriginalAutoRotate and humanoid and humanoid.Parent then
        pcall(function()
            humanoid.AutoRotate = Runtime.DownFacingOriginalAutoRotate
        end)
    end
    Runtime.DownFacingActive = false
    Runtime.DownFacingTarget = nil
    Runtime.DownFacingHumanoid = nil
    Runtime.DownFacingHasOriginalAutoRotate = false
end

local function acquireDownFacingLock(model, humanoid)
    if Runtime.DownFacingHumanoid ~= humanoid then
        releaseDownFacingLock()
        Runtime.DownFacingHumanoid = humanoid
        Runtime.DownFacingOriginalAutoRotate = humanoid.AutoRotate
        Runtime.DownFacingHasOriginalAutoRotate = true
    end
    Runtime.DownFacingTarget = model
    Runtime.DownFacingActive = true
    if humanoid.AutoRotate ~= false then
        humanoid.AutoRotate = false
    end
end

local function downFacingCFrame(enemyRoot, hover)
    local targetPos = Vector3.new(
        enemyRoot.Position.X,
        enemyRoot.Position.Y + hover,
        enemyRoot.Position.Z
    )
    return CFrame.fromMatrix(
        targetPos,
        DOWN_FACING_RIGHT,
        DOWN_FACING_UP,
        DOWN_FACING_BACK
    )
end

local function applyDownFacingLock()
    if not Runtime.DownFacingActive then return end

    local target = Runtime.DownFacingTarget
    local combatActivity = Runtime.Activity == "World"
        or Runtime.Activity == "Dungeon"
        or Runtime.Activity == "Tower"
        or Runtime.Activity == "LiveEvent"

    if not Runtime.Alive
        or not Settings.Master
        or not Settings.PerfectDownFacing
        or not combatActivity
        or Runtime.QuestAcquiring
        or now() < (Runtime.TravelUntil or 0)
        or now() < (Runtime.ChestSweepUntil or 0)
        or target ~= Runtime.Target
        or not liveEnemy(target) then
        releaseDownFacingLock()
        return
    end

    local _, humanoid, root = getCharacter()
    local enemyRoot = target and target:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or not enemyRoot then
        releaseDownFacingLock()
        return
    end

    -- Humanoid.AutoRotate continuously tries to return a pitched character to an
    -- upright movement-facing pose. Keep it disabled only while this lock owns
    -- combat facing, then restore its exact previous value on release.
    acquireDownFacingLock(target, humanoid)

    local hover = tonumber(Runtime.CurrentHoverHeight) or tonumber(Settings.HoverHeight) or 6
    root.CFrame = downFacingCFrame(enemyRoot, hover)
    root.AssemblyAngularVelocity = Vector3.zero
    if Settings.AntiStuck then
        root.AssemblyLinearVelocity = Vector3.zero
    end
end

local function moveToEnemy(model)
    local _, humanoid, root = getCharacter()
    if not root or not liveEnemy(model) then
        releaseDownFacingLock()
        return false
    end
    local enemyRoot = model:FindFirstChild("HumanoidRootPart")
    if not enemyRoot then
        releaseDownFacingLock()
        return false
    end

    -- Size-aware vertical positioning. The previous farm used one fixed offset
    -- from HumanoidRootPart for every enemy, so a tiny mob and a giant boss
    -- placed the player at the same height. Instead, measure the live model and
    -- keep the player's root above the enemy's real top surface. HoverHeight is
    -- retained as the familiar reference/bias: 6 studs behaves roughly like the
    -- old setting on a normal humanoid-sized enemy, but automatically scales up
    -- or down for differently-sized enemies.
    local desiredHeight = tonumber(Settings.HoverHeight) or 6
    local bodyHeight = enemyRoot.Size.Y
    local bodyWidth = math.max(enemyRoot.Size.X, enemyRoot.Size.Z)

    if Settings.DynamicEnemyHeight then
        local enemyTopFromRoot = math.max(0.5, enemyRoot.Size.Y * 0.5)
        local okBounds, boundsCF, boundsSize = pcall(function()
            return model:GetBoundingBox()
        end)

        if okBounds and typeof(boundsCF) == "CFrame" and typeof(boundsSize) == "Vector3" then
            -- Clamp pathological helper/hitbox parts so one malformed model cannot
            -- throw the farmer hundreds of studs into the air. Real bosses still
            -- have plenty of room to scale.
            bodyHeight = math.clamp(boundsSize.Y, enemyRoot.Size.Y, 120)
            bodyWidth = math.clamp(
                math.max(boundsSize.X, boundsSize.Z),
                math.max(enemyRoot.Size.X, enemyRoot.Size.Z),
                120
            )

            local measuredTop = (boundsCF.Position.Y + boundsSize.Y * 0.5) - enemyRoot.Position.Y
            if measuredTop > 0 and measuredTop <= 80 then
                enemyTopFromRoot = math.max(enemyTopFromRoot, measuredTop)
            end
        end

        -- Humanoid.HipHeight + half the player's root is a stable approximation
        -- of how far the player's feet/body extend below their root. A normal
        -- Roblox humanoid is about 3 studs root->feet and a normal enemy about
        -- 3 studs root->top, hence the 6-stud reference used by the old setting.
        local playerBottom = math.max(
            root.Size.Y * 0.5,
            (humanoid and tonumber(humanoid.HipHeight) or 2) + root.Size.Y * 0.5
        )
        local referenceBias = desiredHeight - 6
        desiredHeight = enemyTopFromRoot + playerBottom + referenceBias
        desiredHeight = math.clamp(desiredHeight, 1, 80)
    end

    -- Smooth only while staying on the same target. A new enemy adopts its own
    -- correct size immediately; animated/scaling bosses then adjust without
    -- jitter as their bounding box changes.
    if Runtime.PositionTarget ~= model or type(Runtime.CurrentHoverHeight) ~= "number" then
        Runtime.PositionTarget = model
        Runtime.CurrentHoverHeight = desiredHeight
    else
        local speed = math.max(1, tonumber(Settings.HeightSmoothing) or 14)
        local alpha = 1 - math.exp(-speed * 0.055)
        Runtime.CurrentHoverHeight = Runtime.CurrentHoverHeight
            + (desiredHeight - Runtime.CurrentHoverHeight) * alpha
    end

    Runtime.TargetBodyHeight = bodyHeight
    Runtime.TargetBodyWidth = bodyWidth

    -- v1.2.9: stable straight-down combat facing.
    --
    -- A normal CFrame.lookAt(position, enemyPosition) becomes numerically unstable
    -- when the player is almost directly above the enemy because the requested
    -- look direction approaches the world up/down axis. That is what caused the
    -- old down -> upright -> down "spazz". For perfect downward facing, do not
    -- derive pitch from the enemy's moving root at all. Center directly over the
    -- target and build one fixed orthonormal basis whose LookVector is exactly
    -- Vector3.new(0, -1, 0). Enemy animation/yaw can therefore never change pitch.
    local hover = Runtime.CurrentHoverHeight or desiredHeight
    local targetPos

    if Settings.PerfectDownFacing then
        -- v1.4.1: give downward combat facing exclusive ownership of rotation.
        -- This stops Humanoid/game-facing updates from restoring an upright pose
        -- between the 55 ms farm ticks and causing visible up/down oscillation.
        acquireDownFacingLock(model, humanoid)
        root.CFrame = downFacingCFrame(enemyRoot, hover)
    else
        releaseDownFacingLock()
        -- Original v1.2.7 upright/yaw-only positioning is retained as the optional
        -- fallback. Behind Distance is intentionally only used in this mode; a
        -- perfectly downward-facing character must be centered over the enemy.
        local rawForward = enemyRoot.CFrame.LookVector
        local flatForward = Vector3.new(rawForward.X, 0, rawForward.Z)
        if flatForward.Magnitude < 0.001 then
            local ownForward = root.CFrame.LookVector
            flatForward = Vector3.new(ownForward.X, 0, ownForward.Z)
        end
        if flatForward.Magnitude < 0.001 then
            flatForward = Vector3.new(0, 0, -1)
        else
            flatForward = flatForward.Unit
        end

        local behind = -flatForward * (tonumber(Settings.BehindDistance) or 3)
        targetPos = enemyRoot.Position
            + Vector3.new(0, hover, 0)
            + behind

        local planarToEnemy = Vector3.new(
            enemyRoot.Position.X - targetPos.X,
            0,
            enemyRoot.Position.Z - targetPos.Z
        )
        local faceDir = planarToEnemy.Magnitude > 0.001 and planarToEnemy.Unit or flatForward
        root.CFrame = CFrame.lookAt(
            targetPos,
            targetPos + faceDir,
            Vector3.new(0, 1, 0)
        )
    end
    if Settings.AntiStuck then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    return true
end

local function setAutoSwing(enabled, force)
    enabled = enabled == true
    -- SetAutoSwingEnabled can have controller-side setup/facing side effects. Do
    -- not re-run it every 55 ms when the requested state has not changed.
    if not force and Runtime.AutoSwingState == enabled then return end
    Runtime.AutoSwingState = enabled
    if Controllers.Combat and type(Controllers.Combat.SetAutoSwingEnabled) == "function" then
        safe(Controllers.Combat.SetAutoSwingEnabled, Controllers.Combat, enabled)
    end
end

local stackAmount -- forward declaration; assigned in the skill/economy section below

-- Inventory ---------------------------------------------------------------------
local function inventoryWindow()
    local windows = Controllers.UI and Controllers.UI.Windows
    return windows and windows.Inventory
end

local function bestEquipmentBySlot()
    local inv = inventoryWindow()
    local best = {}
    if not inv or type(inv.Items) ~= "table" then return best end
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data then
            local rarity = tonumber(entry.info.rarity) or 1
            local slot = D.Items.IdToSlot and D.Items:IdToSlot(entry.id) or nil
            local canUse = true
            if inv.IsEntryWorldUnlocked then
                canUse = safe(inv.IsEntryWorldUnlocked, inv, entry) ~= false
            end
            if slot and canUse and rarity ~= 1002 then
                local score = tonumber(entry.powerScore) or 0
                if not best[slot] or score > best[slot].score then
                    best[slot] = {key = key, entry = entry, score = score}
                end
            end
        end
    end
    return best
end

local function autoEquipBest()
    local inv = inventoryWindow()
    if not inv or not E.Inventory then return end
    local best = bestEquipmentBySlot()
    for slot, picked in pairs(best) do
        local current = inv.Equipped and inv.Equipped[slot]
        local currentKey = type(current) == "table" and current.key or nil
        if currentKey ~= picked.key then
            if type(inv.Equip) == "function" then
                safe(inv.Equip, inv, picked.key, true)
            else
                E.Inventory:FireServer("e", picked.key)
            end
            task.wait(0.13)
        end
    end
end

Runtime.RefreshPlayerBank = function(force)
    if not force and Runtime.PlayerBankState and now() - (Runtime.PlayerBankLastRefresh or 0) < 30 then
        return Runtime.PlayerBankState
    end
    local bankFunc = func("GetPlayerBank")
    if not bankFunc then return Runtime.PlayerBankState end
    local result = safe(bankFunc.InvokeServer, bankFunc)
    if type(result) == "table" then
        Runtime.PlayerBankState = type(result.Bank) == "table" and result.Bank or Runtime.PlayerBankState
        Runtime.PlayerBankCapacity = tonumber(result.Capacity) or Runtime.PlayerBankCapacity or 750
        Runtime.PlayerBankLastRefresh = now()
    end
    return Runtime.PlayerBankState
end

Runtime.AutoWithdrawVariantBankTick = function()
    if not Settings.AutoRetrieveVariantBank or not Settings.AutoVariantUpgrade then return false end
    if now() - (Runtime.PlayerBankLastWithdraw or 0) < 5 then return false end
    local withdraw = func("WithdrawPlayerBankItems")
    if not withdraw then return false end
    local inv = inventoryWindow()
    if not inv or type(inv.Items) ~= "table" then return false end

    local inventoryCount = 0
    for _, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" then inventoryCount = inventoryCount + 1 end
    end
    local ownedPasses = tableData("OwnedPasses")
    local maxSpace = tonumber(inv.MaxSpace)
    if type(D.InventoryCapacity.GetMax) == "function" then
        maxSpace = tonumber(safe(D.InventoryCapacity.GetMax, D.InventoryCapacity, ownedPasses)) or maxSpace
    end
    maxSpace = math.max(1, maxSpace or tonumber(D.InventoryCapacity.Base) or 750)
    local free = maxSpace - inventoryCount
    if free < 1 then return false end

    local minRarity = equipmentRarityNames[Settings.VariantMinRarity] or 4
    local targetIds = {}
    for _, picked in pairs(bestEquipmentBySlot()) do
        if picked.entry and picked.entry.id and picked.entry.info
            and (tonumber(picked.entry.info.rarity) or 0) >= minRarity then
            local meta = picked.entry.data and picked.entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant ~= "Shiny" then targetIds[picked.entry.id] = true end
        end
    end
    if next(targetIds) == nil then return false end

    local counts = {}
    for id in pairs(targetIds) do counts[id] = {Normal = 0, Golden = 0} end
    for _, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.id and counts[entry.id]
            and entry.data and entry.data.lock ~= true and entry.equipped ~= true and entry.cosmeticEquipped ~= true then
            local meta = entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant == "Golden" then counts[entry.id].Golden = counts[entry.id].Golden + 1
            elseif variant ~= "Shiny" then counts[entry.id].Normal = counts[entry.id].Normal + 1 end
        end
    end

    local bank = Runtime.RefreshPlayerBank(true)
    if type(bank) ~= "table" or type(bank.Equipment) ~= "table" then return false end
    local byId = {}
    for uid, data in pairs(bank.Equipment) do
        if type(data) == "table" and data.id and counts[data.id] and data.lock ~= true then
            local meta = data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant ~= "Shiny" then
                local row = byId[data.id] or {Normal = {}, Golden = {}}
                byId[data.id] = row
                if variant == "Golden" then row.Golden[#row.Golden + 1] = tostring(uid)
                else row.Normal[#row.Normal + 1] = tostring(uid) end
            end
        end
    end

    local uids = {}
    local cap = math.min(free, 25)
    for id, count in pairs(counts) do
        if #uids >= cap then break end
        local bankRows = byId[id]
        if bankRows then
            local goldenNeed = math.max(0, 5 - count.Golden)
            local takeGolden = math.min(goldenNeed, #bankRows.Golden, cap - #uids)
            for i = 1, takeGolden do uids[#uids + 1] = bankRows.Golden[i] end
            local projectedGoldens = count.Golden + takeGolden
            local normalGoal = math.max(0, (5 - projectedGoldens) * 5)
            local normalNeed = math.max(0, normalGoal - count.Normal)
            local takeNormal = math.min(normalNeed, #bankRows.Normal, cap - #uids)
            for i = 1, takeNormal do uids[#uids + 1] = bankRows.Normal[i] end
        end
    end
    if #uids == 0 then return false end

    local result = safe(withdraw.InvokeServer, withdraw, {Equipment = uids, Stacks = {}})
    Runtime.PlayerBankLastWithdraw = now()
    if type(result) == "table" then
        if type(result.Bank) == "table" then Runtime.PlayerBankState = result.Bank end
        Runtime.PlayerBankCapacity = tonumber(result.Capacity) or Runtime.PlayerBankCapacity
        Runtime.PlayerBankLastRefresh = now()
        return result.Success ~= false
    end
    return false
end

Runtime.AutoBankOverflowTick = function()
    if not Settings.AutoBankOverflow or now() - (Runtime.PlayerBankLastDeposit or 0) < 4 then return false end
    local inv = inventoryWindow()
    if not inv or type(inv.Items) ~= "table" then return false end

    local inventoryCount = 0
    for _, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" then inventoryCount = inventoryCount + 1 end
    end
    local ownedPasses = tableData("OwnedPasses")
    local maxSpace = tonumber(inv.MaxSpace)
    if type(D.InventoryCapacity.GetMax) == "function" then
        maxSpace = tonumber(safe(D.InventoryCapacity.GetMax, D.InventoryCapacity, ownedPasses)) or maxSpace
    end
    maxSpace = math.max(1, maxSpace or tonumber(D.InventoryCapacity.Base) or 750)
    local trigger = math.clamp((tonumber(Settings.AutoBankAt) or 86) / 100, 0.70, 0.98)
    if inventoryCount / maxSpace < trigger then return false end

    local bank = Runtime.RefreshPlayerBank(false)
    if type(bank) ~= "table" then return false end
    local bankCount = 0
    if type(bank.Equipment) == "table" then
        for _, value in pairs(bank.Equipment) do if value ~= nil then bankCount = bankCount + 1 end end
    end
    if type(bank.Stacks) == "table" then
        for _, value in pairs(bank.Stacks) do
            local amount = type(value) == "table" and tonumber(value.amount) or tonumber(value)
            if (amount or 0) > 0 then bankCount = bankCount + 1 end
        end
    end
    local bankFree = math.max(0, (tonumber(Runtime.PlayerBankCapacity) or 750) - bankCount)
    if bankFree <= 0 then return false end

    local protected = {}
    local best = bestEquipmentBySlot()
    local variantTargetIds = {}
    for _, picked in pairs(best) do
        protected[picked.key] = true
        if picked.entry and picked.entry.id then
            local meta = picked.entry.data and picked.entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant ~= "Shiny" then variantTargetIds[picked.entry.id] = true end
        end
    end

    local bySlot, bestById = {}, {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data then
            local slot = D.Items.IdToSlot and D.Items:IdToSlot(entry.id) or "Unknown"
            bySlot[slot] = bySlot[slot] or {}
            local score = tonumber(entry.powerScore) or 0
            bySlot[slot][#bySlot[slot] + 1] = {key=key, score=score}
            if entry.id and (not bestById[entry.id] or score > bestById[entry.id].score) then
                bestById[entry.id] = {key=key, score=score}
            end
        end
    end
    for _, list in pairs(bySlot) do
        table.sort(list, function(a,b) return a.score > b.score end)
        for i = 1, math.min(#list, math.max(0, tonumber(Settings.KeepSpareBest) or 0) + 1) do
            protected[list[i].key] = true
        end
    end
    for _, row in pairs(bestById) do protected[row.key] = true end

    if Settings.AutoVariantUpgrade and type(D.ItemVariants.GetUpgradeTarget) == "function" then
        local buckets = {}
        local minVariantRarity = equipmentRarityNames[Settings.VariantMinRarity] or 4
        for key, entry in pairs(inv.Items) do
            if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data
                and variantTargetIds[entry.id] and entry.data.lock ~= true and entry.equipped ~= true
                and entry.cosmeticEquipped ~= true and (tonumber(entry.info.rarity) or 0) >= minVariantRarity
                and (tonumber(entry.info.rarity) or 0) < 999 then
                local meta = entry.data.meta or {}
                local variant = type(D.ItemVariants.Normalize) == "function"
                    and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
                if safe(D.ItemVariants.GetUpgradeTarget, D.ItemVariants, variant) then
                    local bucketKey = tostring(entry.id) .. "|" .. tostring(variant or "Normal")
                    buckets[bucketKey] = buckets[bucketKey] or {variant = variant, items = {}}
                    buckets[bucketKey].items[#buckets[bucketKey].items + 1] = {key=key, score=tonumber(entry.powerScore) or 0}
                end
            end
        end
        local needed = tonumber(D.ItemVariants.UpgradeInputCount) or 5
        for _, bucket in pairs(buckets) do
            local list = bucket.items or {}
            table.sort(list, function(a,b) return a.score < b.score end)
            -- One Shiny requires five Goldens = 25 Normal-equivalent copies.
            -- Preserve enough un-equipped duplicates to finish the full chain instead
            -- of banking copies 6-25 after the first Golden craft.
            local keep = bucket.variant == "Golden" and needed or (needed * needed)
            for i = 1, math.min(keep, #list) do protected[list[i].key] = true end
        end
    end

    local threshold = equipmentRarityNames[Settings.SellBelow] or 3
    local candidates = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data
            and not protected[key] and entry.data.lock ~= true and entry.equipped ~= true
            and entry.cosmeticEquipped ~= true then
            local rarity = tonumber(entry.info.rarity) or 1
            if rarity >= threshold and rarity < 999 then
                candidates[#candidates + 1] = {key=key, rarity=rarity, score=tonumber(entry.powerScore) or 0}
            end
        end
    end
    if #candidates == 0 then return false end
    table.sort(candidates, function(a,b)
        if a.rarity ~= b.rarity then return a.rarity < b.rarity end
        return a.score < b.score
    end)

    local targetSpace = math.floor(maxSpace * math.max(0.65, trigger - 0.07))
    local wanted = math.max(1, inventoryCount - targetSpace)
    local count = math.min(#candidates, bankFree, wanted, 35)
    if count <= 0 then return false end
    local uids = {}
    for i = 1, count do uids[#uids + 1] = candidates[i].key end

    local deposit = func("DepositPlayerBankItems")
    if not deposit then return false end
    local result = safe(deposit.InvokeServer, deposit, {Equipment=uids, Stacks={}})
    Runtime.PlayerBankLastDeposit = now()
    if type(result) == "table" then
        if type(result.Bank) == "table" then Runtime.PlayerBankState = result.Bank end
        Runtime.PlayerBankCapacity = tonumber(result.Capacity) or Runtime.PlayerBankCapacity
        Runtime.PlayerBankLastRefresh = now()
        return result.Success ~= false
    end
    return false
end

local function autoSellJunk()
    local inv = inventoryWindow()
    if not inv or not E.Inventory or type(inv.Items) ~= "table" then return end
    local threshold = equipmentRarityNames[Settings.SellBelow] or 3
    local protected = {}
    local best = bestEquipmentBySlot()
    local variantTargetIds = {}
    for _, picked in pairs(best) do
        protected[picked.key] = true
        if picked.entry and picked.entry.id then
            local meta = picked.entry.data and picked.entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant ~= "Shiny" then variantTargetIds[picked.entry.id] = true end
        end
    end

    if Settings.AutoVariantUpgrade then
        local minVariantRarity = equipmentRarityNames[Settings.VariantMinRarity] or 4
        local variantBuckets = {}
        for key, entry in pairs(inv.Items) do
            if type(entry) == "table"
                and entry.type == "Equipment"
                and entry.info
                and entry.data
                and variantTargetIds[entry.id]
                and entry.data.lock ~= true
                and entry.equipped ~= true
                and entry.cosmeticEquipped ~= true
                and (tonumber(entry.info.rarity) or 0) >= minVariantRarity
                and (tonumber(entry.info.rarity) or 0) < 999 then

                local meta = entry.data.meta or {}
                local variant = type(D.ItemVariants.Normalize) == "function"
                    and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
                if safe(D.ItemVariants.GetUpgradeTarget, D.ItemVariants, variant) then
                    local bucket = tostring(entry.id) .. "|" .. tostring(variant or "Normal")
                    variantBuckets[bucket] = variantBuckets[bucket] or {variant = variant, items = {}}
                    table.insert(variantBuckets[bucket].items, {key=key, score=tonumber(entry.powerScore) or 0})
                end
            end
        end
        local needed = tonumber(D.ItemVariants.UpgradeInputCount) or 5
        for _, bucket in pairs(variantBuckets) do
            local list = bucket.items or {}
            table.sort(list, function(a,b) return a.score < b.score end)
            local keep = bucket.variant == "Golden" and needed or (needed * needed)
            for i = 1, math.min(keep, #list) do
                protected[list[i].key] = true
            end
        end
    end

    local bySlot = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data then
            local slot = D.Items.IdToSlot and D.Items:IdToSlot(entry.id) or "Unknown"
            bySlot[slot] = bySlot[slot] or {}
            table.insert(bySlot[slot], {key = key, entry = entry, score = tonumber(entry.powerScore) or 0})
        end
    end
    for _, list in pairs(bySlot) do
        table.sort(list, function(a, b) return a.score > b.score end)
        for i = 1, math.min(#list, math.max(0, tonumber(Settings.KeepSpareBest) or 0) + 1) do
            protected[list[i].key] = true
        end
    end

    -- Keep the strongest copy of every distinct equipment id. Emergency cleanup
    -- can therefore free bulk duplicates without destroying a collection piece.
    local bestByItemId = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data and entry.id then
            local score = tonumber(entry.powerScore) or 0
            local old = bestByItemId[entry.id]
            if not old or score > old.score then bestByItemId[entry.id] = {key = key, score = score} end
        end
    end
    for _, row in pairs(bestByItemId) do protected[row.key] = true end

    local sell = {}
    local sellSet = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data then
            local rarity = tonumber(entry.info.rarity) or 1
            local special = rarity >= 999
            local locked = entry.data.lock == true
            local equipped = entry.equipped == true or entry.cosmeticEquipped == true
            if not special and not locked and not equipped and not protected[key] and rarity < threshold then
                sell[#sell + 1] = key
                sellSet[key] = true
                if #sell >= 60 then break end
            end
        end
    end
    if Settings.EmergencyInventoryCleanup and #sell < 60 then
        local space = 0
        for _, entry in pairs(inv.Items) do
            if type(entry) == "table" and entry.type == "Equipment" then space = space + 1 end
        end
        local ownedPasses = tableData("OwnedPasses")
        local maxSpace = tonumber(inv.MaxSpace)
        if type(D.InventoryCapacity.GetMax) == "function" then
            maxSpace = tonumber(safe(D.InventoryCapacity.GetMax, D.InventoryCapacity, ownedPasses)) or maxSpace
        end
        maxSpace = math.max(1, maxSpace or tonumber(D.InventoryCapacity.Base) or 750)
        local trigger = math.clamp((tonumber(Settings.InventoryCleanupAt) or 92) / 100, 0.75, 0.99)
        if space / maxSpace >= trigger then
            local emergency = {}
            for key, entry in pairs(inv.Items) do
                if type(entry) == "table" and entry.type == "Equipment" and entry.info and entry.data
                    and not sellSet[key] and not protected[key]
                    and entry.data.lock ~= true
                    and entry.equipped ~= true and entry.cosmeticEquipped ~= true
                    and (tonumber(entry.info.rarity) or 0) < 999 then
                    emergency[#emergency + 1] = {
                        key = key, rarity = tonumber(entry.info.rarity) or 0,
                        score = tonumber(entry.powerScore) or 0,
                    }
                end
            end
            table.sort(emergency, function(a, b)
                if a.rarity ~= b.rarity then return a.rarity < b.rarity end
                return a.score < b.score
            end)
            local targetSpace = math.floor(maxSpace * math.max(0.70, trigger - 0.08))
            local needed = math.max(0, space - targetSpace)
            for i = 1, math.min(#emergency, needed, 60 - #sell) do
                sell[#sell + 1] = emergency[i].key
                sellSet[emergency[i].key] = true
            end
            Runtime.InventorySpace = space
            Runtime.InventoryMaxSpace = maxSpace
            Runtime.InventoryEmergencyCleanup = needed > 0
        else
            Runtime.InventorySpace = space
            Runtime.InventoryMaxSpace = maxSpace
            Runtime.InventoryEmergencyCleanup = false
        end
    end

    if #sell > 0 then
        E.Inventory:FireServer("s", sell)
    end
end


local function variantUpgradeCandidate()
    if not Settings.AutoVariantUpgrade or type(D.ItemVariants.GetUpgradeTarget) ~= "function" then
        return nil
    end
    local inv = inventoryWindow()
    if not inv or type(inv.Items) ~= "table" then return nil end
    local protected = {}
    local targetIds = {}
    for _, picked in pairs(bestEquipmentBySlot()) do
        protected[picked.key] = true
        if picked.entry and picked.entry.id then
            local meta = picked.entry.data and picked.entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant ~= "Shiny" then
                targetIds[picked.entry.id] = true
            end
        end
    end

    local minRarity = equipmentRarityNames[Settings.VariantMinRarity] or 4
    local groups = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table"
            and entry.type == "Equipment"
            and entry.info
            and entry.data
            and targetIds[entry.id] == true
            and not protected[key]
            and entry.data.lock ~= true
            and entry.equipped ~= true
            and entry.cosmeticEquipped ~= true
            and (tonumber(entry.info.rarity) or 0) >= minRarity
            and (tonumber(entry.info.rarity) or 0) < 999 then

            local meta = entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            local target = safe(D.ItemVariants.GetUpgradeTarget, D.ItemVariants, variant)
            if target then
                local groupKey = tostring(entry.id) .. "|" .. tostring(variant or "Normal")
                groups[groupKey] = groups[groupKey] or {
                    id = entry.id,
                    variant = variant,
                    items = {},
                    info = entry.info,
                }
                table.insert(groups[groupKey].items, {
                    key = key,
                    entry = entry,
                    score = tonumber(entry.powerScore) or 0,
                })
            end
        end
    end

    local orderedGroups = {}
    for _, group in pairs(groups) do orderedGroups[#orderedGroups + 1] = group end
    table.sort(orderedGroups, function(a, b)
        local ar = a.variant == "Golden" and 2 or 1
        local br = b.variant == "Golden" and 2 or 1
        if ar ~= br then return ar > br end
        return tostring(a.id) < tostring(b.id)
    end)
    for _, group in ipairs(orderedGroups) do
        if #group.items >= (tonumber(D.ItemVariants.UpgradeInputCount) or 5) then
            table.sort(group.items, function(a,b) return a.score < b.score end)
            local needed = tonumber(D.ItemVariants.UpgradeInputCount) or 5
            local uids, dataList = {}, {}
            for i = 1, needed do
                local row = group.items[i]
                uids[#uids+1] = row.key
                dataList[#dataList+1] = row.entry.data
            end

            local surcharge = 0
            if type(D.ItemVariants.GetEquipmentQualitySurcharge) == "function" then
                surcharge = tonumber(safe(D.ItemVariants.GetEquipmentQualitySurcharge, D.ItemVariants, dataList, group.info)) or 0
            end
            local _, recipe = safe(D.ItemVariants.GetUpgradeRecipe, D.ItemVariants, group.id, group.variant, surcharge)
            if type(recipe) == "table" then
                local hasMaterials = true
                for _, mat in ipairs(recipe) do
                    if type(mat) == "table" and stackAmount(mat.id) < (tonumber(mat.amount) or 0) then
                        hasMaterials = false
                        break
                    end
                end
                if hasMaterials then
                    return uids
                end
            end
        end
    end
    return nil
end

-- Pet variants use the same 5-copy recipe. The server preserves level/EXP from
-- the first input pet, so always put the most progressed duplicate first. Only
-- families currently equipped by the smart pet selector are upgraded automatically.
Runtime.PetVariantUpgradeCandidate = function()
    if not Settings.AutoVariantUpgrade or type(D.ItemVariants.GetUpgradeTarget) ~= "function" then return nil end
    local inv = inventoryWindow()
    if not inv or type(inv.Items) ~= "table" then return nil end
    local save = tableData("Pets")
    local owned = type(save.Owned) == "table" and save.Owned or {}
    local targetIds = {}
    local equippedUids = {}
    if save.Equipped then equippedUids[tostring(save.Equipped)] = true end
    if save.EquippedSecondary then equippedUids[tostring(save.EquippedSecondary)] = true end
    for uid in pairs(equippedUids) do
        local data = owned[uid] or owned[tonumber(uid)]
        if type(data) == "table" and data.id then
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, data.variant) or data.variant
            if variant ~= "Shiny" then targetIds[data.id] = true end
        end
    end
    if next(targetIds) == nil then return nil end

    local groups = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.type == "Pet" and entry.data and entry.id
            and targetIds[entry.id] == true and entry.data.lock ~= true then
            local uid = tostring(entry.petUid or key)
            if not equippedUids[uid] then
                local variant = type(D.ItemVariants.Normalize) == "function"
                    and safe(D.ItemVariants.Normalize, D.ItemVariants, entry.data.variant) or entry.data.variant
                if safe(D.ItemVariants.GetUpgradeTarget, D.ItemVariants, variant) then
                    local groupKey = tostring(entry.id) .. "|" .. tostring(variant or "Normal")
                    groups[groupKey] = groups[groupKey] or {id = entry.id, variant = variant, items = {}}
                    groups[groupKey].items[#groups[groupKey].items + 1] = {
                        uid = uid, level = tonumber(entry.data.level) or 1,
                        exp = tonumber(entry.data.exp or entry.data.Exp) or 0,
                    }
                end
            end
        end
    end

    local needed = tonumber(D.ItemVariants.UpgradeInputCount) or 5
    local orderedGroups = {}
    for _, group in pairs(groups) do orderedGroups[#orderedGroups + 1] = group end
    table.sort(orderedGroups, function(a, b)
        local ar = a.variant == "Golden" and 2 or 1
        local br = b.variant == "Golden" and 2 or 1
        if ar ~= br then return ar > br end
        return tostring(a.id) < tostring(b.id)
    end)
    for _, group in ipairs(orderedGroups) do
        if #group.items >= needed then
            table.sort(group.items, function(a, b)
                if a.level ~= b.level then return a.level > b.level end
                return a.exp > b.exp
            end)
            local _, recipe = safe(D.ItemVariants.GetUpgradeRecipe, D.ItemVariants, tostring(group.id), group.variant, 0)
            local hasMaterials = type(recipe) == "table"
            if hasMaterials then
                for _, mat in ipairs(recipe) do
                    if type(mat) == "table" and stackAmount(mat.id) < (tonumber(mat.amount) or 0) then
                        hasMaterials = false
                        break
                    end
                end
            end
            if hasMaterials then
                local uids = {group.items[1].uid}
                for i = 2, needed do uids[#uids + 1] = group.items[i].uid end
                return uids
            end
        end
    end
    return nil
end

Runtime.GetVariantMaterialNeeds = function()
    local needs = {Normal = 0, Rare = 0, VeryRare = 0}
    if type(D.ItemVariants.GetUpgradeTarget) ~= "function" or type(D.ItemVariants.GetUpgradeRecipe) ~= "function" then
        return needs
    end
    local inv = inventoryWindow()
    if not inv or type(inv.Items) ~= "table" then return needs end
    local inputCount = tonumber(D.ItemVariants.UpgradeInputCount) or 5
    local normalSet, rareSet, verySet = {}, {}, {}
    for _, id in ipairs(type(D.ItemVariants.UpgradeMaterialGroups) == "table" and D.ItemVariants.UpgradeMaterialGroups.Normal or {}) do normalSet[id] = true end
    for _, id in ipairs(type(D.ItemVariants.UpgradeMaterialGroups) == "table" and D.ItemVariants.UpgradeMaterialGroups.Rare or {}) do rareSet[id] = true end
    for _, id in ipairs(type(D.ItemVariants.UpgradeMaterialGroups) == "table" and D.ItemVariants.UpgradeMaterialGroups.VeryRare or {}) do verySet[id] = true end

    local targetIds = {}
    for _, picked in pairs(bestEquipmentBySlot()) do
        if picked.entry and picked.entry.id then
            local meta = picked.entry.data and picked.entry.data.meta or {}
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
            if variant ~= "Shiny" then
                targetIds[picked.entry.id] = {type = "Equipment", info = picked.entry.info}
            end
        end
    end
    local petSave = tableData("Pets")
    local petOwned = type(petSave.Owned) == "table" and petSave.Owned or {}
    for _, uid in ipairs({petSave.Equipped, petSave.EquippedSecondary}) do
        local data = uid and (petOwned[tostring(uid)] or petOwned[tonumber(uid)]) or nil
        if type(data) == "table" and data.id then
            local variant = type(D.ItemVariants.Normalize) == "function"
                and safe(D.ItemVariants.Normalize, D.ItemVariants, data.variant) or data.variant
            if variant ~= "Shiny" then targetIds[data.id] = {type = "Pet"} end
        end
    end

    local groups = {}
    for key, entry in pairs(inv.Items) do
        if type(entry) == "table" and entry.id and entry.data and targetIds[entry.id]
            and entry.data.lock ~= true and entry.equipped ~= true and entry.cosmeticEquipped ~= true then
            local kind = entry.type
            if kind == "Equipment" or kind == "Pet" then
                local variant
                if kind == "Pet" then
                    variant = type(D.ItemVariants.Normalize) == "function" and safe(D.ItemVariants.Normalize, D.ItemVariants, entry.data.variant) or entry.data.variant
                else
                    local meta = entry.data.meta or {}
                    variant = type(D.ItemVariants.Normalize) == "function" and safe(D.ItemVariants.Normalize, D.ItemVariants, meta.variant) or meta.variant
                end
                if safe(D.ItemVariants.GetUpgradeTarget, D.ItemVariants, variant) then
                    local groupKey = tostring(kind) .. "|" .. tostring(entry.id) .. "|" .. tostring(variant or "Normal")
                    local group = groups[groupKey]
                    if not group then
                        group = {kind = kind, id = entry.id, variant = variant, items = {}, info = entry.info}
                        groups[groupKey] = group
                    end
                    group.items[#group.items + 1] = {key = key, entry = entry}
                end
            end
        end
    end

    for _, group in pairs(groups) do
        if #group.items >= inputCount then
            local surcharge = 0
            if group.kind == "Equipment" and type(D.ItemVariants.GetEquipmentQualitySurcharge) == "function" then
                local dataList = {}
                for i = 1, inputCount do dataList[i] = group.items[i].entry.data end
                surcharge = tonumber(safe(D.ItemVariants.GetEquipmentQualitySurcharge, D.ItemVariants, dataList, group.info)) or 0
            end
            local _, recipe = safe(D.ItemVariants.GetUpgradeRecipe, D.ItemVariants, tostring(group.id), group.variant, surcharge)
            for _, mat in ipairs(type(recipe) == "table" and recipe or {}) do
                if type(mat) == "table" and mat.id then
                    local missing = math.max(0, (tonumber(mat.amount) or 0) - stackAmount(mat.id))
                    if normalSet[mat.id] then needs.Normal = needs.Normal + missing
                    elseif rareSet[mat.id] then needs.Rare = needs.Rare + missing
                    elseif verySet[mat.id] then needs.VeryRare = needs.VeryRare + missing end
                end
            end
        end
    end
    return needs
end

local function autoVariantUpgrade()
    local f = func("VariantUpgrade")
    if not f then return false end
    local uids = variantUpgradeCandidate() or Runtime.PetVariantUpgradeCandidate()
    if not uids then return false end
    safe(f.InvokeServer, f, {uids = uids})
    return true
end

local function equippedForgeCandidates()
    local inv = inventoryWindow()
    local out = {}
    if not inv or type(inv.Equipped) ~= "table" then return out end
    for _, entry in pairs(inv.Equipped) do
        if type(entry) == "table" and entry.key and entry.data and entry.info then
            out[#out + 1] = entry
        end
    end
    table.sort(out, function(a, b)
        local al = tonumber(a.data.meta and a.data.meta.level) or 0
        local bl = tonumber(b.data.meta and b.data.meta.level) or 0
        if al ~= bl then return al < bl end
        return (tonumber(a.powerScore) or 0) > (tonumber(b.powerScore) or 0)
    end)
    return out
end

local function stageForgeCost(dataModule, entry, currentLevel)
    local rarity = tonumber(entry.info and entry.info.rarity) or 1
    if type(dataModule.GetCost) == "function" then
        local a, b = safe(dataModule.GetCost, dataModule, rarity, currentLevel)
        return math.ceil(tonumber(a) or 0), math.ceil(tonumber(b) or 0)
    end
    return 0, 0
end

Runtime.GetEffectiveForgeChance = function(stageData, level, isMagic)
    if type(stageData) ~= "table" or type(stageData.GetForgeChance) ~= "function" then return 0 end
    local chance = tonumber(safe(stageData.GetForgeChance, stageData, level)) or 0
    if Runtime.OwnsPermanentPass and Runtime.OwnsPermanentPass(3475770883) then
        chance = chance * 1.5
    end

    local runes = tableData("Runes")
    for _, runeId in pairs(runes) do
        local rune = type(D.RunesData.All) == "table" and D.RunesData.All[runeId] or nil
        if type(rune) == "table" and type(rune.effects) == "table" then
            chance = chance + (tonumber(rune.effects.ForgeLuck) or 0)
        end
    end

    local race = tostring(getData("Race") or "")
    if race == "dwarf" then chance = chance + 0.10 end
    if isMagic and race == "wizard" then chance = chance + 0.10 end
    return math.clamp(chance, 0, 1)
end

local function autoForge()
    local target = math.clamp(tonumber(Settings.ForgeTarget) or 10, 1, 15)
    local reserveGold, reserveShards
    if Runtime.GetMajorCurrencyReserve then
        reserveGold, reserveShards = Runtime.GetMajorCurrencyReserve()
    else
        reserveGold, reserveShards = reserveForNextWorld()
    end

    for _, entry in ipairs(equippedForgeCandidates()) do
        local level = tonumber(entry.data.meta and entry.data.meta.level) or 0
        if level < target then
            local stageData = level < 6 and D.ForgeData or (level < 10 and D.MagicForgeData or D.ExpertForgeData)
            local chance = Runtime.GetEffectiveForgeChance(stageData, level, level >= 6 and level < 10)
            local useProtection = Settings.ForgeProtection == true
            if not useProtection and Settings.SmartForgeProtection == true then
                useProtection = chance < math.clamp((tonumber(Settings.ForgeProtectionBelow) or 45) / 100, 0, 1)
            end
            useProtection = useProtection and stackAmount and stackAmount("st_3") > 0

            if level < 6 then
                if not E.Forge then return end
                local goldCost, shardCost = stageForgeCost(D.ForgeData, entry, level)
                if numData("Gold") - goldCost >= reserveGold
                    and numData("Shards") - shardCost >= reserveShards then
                    E.Forge:FireServer(entry.key, useProtection == true)
                end
                return
            elseif level < 10 then
                if not E.MagicForge then return end
                local goldCost, shardCost = stageForgeCost(D.MagicForgeData, entry, level)
                if numData("Gold") - goldCost >= reserveGold
                    and numData("Shards") - shardCost >= reserveShards then
                    E.MagicForge:FireServer(entry.key, useProtection == true)
                end
                return
            else
                if not E.ExpertForge then return end
                local forgeShardCost = stageForgeCost(D.ExpertForgeData, entry, level)
                if stackAmount and stackAmount("st_9") >= forgeShardCost then
                    E.ExpertForge:FireServer(entry.key, useProtection == true)
                end
                return
            end
        end
    end
end

-- Stats / trees / skills ---------------------------------------------------------
local function normalizedStatPoints()
    local raw = tableData("StatPoints")
    if type(D.Leveling.GetNormalizedStatPoints) == "function" then
        local result = safe(D.Leveling.GetNormalizedStatPoints, D.Leveling, raw)
        if type(result) == "table" then return result end
    end
    return {Damage = tonumber(raw.Damage) or 0, Defence = tonumber(raw.Defence) or 0, Health = tonumber(raw.Health) or 0}
end

local function availableStatPoints()
    local level = numData("Level")
    local stats = normalizedStatPoints()
    if type(D.Leveling.GetAvailableStatPoints) == "function" then
        return tonumber(safe(D.Leveling.GetAvailableStatPoints, D.Leveling, level, stats)) or 0
    end
    local spent = (stats.Damage or 0) + (stats.Defence or 0) + (stats.Health or 0)
    return math.max(0, (level - 1) * 4 - spent)
end

local function autoSpendStats()
    if not E.StatChange then return end
    local points = math.floor(availableStatPoints())
    if points <= 0 then return end

    local stats = normalizedStatPoints()
    local currentDamage = math.max(0, tonumber(stats.Damage) or 0)
    local currentDefence = math.max(0, tonumber(stats.Defence) or 0)
    local currentHealth = math.max(0, tonumber(stats.Health) or 0)
    local totalAfter = currentDamage + currentDefence + currentHealth + points

    local damageRatio, defenceRatio, healthRatio
    if Settings.StatBuild == "Damage" then
        damageRatio, defenceRatio, healthRatio = 1.00, 0.00, 0.00
    elseif Settings.StatBuild == "Survival" then
        damageRatio, defenceRatio, healthRatio = 0.25, 0.40, 0.35
    elseif Settings.StatBuild == "Balanced" then
        damageRatio, defenceRatio, healthRatio = 0.60, 0.20, 0.20
    else
        -- Smart is deliberately damage-heavy because the farm fights from above.
        -- Real deaths temporarily move future points toward survival, and Dungeon /
        -- Tower content gets a little more baseline durability than World Farm.
        local recentDeaths = 0
        local cutoff = now() - 240
        for i = #Runtime.RecentCombatDeaths, 1, -1 do
            local at = tonumber(Runtime.RecentCombatDeaths[i]) or 0
            if at < cutoff then
                table.remove(Runtime.RecentCombatDeaths, i)
            else
                recentDeaths = recentDeaths + 1
            end
        end
        if recentDeaths >= 2 then
            damageRatio, defenceRatio, healthRatio = 0.60, 0.23, 0.17
        elseif Runtime.Activity == "Dungeon" or Runtime.Activity == "Tower" or Runtime.Activity == "LiveEvent" then
            damageRatio, defenceRatio, healthRatio = 0.72, 0.16, 0.12
        else
            damageRatio, defenceRatio, healthRatio = 0.82, 0.10, 0.08
        end
    end

    local desiredDamage = math.floor(totalAfter * damageRatio + 0.5)
    local desiredDefence = math.floor(totalAfter * defenceRatio + 0.5)
    local desiredHealth = math.max(0, totalAfter - desiredDamage - desiredDefence)
    local deficits = {
        Damage = math.max(0, desiredDamage - currentDamage),
        Defence = math.max(0, desiredDefence - currentDefence),
        Health = math.max(0, desiredHealth - currentHealth),
    }
    local allocated = {Damage = 0, Defence = 0, Health = 0}
    local remaining = points

    while remaining > 0 do
        local bestStat, bestDeficit = "Damage", -1
        for _, stat in ipairs({"Damage", "Defence", "Health"}) do
            if deficits[stat] > bestDeficit then
                bestStat, bestDeficit = stat, deficits[stat]
            end
        end
        if bestDeficit <= 0 then
            allocated.Damage = allocated.Damage + remaining
            remaining = 0
        else
            local amount = math.min(remaining, bestDeficit)
            allocated[bestStat] = allocated[bestStat] + amount
            deficits[bestStat] = deficits[bestStat] - amount
            remaining = remaining - amount
        end
    end

    if allocated.Damage > 0 then E.StatChange:FireServer("a", "Damage", allocated.Damage) task.wait(0.08) end
    if allocated.Defence > 0 then E.StatChange:FireServer("a", "Defence", allocated.Defence) task.wait(0.08) end
    if allocated.Health > 0 then E.StatChange:FireServer("a", "Health", allocated.Health) end
end

local function standardTreeOwned(nodeId)
    local state = tableData("SkillTree")
    if state[nodeId] == true then return true end
    local legacy = type(state.LegacyOwned) == "table" and state.LegacyOwned or {}
    return legacy[nodeId] == true
end

local function autoBuyStandardTree()
    if not E.SkillTree or type(D.SkillTree.Nodes) ~= "table" then return end

    -- Loot Up's current SkillTree remote is owned by PotentialTree v2. The old
    -- upgrade-tree UI used the action "Purchase", but PotentialTree only accepts
    -- Sync/OpenNode/Choose/Upgrade/Reroll. Sending legacy Purchase calls here caused
    -- eight "[PotentialTree] Purchase rejected: invalid_action" warnings every tick.
    -- Keep this legacy path dormant whenever the PotentialTree data module is active.
    if type(D.PotentialTree) == "table" and tonumber(D.PotentialTree.Version) then return end

    local sent = 0
    for _, node in ipairs(D.SkillTree.Nodes) do
        local id = node.id or node.Id
        local effect = node.effect or node.Effect
        if id and effect and not standardTreeOwned(id) then
            E.SkillTree:FireServer("Purchase", id)
            sent = sent + 1
            if sent >= 8 then return end
            task.wait(0.11)
        end
    end
end

local branchOrders = {
    ["Farming First"] = {"farming", "core", "skills", "special", "conditional", "race"},
    ["Combat First"] = {"core", "skills", "special", "conditional", "farming", "race"},
    ["Activities First"] = {"skills", "farming", "core", "special", "conditional", "race"},
    ["Race First"] = {"race", "core", "skills", "farming", "special", "conditional"},
}
local effectWeight = {
    Experience = 95, Coins = 82, LootLuck = 90, MaterialLuck = 84, VariantLuck = 78,
    Power = 96, SkillDamage = 90, SkillCooldown = 88, BossDamage = 83, EliteDamage = 76,
    TowerRewards = 80, DungeonRewards = 80, TowerDamage = 80, DungeonDamage = 80,
    PetDamage = 76, PetExperience = 66, ForgeLuck = 62, SoulCrystals = 70,
    CriticalStrike = 74, ExecutePower = 65, LifeSteal = 60, Vitality = 58, Defense = 55,
    RacePower = 95, RaceSkillPower = 92, RaceLuck = 90, RaceSpeed = 76, RaceDefense = 62,
}
local rarityWeight = {Common = 0, Rare = 80, Epic = 180, Legendary = 340, Mythic = 600}

local function scorePotentialCard(card, upgradeLevel)
    if type(card) ~= "table" then return -math.huge end
    local score = rarityWeight[card.Rarity] or 0
    local upgradeMult = 1 + math.clamp(tonumber(upgradeLevel) or 0, 0, tonumber(D.PotentialTree.MaxUpgradeLevel) or 5) * 0.05
    for _, effect in ipairs(card.Effects or {}) do
        local key = effect.Key
        local value = (tonumber(effect.Value) or 0) * upgradeMult
        score = score + (effectWeight[key] or 45) + value * 1000
    end
    return score
end

local function potentialState()
    local state = tableData("SkillTree")
    return tonumber(state.Version) == tonumber(D.PotentialTree.Version) and state or nil
end

local function choosePotentialOffer(offer)
    if not E.SkillTree or type(offer) ~= "table" or type(offer.Cards) ~= "table" then return end
    local bestIndex, bestScore = nil, -math.huge
    for i, card in ipairs(offer.Cards) do
        local upgradeLevel = 0
        if offer.Mode == "Reroll" and i == (tonumber(offer.KeepCurrentIndex) or 1) and offer.NodeId then
            local state = tableData("SkillTree")
            local nodeState = type(state.Nodes) == "table" and state.Nodes[offer.NodeId] or nil
            upgradeLevel = type(nodeState) == "table" and (tonumber(nodeState.UpgradeLevel) or 0) or 0
        end
        local score = scorePotentialCard(card, upgradeLevel)
        if score > bestScore then bestIndex, bestScore = i, score end
    end
    if bestIndex and offer.Token then
        E.SkillTree:FireServer("Choose", offer.Token, bestIndex)
        Runtime.PotentialLastChoice = now()
    end
end

local function nextPotentialNode(state)
    if type(state) ~= "table" then return nil end
    local points = tonumber(state.Points) or 0
    local nodes = type(state.Nodes) == "table" and state.Nodes or {}
    local order = branchOrders[Settings.PotentialBranch] or branchOrders["Farming First"]
    for _, branchId in ipairs(order) do
        for i = 1, 20 do
            local id = string.format("%s_%02d", branchId, i)
            local def = D.PotentialTree.NodesById and D.PotentialTree.NodesById[id]
            local owned = type(nodes[id]) == "table" and type(nodes[id].Card) == "table"
            local prevOwned = i == 1 or (type(nodes[string.format("%s_%02d", branchId, i - 1)]) == "table" and type(nodes[string.format("%s_%02d", branchId, i - 1)].Card) == "table")
            if def and not owned and prevOwned and points >= (tonumber(def.Cost) or 0) then
                return def
            end
        end
    end
    return nil
end

local function potentialUpgradeCandidate(state)
    if type(state) ~= "table" then return nil end
    local points = tonumber(state.Points) or 0
    local nodes = type(state.Nodes) == "table" and state.Nodes or {}
    local best, bestScore
    for id, entry in pairs(nodes) do
        if type(entry) == "table" and type(entry.Card) == "table" then
            local level = tonumber(entry.UpgradeLevel) or 0
            if level < (tonumber(D.PotentialTree.MaxUpgradeLevel) or 5) then
                local cost = D.PotentialTree.GetUpgradeCost and D.PotentialTree:GetUpgradeCost(level + 1) or (D.PotentialTree.UpgradeCosts and D.PotentialTree.UpgradeCosts[level + 1])
                cost = tonumber(cost) or math.huge
                if points >= cost then
                    local score = scorePotentialCard(entry.Card) - level * 5
                    if not bestScore or score > bestScore then
                        best, bestScore = id, score
                    end
                end
            end
        end
    end
    return best
end

Runtime.PotentialRerollCandidate = function(state)
    if not Settings.AutoPotentialReroll or type(state) ~= "table" or state.Awakened ~= true then return nil end
    local cost = tonumber(D.PotentialTree.RerollCost) or 5
    if (tonumber(state.Points) or 0) < cost then return nil end
    local threshold = rarityWeight[Settings.PotentialRerollMin] or rarityWeight.Epic
    local worstId, worstScore
    for id, entry in pairs(type(state.Nodes) == "table" and state.Nodes or {}) do
        if type(entry) == "table" and type(entry.Card) == "table" then
            local rarityScore = rarityWeight[entry.Card.Rarity] or 0
            if rarityScore < threshold then
                local score = scorePotentialCard(entry.Card, entry.UpgradeLevel)
                if worstScore == nil or score < worstScore then
                    worstId, worstScore = id, score
                end
            end
        end
    end
    return worstId
end

local function autoPotential()
    if not E.SkillTree then return end
    local state = potentialState()
    if not state then
        E.SkillTree:FireServer("Sync")
        return
    end
    local pending = state.PendingOffer or Runtime.PotentialOffer
    if type(pending) == "table" and pending.Token and now() - Runtime.PotentialLastChoice > 0.5 then
        choosePotentialOffer(pending)
        return
    end
    local node = nextPotentialNode(state)
    if node and now() - Runtime.PotentialLastOpen > 0.5 then
        E.SkillTree:FireServer("OpenNode", node.Id)
        Runtime.PotentialLastOpen = now()
        return
    end
    local rerollNode = Runtime.PotentialRerollCandidate(state)
    if rerollNode and now() - Runtime.PotentialLastOpen > 0.75 then
        E.SkillTree:FireServer("Reroll", rerollNode)
        Runtime.PotentialLastOpen = now()
        return
    end
    if Settings.AutoPotentialUpgrade then
        local upgrade = potentialUpgradeCandidate(state)
        if upgrade and now() - (Runtime.PotentialLastUpgrade or 0) > 0.75 then
            E.SkillTree:FireServer("Upgrade", upgrade)
            Runtime.PotentialLastUpgrade = now()
        end
    end
end

stackAmount = function(stackId)
    local inv = tableData("Inventory")
    local stacks = type(inv.Stacks) == "table" and inv.Stacks or {}
    local raw = stacks[stackId]
    if type(raw) == "table" then return tonumber(raw.amount or raw.Amount or raw.count) or 0 end
    return tonumber(raw) or 0
end


-- System-wide economy helpers ---------------------------------------------------
Runtime.GoldMerchantTargets = {
    [1] = {stack = "st_1", amount = 30, name = "Enchant Stone"},
    [2] = {stack = "st_2", amount = 8, name = "True Enchant Stone", highTarget = "enchant"},
    [3] = {stack = "st_3", amount = 30, name = "Forgeguard"},
    [4] = {stack = "st_4", amount = 30, name = "Skill Scroll"},
    [5] = {stack = "st_5", amount = 8, name = "Ancient Skill Scroll", highTarget = "skill"},
}

if E.GoldMerchant then
    connect(E.GoldMerchant.OnClientEvent, function(action, payload)
        if action == "UpdateStock" and type(payload) == "table" then
            Runtime.GoldMerchantStock = payload
            Runtime.GoldMerchantStockAt = now()
        end
    end)
end

Runtime.AutoGoldMerchantTick = function()
    if not Settings.AutoGoldMerchant or not E.GoldMerchant then return false end
    if type(Runtime.GoldMerchantStock) ~= "table" or now() - (Runtime.GoldMerchantStockAt or 0) > 180 then
        E.GoldMerchant:FireServer("RequestStock")
        return false
    end

    local reserveGold, reserveShards = Runtime.GetMajorCurrencyReserve and Runtime.GetMajorCurrencyReserve() or reserveForNextWorld()
    local goldAvailable = math.max(0, numData("Gold") - (tonumber(reserveGold) or 0))
    local shardAvailable = math.max(0, numData("Shards") - (tonumber(reserveShards) or 0))
    local weaponTarget = rollRarityNames[Settings.WeaponEnchantMin] or 3
    local skillTarget = rollRarityNames[Settings.SkillMinRarity] or 3

    -- Buy only useful progression materials and only from disposable currency.
    -- Golden Rings/event currency are deliberately excluded from this routine.
    for index = 1, 5 do
        local target = Runtime.GoldMerchantTargets[index]
        local wanted = target and tonumber(target.amount) or 0
        if target and target.highTarget == "enchant" and weaponTarget < 4 then wanted = 0 end
        if target and target.highTarget == "skill" and skillTarget < 4 then wanted = 0 end
        local have = target and stackAmount(target.stack) or 0
        local need = math.max(0, wanted - have)
        local stock = math.max(0, tonumber(Runtime.GoldMerchantStock[index] or Runtime.GoldMerchantStock[tostring(index)]) or 0)
        local itemData = type(D.GoldMerchantData.GetItemData) == "function"
            and safe(D.GoldMerchantData.GetItemData, D.GoldMerchantData, index)
            or (D.GoldMerchantData.ItemData and D.GoldMerchantData.ItemData[index])
        if need > 0 and stock > 0 and type(itemData) == "table" then
            local gc = math.max(0, tonumber(itemData.goldCost) or 0)
            local sc = math.max(0, tonumber(itemData.shardCost) or 0)
            local byGold = gc > 0 and math.floor(goldAvailable / gc) or need
            local byShard = sc > 0 and math.floor(shardAvailable / sc) or need
            local quantity = math.min(need, stock, byGold, byShard)
            if quantity >= 1 then
                E.GoldMerchant:FireServer("Purchase", index, math.floor(quantity))
                return true
            end
        end
    end
    return false
end

Runtime.TokenUpgradePriority = {
    {id = 3475768740, name = "2x Exp", value = 125},
    {id = 3475769423, name = "2x Drops", value = 120},
    {id = 3475778953, name = "Extra Skill Slot", value = 112},
    {id = 3520459829, name = "2x Luck", value = 105},
    {id = 3710353474, name = "x2 Pets", value = 100},
    {id = 3575645947, name = "x2 Boss Reward", value = 92},
    {id = 3580830657, name = "x2 Soul Crystal", value = 82},
    {id = 3604339134, name = "x2 Infinite Tower Speed", value = 70},
    {id = 3710353491, name = "x2 Variants", value = 78},
    {id = 3475770883, name = "Lucky Forge", value = 74},
    {id = 3580830766, name = "+1 Dungeon Life", value = 58},
    {id = 3703674621, name = "More Inventory Slots", value = 68},
}
Runtime.TokenBundleId = 3475764387

Runtime.RefreshTokenPrices = function(force)
    if not force and type(Runtime.TokenPrices) == "table" and now() - (Runtime.TokenPricesAt or 0) < 120 then
        return Runtime.TokenPrices
    end
    local f = func("GetShopTokenPrices")
    if not f then return nil end
    local prices = safe(f.InvokeServer, f)
    if type(prices) == "table" then
        Runtime.TokenPrices = prices
        Runtime.TokenPricesAt = now()
    end
    return Runtime.TokenPrices
end

Runtime.AutoTokenUpgradeTick = function()
    if not Settings.AutoTokenUpgrades or not E.Market then return false end
    if now() - (Runtime.LastTokenPurchase or 0) < 4 then return false end
    local prices = Runtime.RefreshTokenPrices(false)
    if type(prices) ~= "table" then return false end
    local tokens = numData("TradingToken")
    if tokens <= 0 then return false end

    -- Rank permanent upgrades by progression value per Trading Token rather than
    -- blindly buying the first affordable pass. The all-gamepasses bundle is a
    -- real token-shop product, so its value is the sum of useful passes still
    -- missing from this account. If it is materially better value, save for it.
    local mode = tostring(Settings.ActivityMode or "World Farm")
    local candidates = {}
    local remainingUtility = 0
    for _, row in ipairs(Runtime.TokenUpgradePriority) do
        if not Runtime.OwnsPermanentPass(row.id) then
            local utility = tonumber(row.value) or 50
            if row.id == 3580830657 and (mode == "Dungeons" or mode == "Rotation") then
                utility = utility + 70
            elseif row.id == 3604339134 and (mode == "Infinite Tower" or mode == "Rotation") then
                utility = utility + 70
            elseif row.id == 3580830766 and (mode == "Dungeons" or mode == "Rotation") then
                utility = utility + 40
            end
            remainingUtility = remainingUtility + utility
            local price = tonumber(prices[tostring(row.id)] or prices[row.id])
            if price and price > 0 and (type(D.ShopTokenProducts.IsEligible) ~= "function"
                or safe(D.ShopTokenProducts.IsEligible, D.ShopTokenProducts, row.id) == true) then
                candidates[#candidates + 1] = {
                    id = row.id, name = row.name, price = price, utility = utility,
                    efficiency = utility / price, bundle = false,
                }
            end
        end
    end

    local bundleId = Runtime.TokenBundleId
    if remainingUtility > 0 and bundleId and not Runtime.OwnsPermanentPass(bundleId) then
        local bundlePrice = tonumber(prices[tostring(bundleId)] or prices[bundleId])
        if bundlePrice and bundlePrice > 0 and (type(D.ShopTokenProducts.IsEligible) ~= "function"
            or safe(D.ShopTokenProducts.IsEligible, D.ShopTokenProducts, bundleId) == true) then
            candidates[#candidates + 1] = {
                id = bundleId, name = "ALL Gamepasses Bundle", price = bundlePrice,
                utility = remainingUtility, efficiency = remainingUtility / bundlePrice, bundle = true,
            }
        end
    end

    table.sort(candidates, function(a, b)
        if math.abs(a.efficiency - b.efficiency) > 0.0000001 then
            return a.efficiency > b.efficiency
        end
        return a.utility > b.utility
    end)
    local bestOverall = candidates[1]
    if not bestOverall then
        Runtime.TokenSavingFor = nil
        return false
    end

    local bestAffordable
    for _, candidate in ipairs(candidates) do
        if tokens >= candidate.price then
            if not bestAffordable or candidate.efficiency > bestAffordable.efficiency then
                bestAffordable = candidate
            end
        end
    end

    -- Save for a substantially more token-efficient bundle/upgrade instead of
    -- spending the balance on a weaker pass just because it happens to be cheap.
    if tokens < bestOverall.price and bestAffordable
        and bestOverall.efficiency >= bestAffordable.efficiency * 1.35 then
        Runtime.TokenSavingFor = bestOverall.name
        Runtime.TokenSavingCost = bestOverall.price
        return false
    end

    local chosen = tokens >= bestOverall.price and bestOverall or bestAffordable
    if not chosen then
        Runtime.TokenSavingFor = bestOverall.name
        Runtime.TokenSavingCost = bestOverall.price
        return false
    end

    E.Market:FireServer("purchaseToken", tostring(chosen.id))
    Runtime.TokenSavingFor = nil
    Runtime.TokenSavingCost = nil
    Runtime.LastTokenPurchase = now()
    return true
end

Runtime.AutoSkipTutorialTick = function()
    if not Settings.AutoSkipTutorial or not E.Tutorial then return false end
    if tonumber(getData("TutorialStage")) ~= 1 then return false end
    if now() - (Runtime.TutorialSkipSentAt or 0) < 8 then return false end
    Runtime.TutorialSkipSentAt = now()
    E.Tutorial:FireServer("skip")
    return true
end

Runtime.ItemBasePowerHint = function(itemId, info)
    if type(info) ~= "table" or type(info.stats) ~= "table" then return 0 end
    local total = 0
    for statKey, range in pairs(info.stats) do
        local bounds = range
        if type(D.LimitedScaling.GetStatBounds) == "function" then
            bounds = safe(D.LimitedScaling.GetStatBounds, D.LimitedScaling, itemId, info, statKey, numData("Level")) or bounds
        end
        if type(bounds) == "table" then
            total = total + math.max(tonumber(bounds[1]) or 0, tonumber(bounds[2]) or 0)
        elseif tonumber(bounds) then
            total = total + tonumber(bounds)
        end
    end
    return total
end

Runtime.EventGearCanImprove = function(contents)
    if type(contents) ~= "table" then return false end
    local best = bestEquipmentBySlot()
    for itemId in pairs(contents) do
        local info = type(D.Items.Lookup) == "function" and safe(D.Items.Lookup, D.Items, itemId) or nil
        if type(info) == "table" and info.type == "Equipment" then
            local slot = type(D.Items.IdToSlot) == "function" and safe(D.Items.IdToSlot, D.Items, itemId) or nil
            local current = slot and best[slot] or nil
            if not current then return true end
            -- Estimate the unopened event item's best base roll using Loot Up's
            -- LimitedScaling rules, then compare it with the current item's real
            -- effective powerScore (which already includes forge/variant/apex scaling).
            local eventHint = Runtime.ItemBasePowerHint(itemId, info)
            local currentPower = math.max(0, tonumber(current.score) or 0)
            if eventHint > currentPower * 1.01 then return true end
        end
    end
    return false
end

Runtime.AutoAdvancePresentRoll = function()
    -- Christmas presents use the game's interactive PresentOpen roll UI. Advance
    -- its existing Activated signal automatically so AFK event spending cannot
    -- leave the camera/UI waiting for manual clicks. This never invokes a purchase.
    task.spawn(function()
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        for _ = 1, 9 do
            if not Runtime.Alive then return end
            task.wait(0.30)
            local ui = playerGui and (playerGui:FindFirstChild("PresentOpen") or playerGui:FindFirstChild("EasterPresentOpen"))
            local background = ui and ui:FindFirstChild("Background", true)
            if ui and ui.Enabled and background and background:IsA("GuiButton") then
                if type(firesignal) == "function" then
                    pcall(firesignal, background.Activated)
                elseif type(getconnections) == "function" then
                    local ok, connections = pcall(getconnections, background.Activated)
                    if ok and type(connections) == "table" then
                        for _, connection in ipairs(connections) do
                            if connection and type(connection.Function) == "function" then
                                pcall(connection.Function)
                            end
                        end
                    end
                else
                    local ok, virtualInput = pcall(game.GetService, game, "VirtualInputManager")
                    if ok and virtualInput then
                        local pos, size = background.AbsolutePosition, background.AbsoluteSize
                        local x, y = pos.X + size.X * 0.5, pos.Y + size.Y * 0.5
                        pcall(virtualInput.SendMouseButtonEvent, virtualInput, x, y, 0, true, game, 0)
                        pcall(virtualInput.SendMouseButtonEvent, virtualInput, x, y, 0, false, game, 0)
                    end
                end
            end
        end
    end)
end

Runtime.AutoEventChestTick = function()
    if not Settings.AutoEventChests or not E.Reward then return false end
    if now() < (Runtime.EventChestPendingUntil or 0) then return false end

    -- These are normal in-game event currencies, never Robux purchase paths.
    -- Golden Rings buy the Christmas Material Present; Sea Shells/Eggs use the
    -- event chest tables. Interactive present animations are auto-advanced below.
    local rings = stackAmount("st_6")
    local christmasPresents = type(D.ChristmasEvent.Presents) == "table" and D.ChristmasEvent.Presents or {}
    local christmasChests = type(D.ChristmasEvent.Chests) == "table" and D.ChristmasEvent.Chests or {}
    local presentPrice = type(christmasPresents[1]) == "table" and tonumber(christmasPresents[1].price) or 0
    local chestPrice = type(christmasChests[1]) == "table" and tonumber(christmasChests[1].price) or 0
    -- The saved Christmas client reconciles affordability from Presents but builds
    -- the visible reward table from Chests. Require the larger of the two prices so
    -- an AFK request can never depend on that client inconsistency being favourable.
    local christmasSafePrice = math.max(1, presentPrice, chestPrice)
    if rings >= christmasSafePrice then
        E.Reward:FireServer("b_chr", 1)
        Runtime.EventChestPendingUntil = now() + 3
        if Runtime.AutoAdvancePresentRoll then task.defer(Runtime.AutoAdvancePresentRoll) end
        return true
    end

    -- Gear chests are useful while their fixed event equipment can still improve
    -- a slot. After that point, the cheaper materials chest gives much better
    -- long-term forge/enchant/skill/rune value per event currency.
    local shells = stackAmount("st_1001")
    local summerChests = type(D.ChristmasEvent.Chests) == "table" and D.ChristmasEvent.Chests or {}
    local summerGear = summerChests[2]
    local summerMaterials = summerChests[1]
    local summerIndex = Runtime.EventGearCanImprove(type(summerGear) == "table" and summerGear.contents or nil) and 2 or 1
    local summerChest = summerChests[summerIndex]
    local summerPrice = type(summerChest) == "table" and tonumber(summerChest.price) or (summerIndex == 2 and 50 or 25)
    if shells >= summerPrice and summerPrice > 0 then
        local blackMarket = Controllers.UI and Controllers.UI.Windows and Controllers.UI.Windows.BlackMarket
        if type(blackMarket) == "table" then blackMarket._skipAnimation = true end
        E.Reward:FireServer("b_bm", summerIndex)
        Runtime.EventChestPendingUntil = now() + 3
        if Runtime.AutoAdvancePresentRoll then task.defer(Runtime.AutoAdvancePresentRoll) end
        return true
    end

    local easterId = D.EasterEvent.CurrencyId or "st_10"
    local eggs = stackAmount(easterId)
    local easterChests = type(D.EasterEvent.Chests) == "table" and D.EasterEvent.Chests or {}
    local easterGear = easterChests[2]
    local easterIndex = Runtime.EventGearCanImprove(type(easterGear) == "table" and easterGear.contents or nil) and 2 or 1
    local easterChest = easterChests[easterIndex]
    local easterPrice = type(easterChest) == "table" and tonumber(easterChest.price) or (easterIndex == 2 and 25 or 5)
    if eggs >= easterPrice and easterPrice > 0 then
        E.Reward:FireServer("b_easter", easterIndex)
        Runtime.EventChestPendingUntil = now() + 3
        if Runtime.AutoAdvancePresentRoll then task.defer(Runtime.AutoAdvancePresentRoll) end
        return true
    end
    return false
end

local function skillRarity(skillId)
    if not skillId then return 0 end
    local info
    if type(D.SkillDefs.Lookup) == "function" then
        info = safe(D.SkillDefs.Lookup, D.SkillDefs, skillId)
    end
    if type(info) ~= "table" and type(D.SkillDefs.All) == "table" then
        info = D.SkillDefs.All[skillId]
    end
    if type(info) ~= "table" then
        info = D.SkillDefs[skillId]
    end
    return type(info) == "table" and tonumber(info.rarity) or 0
end

local function skillSlotAvailable(slot)
    if slot == 1 then return true end
    if slot == 2 then return numData("Level") >= 15 end
    if slot == 3 then
        if Controllers.Replication and type(Controllers.Replication.OwnsPass) == "function" then
            return safe(Controllers.Replication.OwnsPass, Controllers.Replication, "3475778953") == true
        end
        local owned = tableData("OwnedPasses")
        return owned["3475778953"] == true or owned[3475778953] == true
    end
    return false
end

local function autoRollSkills()
    if not E.SkillRoll then return end
    local skills = tableData("Skills")
    local requestedRarity = rollRarityNames[Settings.SkillMinRarity] or 3
    local minRarity = math.min(requestedRarity, tonumber(Runtime.MaxRollableSkillRarity) or requestedRarity)
    local normalCount = stackAmount("st_4")
    local ancientCount = stackAmount("st_5")
    local scroll

    -- The game's scroll rules are threshold-based: normal scrolls can roll any
    -- normal skill; Ancient scrolls exclude Common/Rare and therefore guarantee
    -- Epic+ in this snapshot. At the 20-roll pity, the UI overrides that threshold
    -- with Rare+, so an Ancient scroll would lose its Epic+ guarantee on that roll.
    local pityAt = tonumber(D.SkillDefs.Pity) or 20
    local pityReady = numData("SkillPity") >= pityAt
    local ancientReserve = math.max(0, tonumber(Settings.SkillQualityAncientReserve) or 2)
    if pityReady then
        -- On the pity roll the client forces Rare+, even when an Ancient Scroll is
        -- selected. Use a normal scroll so the Ancient Epic+ threshold is not wasted.
        if normalCount > 0 then scroll = "st_4" else return end
    elseif minRarity >= 3 and ancientCount > ancientReserve then
        -- AncientMinRarity=2 and GetSkillsOverRarity uses rarity > threshold,
        -- therefore Ancient Scrolls guarantee Epic+ in this snapshot.
        scroll = "st_5"
    elseif normalCount > 0 then
        scroll = "st_4"
    elseif ancientCount > ancientReserve then
        scroll = "st_5"
    end
    if not scroll then return end

    local worstSlot, worstRarity
    for slot = 1, 3 do
        if skillSlotAvailable(slot) then
            local id = skills[tostring(slot)] or skills[slot]
            local rarity = skillRarity(id)
            if not id or rarity < minRarity then
                if not worstRarity or rarity < worstRarity then
                    worstSlot, worstRarity = slot, rarity
                end
            end
        end
    end

    -- Once the configured rarity floor is satisfied, improve weak same-rarity
    -- skills only through a non-downgrade path. For the default Epic floor that
    -- means Ancient Scrolls, which guarantee Epic+ here. Legendary+ and evolved
    -- skills are protected rather than gambling them for marginal quality gains.
    if not worstSlot and Settings.SmartSkillQuality and minRarity <= 3
        and not pityReady
        and ancientCount > math.max(0, tonumber(Settings.SkillQualityAncientReserve) or 2)
        and type(Runtime.SkillQualityThreshold) == "function" then
        local weakestRatio = 1
        for slot = 1, 3 do
            if skillSlotAvailable(slot) then
                local id = skills[tostring(slot)] or skills[slot]
                local info = id and type(D.SkillDefs.All) == "table" and D.SkillDefs.All[id] or nil
                local rarity = skillRarity(id)
                if type(info) == "table" and info.evolved ~= true
                    and (tonumber(info.weight) or 0) > 0
                    and rarity >= minRarity and rarity <= 3 then
                    local threshold = Runtime.SkillQualityThreshold(rarity)
                    local score = Runtime.SkillModuleScore and Runtime.SkillModuleScore(id) or 0
                    if threshold and threshold > 0 and score < threshold then
                        local ratio = score / threshold
                        if ratio < weakestRatio then
                            weakestRatio = ratio
                            worstSlot = slot
                            worstRarity = rarity
                            scroll = "st_5"
                        end
                    end
                end
            end
        end
    end

    if worstSlot then
        -- The normal UI sends confirmation=true when replacing Legendary+ skills.
        -- Quality rerolls above deliberately never select those protected slots.
        E.SkillRoll:FireServer(worstSlot, scroll, (worstRarity or 0) >= 4)
    end
end

local evolutionCosts = D.SkillEvolutions.CostByRarity or {1, 5, 10, 20}

Runtime.SkillModuleScore = function(skillId)
    Runtime.SkillModuleScoreCache = Runtime.SkillModuleScoreCache or {}
    if Runtime.SkillModuleScoreCache[skillId] ~= nil then return Runtime.SkillModuleScoreCache[skillId] end
    local folder = Shared:FindFirstChild("Skills")
    local moduleScript = folder and folder:FindFirstChild(tostring(skillId))
    local skillModule = moduleScript and safe(require, moduleScript) or nil
    if type(skillModule) ~= "table" then
        Runtime.SkillModuleScoreCache[skillId] = 0
        return 0
    end
    local config = type(skillModule.Config) == "table" and skillModule.Config or {}
    local cooldown = math.max(1, tonumber(config.cooldown) or 20)
    local damage, maxRange = 0, 0
    local token = type(skillModule.Token) == "table" and skillModule.Token or {}
    for _, hit in ipairs(type(token.hits) == "table" and token.hits or {}) do
        if type(hit) == "table" then
            damage = damage + math.max(0, tonumber(hit.damage) or 0)
            maxRange = math.max(maxRange, tonumber(hit.range) or 0)
        end
    end
    local score = damage * (1 + math.min(maxRange, 100) / 200) / cooldown

    -- Utility-only skills do not expose damage hits, so value their actual buff
    -- uptime enough to evolve them after stronger direct-DPS gains.
    if skillId == "warrior_surge" then score = math.max(score, 0.10)
    elseif skillId == "evolved_warrior_surge" then score = math.max(score, 0.17)
    elseif skillId == "bolster" then score = math.max(score, 0.035)
    elseif skillId == "evolved_bolster" then score = math.max(score, 0.070)
    elseif skillId == "forest_blessing" then score = math.max(score, 0.025)
    elseif skillId == "evolved_forest_blessing" then score = math.max(score, 0.080)
    end
    Runtime.SkillModuleScoreCache[skillId] = score
    return score
end

Runtime.SkillQualityThreshold = function(rarity)
    Runtime.SkillQualityThresholdCache = Runtime.SkillQualityThresholdCache or {}
    rarity = tonumber(rarity) or 0
    if Runtime.SkillQualityThresholdCache[rarity] ~= nil then
        return Runtime.SkillQualityThresholdCache[rarity]
    end
    local scores = {}
    for id, info in pairs(type(D.SkillDefs.All) == "table" and D.SkillDefs.All or {}) do
        if type(info) == "table" and info.evolved ~= true
            and (tonumber(info.weight) or 0) > 0
            and tonumber(info.rarity) == rarity then
            local score = Runtime.SkillModuleScore(id)
            if score and score > 0 then scores[#scores + 1] = score end
        end
    end
    table.sort(scores)
    local threshold = 0
    if #scores > 0 then
        -- Median: enough to remove the genuinely weak half of a rarity without
        -- turning normal AFK progression into an endless perfect-skill chase.
        threshold = scores[math.max(1, math.ceil(#scores * 0.50))]
    end
    Runtime.SkillQualityThresholdCache[rarity] = threshold
    return threshold
end

local function autoEvolveSkills()
    if not E.SkillEvolution then return end
    local skills = tableData("Skills")
    local costItemId = D.SkillEvolutions.CostItemId or "st_38"
    local crystals = stackAmount(costItemId)
    local best
    for slot = 1, 3 do
        local id = skills[tostring(slot)] or skills[slot]
        local evolvedId = id and type(D.SkillEvolutions.GetEvolvedId) == "function"
            and safe(D.SkillEvolutions.GetEvolvedId, D.SkillEvolutions, id) or nil
        local enabled = evolvedId ~= nil or (id and type(D.SkillEvolutions.ByBase) == "table" and D.SkillEvolutions.ByBase[id] ~= nil)
        if enabled then
            evolvedId = evolvedId or D.SkillEvolutions.ByBase[id]
            local cost
            if type(D.SkillEvolutions.GetCost) == "function" then
                cost = tonumber(safe(D.SkillEvolutions.GetCost, D.SkillEvolutions, id))
            end
            if not cost then
                local rarity = math.clamp(skillRarity(id), 1, #evolutionCosts)
                cost = tonumber(evolutionCosts[rarity]) or 20
            end
            if crystals >= cost then
                local before = Runtime.SkillModuleScore(id)
                local after = Runtime.SkillModuleScore(evolvedId)
                local gain = math.max(0.001, after - before)
                local value = gain / math.max(1, cost)
                if not best or value > best.value then
                    best = {slot=slot, value=value, gain=gain, cost=cost, id=id, evolvedId=evolvedId}
                end
            end
        end
    end
    if best then
        Runtime.LastSkillEvolutionChoice = best
        E.SkillEvolution:FireServer(best.slot)
    end
end


-- Enchants / runes / potion economy ----------------------------------------------
local armorSlots = {
    Headgear = true,
    Chestplate = true,
    Leggings = true,
    Boots = true,
}

local function enchantRarity(enchantId)
    if not enchantId or type(D.EnchantData.LookupId) ~= "function" then return 0 end
    local info = safe(D.EnchantData.LookupId, D.EnchantData, enchantId)
    return type(info) == "table" and tonumber(info.rarity) or 0
end

local function equippedEntry(slotName)
    local inv = inventoryWindow()
    local entry = inv and type(inv.Equipped) == "table" and inv.Equipped[slotName] or nil
    return type(entry) == "table" and entry or nil
end

local function autoEnchantWeapon()
    if not E.Enchant then return end
    local entry = equippedEntry("Weapon")
    if not entry or not entry.data then return end
    local uid = entry.data.uid or entry.key
    if not uid then return end
    local current = entry.data.meta and entry.data.meta.enchant
    local target = rollRarityNames[Settings.WeaponEnchantMin] or 3
    if enchantRarity(current) >= target then return end

    local normal = stackAmount("st_1")
    local trueStone = stackAmount("st_2")
    local stone
    local pityAt = tonumber(D.EnchantData.Pity) or 15
    local pityReady = numData("EnchantPity") >= pityAt
    -- Just like skills, the pity rule replaces the selected stone's rarity floor.
    -- Save expensive True Enchant Stones on the pity roll.
    if pityReady then
        if normal > 0 then stone = "st_1" else return end
    elseif target >= 4 and trueStone > 0 then
        stone = "st_2"
    elseif normal > 0 then
        stone = "st_1"
    elseif trueStone > 0 then
        stone = "st_2"
    end
    if stone then
        E.Enchant:FireServer(uid, stone)
    end
end

local function autoEnchantArmor()
    if not E.EnchantArmor or stackAmount("st_16") <= 0 then return end
    local inv = inventoryWindow()
    if not inv or type(inv.Equipped) ~= "table" then return end
    local target = rollRarityNames[Settings.ArmorEnchantMin] or 3

    for slot in pairs(armorSlots) do
        local entry = inv.Equipped[slot]
        if type(entry) == "table" and entry.data then
            local current = entry.data.meta and entry.data.meta.enchant
            if enchantRarity(current) < target then
                local uid = entry.data.uid or entry.key
                if uid then
                    E.EnchantArmor:FireServer(uid)
                    return
                end
            end
        end
    end
end

local function runeRarity(runeId)
    local info = type(D.RunesData.All) == "table" and D.RunesData.All[runeId] or nil
    return type(info) == "table" and tonumber(info.rarity) or 0
end

local function autoRunes()
    if not E.RuneRoll then return end
    local runes = tableData("Runes")
    local current = runes["1"] or runes[1]
    local target = rollRarityNames[Settings.RuneMinRarity] or 3
    if current and runeRarity(current) >= target then return end

    local normal = stackAmount("st_15")
    local ancient = stackAmount("st_14")
    local scroll
    if target >= 4 and ancient > 0 then
        scroll = "st_14"
    elseif normal > 0 then
        scroll = "st_15"
    elseif ancient > 0 then
        scroll = "st_14"
    end
    if scroll then
        E.RuneRoll:FireServer("1", scroll)
    end
end

local function potionIsActive(potionKey)
    local active = tableData("ActivePotions")
    return (tonumber(active[potionKey]) or 0) > 0
end

local function dungeonShopController()
    local windows = Controllers.UI and Controllers.UI.Windows
    return windows and (windows.Dungeon_Shop or windows["Dungeon Shop"] or windows.DungeonShop) or nil
end

local function dungeonPotionPrice()
    local shop = dungeonShopController()
    if shop and type(shop.GetPotionPrice) == "function" then
        local price = tonumber(safe(shop.GetPotionPrice, shop))
        if price and price > 0 then return price end
    end
    return tonumber(D.DungeonShopData.PotionPrice) or 2500
end

local function autoPotions()
    if type(D.DungeonShopData.PotionOrder) ~= "table"
        or type(D.DungeonShopData.Potions) ~= "table" then
        return false
    end

    for _, potionKey in ipairs(D.DungeonShopData.PotionOrder) do
        local cfg = D.DungeonShopData.Potions[potionKey]
        local stackId = type(cfg) == "table" and cfg.stackId or nil
        local allowed = true
        if Settings.PotionStrategy == "Smart" then
            local combatActive = liveEnemy(Runtime.Target)
                or Runtime.Activity == "Dungeon" or Runtime.Activity == "Tower" or Runtime.Activity == "LiveEvent"
            if not combatActive then allowed = false end
            if potionKey == "Exp" and numData("Level") >= (tonumber(D.Leveling.MaxLevel) or 1000) then
                allowed = false
            end
        end
        if allowed and stackId and not potionIsActive(potionKey) then
            if stackAmount(stackId) > 0 then
                if E.Potion then
                    E.Potion:FireServer("use", stackId)
                    return true
                end
            elseif Settings.AutoBuyPotions and E.DungeonShop then
                local price = dungeonPotionPrice()
                local reserve = math.max(0, tonumber(Settings.SoulCrystalReserve) or 0)
                if numData(D.DungeonShopData.CurrencyKey or "SoulCrystals") - price >= reserve then
                    E.DungeonShop:FireServer("buyPotion", potionKey)
                    return true
                end
            end
        end
    end
    return false
end

local function autoDungeonShopDeals()
    if not E.DungeonShop or type(D.DungeonShopData.GetCurrentRotatingItems) ~= "function" then return false end
    local crystals = numData(D.DungeonShopData.CurrencyKey or "SoulCrystals")
    local reserve = math.max(0, tonumber(Settings.SoulCrystalReserve) or 0)
    if crystals <= reserve then return false end

    local offers = safe(D.DungeonShopData.GetCurrentRotatingItems, D.DungeonShopData, os.time())
    if type(offers) ~= "table" then
        E.DungeonShop:FireServer("requestRotatingItems")
        return true
    end

    -- Buy the strongest-value consumable bundle once per rotating window.
    -- Pets and Robux crystal packs/gamepasses are deliberately excluded.
    local best
    for _, offer in ipairs(offers) do
        if type(offer) == "table"
            and type(offer.offerId) == "string"
            and (offer.itemId == "st_2" or offer.itemId == "st_5") then
            local price = tonumber(offer.price) or math.huge
            local amount = tonumber(offer.amount) or 1
            local value = amount / math.max(price, 1)
            if crystals - price >= reserve and (not best or value > best.value) then
                best = {
                    offerId = offer.offerId,
                    value = value,
                    windowIndex = offer.windowIndex,
                }
            end
        end
    end
    if best then
        local marker = "dungeonDeal_" .. tostring(best.windowIndex or "current")
        if not Runtime.Last[marker] then
            Runtime.Last[marker] = now()
            E.DungeonShop:FireServer("buyRotatingItem", best.offerId)
            return true
        end
    end
    return false
end

local function completedDungeonRuns()
    local stats = tableData("AccountStats")
    return math.max(0, math.floor(tonumber(stats.CompletedRun) or 0))
end

local dungeonSetSlotMap = {
    Head = "Headgear",
    Body = "Chestplate",
    Legs = "Leggings",
    Boots = "Boots",
    Weapon = "Weapon",
}

local function statTableScore(stats, useUpperBound)
    if type(stats) ~= "table" then return 0 end
    local total = 0
    for _, value in pairs(stats) do
        if type(value) == "number" then
            total = total + value
        elseif type(value) == "table" then
            local a = tonumber(value[1]) or 0
            local b = tonumber(value[2]) or a
            total = total + (useUpperBound and math.max(a, b) or ((a + b) * 0.5))
        end
    end
    return total
end

local function dungeonSetStrength(cfg)
    if type(cfg) ~= "table" or type(cfg.items) ~= "table" then return 0 end
    local total = 0
    for _, itemId in pairs(cfg.items) do
        local info = type(D.Items.Lookup) == "function" and safe(D.Items.Lookup, D.Items, itemId) or nil
        if type(info) == "table" then
            total = total + statTableScore(info.stats, true)
            total = total + (tonumber(info.rarity) or 0) * 0.001
        end
    end
    return total
end

local function dungeonSetHasPotentialUpgrade(cfg)
    if type(cfg) ~= "table" or type(cfg.items) ~= "table" then return true end
    local inv = inventoryWindow()
    if not inv or type(inv.Equipped) ~= "table" then return true end

    for shopSlot, itemId in pairs(cfg.items) do
        local slot = dungeonSetSlotMap[shopSlot]
        local candidate = type(D.Items.Lookup) == "function" and safe(D.Items.Lookup, D.Items, itemId) or nil
        local candidateMax = type(candidate) == "table" and statTableScore(candidate.stats, true) or 0
        local equipped = slot and inv.Equipped[slot] or nil
        local currentStats = equipped and equipped.data and equipped.data.meta and equipped.data.meta.stats
        local currentRaw = statTableScore(currentStats, true)
        if not equipped or candidateMax > currentRaw + 1e-6 then
            return true
        end
    end
    return false
end

local function bestDungeonSet()
    local runs = completedDungeonRuns()
    local bestKey, bestData, bestStrength = nil, nil, -math.huge
    for _, setKey in ipairs(D.DungeonShopData.SetOrder or {}) do
        local cfg = D.DungeonShopData.Sets and D.DungeonShopData.Sets[setKey]
        local required = type(cfg) == "table" and tonumber(cfg.requiredCompletedRuns) or 0
        if type(cfg) == "table" and runs >= (required or 0) then
            -- SetOrder is UI order, not a power ladder (Royal Amethyst is listed
            -- last but is weaker than Radiant Warlord). Rank actual item stats.
            local strength = dungeonSetStrength(cfg)
            if strength > bestStrength then
                bestStrength = strength
                bestKey, bestData = setKey, cfg
            end
        end
    end
    return bestKey, bestData
end

local function autoDungeonGear()
    if not E.DungeonShop or type(D.DungeonShopData.GetPrice) ~= "function" then return false end
    local setKey, setData = bestDungeonSet()
    if not setKey or not dungeonSetHasPotentialUpgrade(setData) then return false end

    local balance = numData(D.DungeonShopData.CurrencyKey or "SoulCrystals")
    local reserve = math.max(0, tonumber(Settings.SoulCrystalReserve) or 0)
    local quantities = {"x25", "x10", "x3", "x1"}
    for _, quantity in ipairs(quantities) do
        local price = tonumber(safe(D.DungeonShopData.GetPrice, D.DungeonShopData, setKey, quantity))
        if price and price > 0 and balance - price >= reserve then
            local shop = dungeonShopController()
            if shop and (shop.RequestPending or shop.Animating) then return false end
            if shop and type(shop.TryBuy) == "function" then
                safe(shop.TryBuy, shop, setKey, quantity)
            else
                E.DungeonShop:FireServer("buy", setKey, quantity)
            end
            return true
        end
    end
    return false
end

local function autoDungeonEconomy()
    -- One shop action per pass prevents mutually-valid systems from firing
    -- multiple state-changing DungeonShop requests in the same frame.
    local shop = dungeonShopController()
    if shop and (shop.RequestPending or shop.Animating) then return false end
    if Settings.AutoUsePotions and autoPotions() then return true end
    if Settings.AutoDungeonShopDeals and autoDungeonShopDeals() then return true end
    if Settings.AutoDungeonGear and autoDungeonGear() then return true end
    return false
end


-- Pets --------------------------------------------------------------------------
local function petDps(info, data)
    if type(info) ~= "table" or type(data) ~= "table" then return 0 end
    local level = tonumber(data.level) or 1
    local variant = data.variant
    local damage = type(D.PetsData.GetDamage) == "function" and tonumber(safe(D.PetsData.GetDamage, D.PetsData, info, level, variant)) or tonumber(info.damage) or 0
    local interval = type(D.PetsData.GetAttackInterval) == "function" and tonumber(safe(D.PetsData.GetAttackInterval, D.PetsData, info)) or tonumber(info.attackSpeed) or 1
    return damage / math.max(interval or 1, 0.05)
end

local function autoEquipPets()
    if not E.Pet then return false end
    local save = tableData("Pets")
    local owned = type(save.Owned) == "table" and save.Owned or {}
    local ranked = {}
    for uid, data in pairs(owned) do
        if type(data) == "table" then
            local id = data.id
            local info = type(D.PetsData.Lookup) == "function" and D.PetsData:Lookup(id) or (D.PetsData.All and D.PetsData.All[id])
            if info then ranked[#ranked + 1] = {uid = tostring(uid), dps = petDps(info, data)} end
        end
    end
    table.sort(ranked, function(a, b) return a.dps > b.dps end)

    local limit = 1
    if type(D.GamepassBenefits.GetPetEquipLimit) == "function" then
        limit = math.max(1, math.floor(tonumber(safe(D.GamepassBenefits.GetPetEquipLimit, D.GamepassBenefits, tableData("OwnedPasses"))) or 1))
    elseif Runtime.OwnsPermanentPass and Runtime.OwnsPermanentPass(3710353474) then
        limit = 2
    end

    local desired = {}
    for i = 1, math.min(limit, #ranked) do desired[ranked[i].uid] = true end
    local current = {}
    if save.Equipped then current[tostring(save.Equipped)] = true end
    if save.EquippedSecondary then current[tostring(save.EquippedSecondary)] = true end

    -- Remove a weaker currently-equipped pet first. The server enforces the slot
    -- cap, so trying to equip the replacement before freeing a slot can fail.
    for uid in pairs(current) do
        if not desired[uid] then
            E.Pet:FireServer("u", uid)
            return true
        end
    end
    for uid in pairs(desired) do
        if not current[uid] then
            E.Pet:FireServer("e", uid)
            return true
        end
    end
    return false
end

-- Rewards / claims ---------------------------------------------------------------
local playtimeStamps = {1,3,5,7,10,15,20,25,30,35,45,60}

local function claimStandardQuests()
    if not E.Quest then return false end
    local windows = Controllers.UI and Controllers.UI.Windows
    local questsWindow = windows and (windows.Quests or windows["Quests"])
    if questsWindow and type(questsWindow.GetClaimableIds) == "function" then
        local ids = safe(questsWindow.GetClaimableIds, questsWindow)
        if type(ids) ~= "table" or #ids == 0 then return false end
    end
    E.Quest:FireServer("ca")
    return true
end

local function dailyRewardReady()
    local state = tableData("DailyRewards")
    if next(state) == nil then return true end -- bootstrap fallback
    if state.Completed == true or (tonumber(state.Streak) or 1) > 7 then return false end
    local lastClaim = tonumber(state.LastClaim)
    if not lastClaim then return true end
    return os.time() - lastClaim >= 86400
end

local function claimRoutineRewards()
    if Settings.AutoDaily and E.Reward and dailyRewardReady() then E.Reward:FireServer("cdr") end
    if Settings.AutoPlaytime and E.Reward then
        -- Prefer the game controller's exact claimable set. This avoids sending
        -- twelve rejected claim requests every reward pass once Playtime has loaded.
        local windows = Controllers.UI and Controllers.UI.Windows
        local playtime = windows and (windows.Playtime or windows["Playtime"])
        local unclaimed = playtime and playtime.Unclaimed
        if type(unclaimed) == "table" then
            local stamps = {}
            for stamp in pairs(unclaimed) do
                local n = tonumber(stamp)
                if n then stamps[#stamps + 1] = n end
            end
            table.sort(stamps)
            for _, stamp in ipairs(stamps) do
                E.Reward:FireServer("cpt", stamp)
                task.wait(0.07)
            end
        elseif not playtime then
            -- Bootstrap fallback for executors that run before the Playtime UI controller
            -- is available. Once the controller exists, its Unclaimed table is authoritative.
            for _, stamp in ipairs(playtimeStamps) do
                E.Reward:FireServer("cpt", stamp)
                task.wait(0.04)
            end
        end
    end
end

local function redeemCodes()
    if not E.Reward or type(D.CodesData) ~= "table" then return end
    local redeemed = tableData("RedeemedCodes")
    local unix = os.time()
    local sent = 0
    for code, entry in pairs(D.CodesData) do
        if type(code) == "string" and not redeemed[code] then
            local valid = true
            if type(entry) == "table" then
                local starts = tonumber(entry.startsAt or entry.StartsAt)
                local expires = tonumber(entry.expiry or entry.expiresAt or entry.Expiry)
                if starts and unix < starts then valid = false end
                if expires and expires > 0 and unix > expires then valid = false end
            end
            if valid then
                E.Reward:FireServer("cc", code)
                sent = sent + 1
                if sent >= 3 then return end
                task.wait(1.05)
            end
        end
    end
end

local function groupReward()
    if not E.Reward then return end
    local claimed = tableData("ClaimedRewards")
    if claimed.Group then return end
    local ok, inGroup = pcall(LocalPlayer.IsInGroup, LocalPlayer, 286242120)
    if ok and inGroup then E.Reward:FireServer("cg") end
end

local function seasonClaims()
    if not E.SeasonPass then return end
    local season = tableData("SeasonPass")
    local daily = type(season.Daily) == "table" and season.Daily or {}
    local quests = type(daily.Quests) == "table" and daily.Quests or {}
    local questDefs = type(D.SeasonPassData.Quests) == "table" and D.SeasonPassData.Quests or {}

    -- The Season Pass client marks a quest claimable only when Progress >= Target
    -- and Claimed is false. Mirror that state instead of probing every quest ID.
    for _, q in pairs(quests) do
        if type(q) == "table" and q.Id and q.Claimed ~= true then
            local def = questDefs[q.Id]
            local target = type(def) == "table" and tonumber(def.Target) or nil
            local progress = tonumber(q.Progress) or 0
            if target and progress >= target then
                E.SeasonPass:FireServer("claimQuest", q.Id)
                task.wait(0.08)
            end
        end
    end

    local claimed = type(season.ClaimedRewards) == "table" and season.ClaimedRewards or {}
    local level = math.max(0, math.floor(numData("BattlepassLevel")))
    -- UI contract: reward i unlocks when (i + 1) <= BattlepassLevel.
    local count = math.min(tonumber(D.SeasonPassData.RewardCount) or 25, math.max(0, level - 1))

    local function claimTrack(track)
        local trackClaimed = type(claimed[track]) == "table" and claimed[track] or {}
        for i = 1, count do
            if trackClaimed[i] ~= true and trackClaimed[tostring(i)] ~= true then
                E.SeasonPass:FireServer("claimReward", track, i)
                task.wait(0.06)
            end
        end
    end

    claimTrack("Free")
    if season.PremiumOwned == true then
        claimTrack("Premium")
    end
end

local function autoBasicSpin()
    local windows = Controllers.UI and Controllers.UI.Windows
    local wheel = windows and (windows["Spin Wheel"] or windows.SpinWheel)
    if wheel and type(wheel.GetState) == "function" then
        local state = safe(wheel.GetState, wheel, "Basic")
        if type(state) == "table" and (tonumber(state.Count) or 0) > 0 then
            wheel.Mode = "Basic"
            local remote = wheel.Event or E.SpinWheel
            if remote then remote:FireServer("spin", "Basic") end
        end
        return
    end
    -- Without the controller state we can safely request sync, but do not probe a
    -- spin blindly because Count can include separately purchased spins.
    if E.SpinWheel then E.SpinWheel:FireServer("sync") end
end

Runtime.AutoPremiumFreeSpinTick = function()
    if not Settings.AutoPremiumFreeSpin then return false end
    local windows = Controllers.UI and Controllers.UI.Windows
    local wheel = windows and (windows["Spin Wheel"] or windows.SpinWheel)
    if not wheel or type(wheel.GetState) ~= "function" then
        if E.SpinWheel then E.SpinWheel:FireServer("sync") end
        return false
    end
    local state = safe(wheel.GetState, wheel, "Premium")
    -- Premium also has purchased spin counts. Only consume the scheduled free spin.
    if type(state) == "table" and state.FreeReady == true then
        local remote = wheel.Event or E.SpinWheel
        if remote then
            wheel.Mode = "Premium"
            remote:FireServer("spin", "Premium")
            return true
        end
    end
    return false
end

local function autoSeasonSpin()
    if not E.SeasonSpin then return end
    local windows = Controllers.UI and Controllers.UI.Windows
    local season = windows and (windows.SeasonPass or windows["Season Pass"])
    E.SeasonSpin:FireServer("sync")
    if season and (tonumber(season.SpinsOwned) or 0) > 0 and season.SpinAnimating ~= true then
        E.SeasonSpin:FireServer("spin")
    end
end

local function autoClanClaim()
    if not Controllers.Quests then return end
    if type(Controllers.Quests.RefreshClanQuests) == "function" then
        safe(Controllers.Quests.RefreshClanQuests, Controllers.Quests)
    end
    local cache = Controllers.Quests.ClanCached
    local quests = type(cache) == "table" and cache.Quests or nil
    if type(quests) ~= "table" then return end
    for id, q in pairs(quests) do
        if type(q) == "table" and not q.Claimed and (tonumber(q.Current) or 0) >= (tonumber(q.Target) or math.huge) then
            if type(Controllers.Quests.AttemptClaimClanQuest) == "function" then
                safe(Controllers.Quests.AttemptClaimClanQuest, Controllers.Quests, id)
            else
                local f = func("ClaimClanQuest")
                if f then safe(f.InvokeServer, f, id) end
            end
            task.wait(0.2)
        end
    end
end

local function autoClanRewards()
    local divisionsFunc = func("Divisions")
    local claimFunc = func("ClaimClanRewards")
    local clanFunc = func("GetClan")
    if not divisionsFunc or not claimFunc or not clanFunc then return end

    -- Divisions returns {definitions, claimedNames}. The UI exposes a reward for
    -- each definition's nextTier once clan Points reaches pointsToNextTier.
    local payload = safe(divisionsFunc.InvokeServer, divisionsFunc)
    local clan = safe(clanFunc.InvokeServer, clanFunc)
    if type(payload) ~= "table" or type(clan) ~= "table" then return end
    local definitions = type(payload[1]) == "table" and payload[1] or {}
    local claimedList = type(payload[2]) == "table" and payload[2] or {}
    local claimed = {}
    for _, name in pairs(claimedList) do
        if type(name) == "string" then claimed[name] = true end
    end
    local points = math.max(0, tonumber(clan.Points) or 0)

    local eligible = {}
    for key, division in pairs(definitions) do
        if key ~= "Example" and type(division) == "table" and division.nextTier ~= nil then
            local nextDef = definitions[division.nextTier]
            local targetName = type(nextDef) == "table" and nextDef.Name or nil
            local cost = tonumber(division.pointsToNextTier) or math.huge
            if type(targetName) == "string" and not claimed[targetName] and points >= cost then
                eligible[#eligible + 1] = {name = targetName, cost = cost}
            end
        end
    end
    table.sort(eligible, function(a, b) return a.cost < b.cost end)

    for i = 1, math.min(#eligible, 3) do
        local ok = safe(claimFunc.InvokeServer, claimFunc, eligible[i].name)
        if ok == true then claimed[eligible[i].name] = true end
        task.wait(0.18)
    end
end

-- NPC quest automation -----------------------------------------------------------
local function questWorldNumber(def, questId)
    if type(def) ~= "table" then return 0 end
    local w = def.world or def.worldId or NPCQuestWorldById[questId]
    return type(w) == "string" and tonumber(w:match("World(%d+)$")) or 0
end

local function worldInfoById(worldId)
    for _, info in ipairs(orderedWorlds) do
        if info.id == worldId then return info end
    end
    return nil
end

local function npcQuestCurrentObjective(def, state)
    if type(def) ~= "table" then return nil, nil end
    local progress = type(state) == "table" and type(state.progress) == "table" and state.progress or {}

    local preferredEnemy = Settings.QuestMatchBestEnemy and Runtime.BestFarmEnemy or nil
    if preferredEnemy and Runtime.QuestTargetsEnemy(def, preferredEnemy) then
        for _, objective in ipairs(def.objectives or {}) do
            local enemy = objective.enemy or objective.enemyName or objective.id
            local target = math.max(0, tonumber(objective.target or objective.amount) or 0)
            local current = enemy and math.max(0, tonumber(progress[enemy]) or 0) or 0
            if enemy == preferredEnemy and (type(state) ~= "table" or current < target) then
                return objective, NPCQuestEnemyMeta[enemy]
            end
        end
    end

    local firstObjective, firstEnemyDef
    for _, objective in ipairs(def.objectives or {}) do
        local enemy = objective.enemy or objective.enemyName or objective.id
        local enemyDef = enemy and NPCQuestEnemyMeta[enemy] or nil
        if not firstObjective and enemyDef then
            firstObjective, firstEnemyDef = objective, enemyDef
        end
        local target = math.max(0, tonumber(objective.target or objective.amount) or 0)
        local current = enemy and math.max(0, tonumber(progress[enemy]) or 0) or 0
        if enemyDef and (type(state) ~= "table" or current < target) then
            return objective, enemyDef
        end
    end
    return firstObjective, firstEnemyDef
end

local function npcQuestTargetLevel(def, state)
    local _, enemyDef = npcQuestCurrentObjective(def, state)
    return enemyDef and math.max(1, tonumber(enemyDef.level) or 1) or 1
end

local function npcQuestZone(worldId, def, state)
    local info = worldInfoById(worldId)
    if not info then return 1 end
    return bestZone(info, npcQuestTargetLevel(def, state))
end

local function findQuestGiver(plan)
    if not plan or not plan.giverId then return nil end
    if NPCController and type(NPCController.NPCs) == "table" then
        local npc = NPCController.NPCs[plan.giverId]
        if typeof(npc) == "Instance" and npc.Parent then return npc end
    end
    local coreObjects = workspace:FindFirstChild("CoreObjects")
    local folder = coreObjects and coreObjects:FindFirstChild("QuestNPCs")
    local npc = folder and folder:FindFirstChild(plan.giverId, true)
    return typeof(npc) == "Instance" and npc or nil
end

local function questGiverCFrame(npc)
    if not npc then return nil end
    if npc:IsA("Model") then
        local ok, cf = pcall(npc.GetPivot, npc)
        if ok then return cf end
    elseif npc:IsA("BasePart") then
        return npc.CFrame
    end
    local part = npc:FindFirstChildWhichIsA("BasePart", true)
    return part and part.CFrame or nil
end

-- v1.4.3: keep travel helpers on Runtime instead of top-level locals. Loot Up is
-- close to Luau's 200-local chunk limit; table fields provide headroom without
-- changing behavior or creating additional main-function registers.
Runtime.TravelActive = function()
    return now() < (tonumber(Runtime.TravelUntil) or 0)
end

Runtime.RequestZoneTeleport = function(worldId, zone, reason)
    if not E.TeleportZone or type(worldId) ~= "string" then return false end

    zone = math.max(1, math.floor(tonumber(zone) or 1))
    local t = now()
    local currentWorld = getData("CurrentWorld")

    -- Same-world zone requests were the main source of unexplained bouncing. The
    -- farmer already moves directly to its selected enemy/NPC, so re-firing the
    -- game's zone teleport while fighting is unnecessary and disruptive.
    if currentWorld == worldId then
        Runtime.LastPlannedWorld = worldId
        Runtime.LastPlannedZone = zone
        return false
    end

    -- Do not stack duplicate travel requests while the server/transition controller
    -- is still processing the first one.
    if Runtime.TravelActive() then return false end
    if Runtime.LastTravelWorld == worldId
        and Runtime.LastTravelZone == zone
        and t - (tonumber(Runtime.LastTravelAt) or 0) < 2.5 then
        return false
    end

    -- Travel gets exclusive movement ownership. Clear stale combat positioning
    -- before firing the remote and keep the combat loop paused long enough for the
    -- replicated CurrentWorld/character position to settle.
    releaseDownFacingLock()
    Runtime.Target = nil
    Runtime.PositionTarget = nil
    Runtime.CurrentHoverHeight = nil
    Runtime.TargetBodyHeight = nil
    Runtime.TargetBodyWidth = nil
    setAutoSwing(false)

    Runtime.TravelUntil = t + 1.6
    Runtime.TravelWorld = worldId
    Runtime.TravelZone = zone
    Runtime.TravelReason = tostring(reason or "World travel")
    Runtime.LastTravelAt = t
    Runtime.LastTravelWorld = worldId
    Runtime.LastTravelZone = zone
    Runtime.LastPlannedWorld = worldId
    Runtime.LastPlannedZone = zone

    E.TeleportZone:FireServer(worldId, zone)
    return true
end

local function moveToQuestGiver(plan)
    if not Settings.QuestTravelToGiver then return true end
    local _, _, root = getCharacter()
    if not root then return false end
    local npc = findQuestGiver(plan)
    local cf = questGiverCFrame(npc)
    if not cf then return false end

    Runtime.QuestAcquiring = true
    Runtime.QuestAcquireUntil = now() + 1.0
    Runtime.Target = nil
    Runtime.PositionTarget = nil
    Runtime.CurrentHoverHeight = nil
    Runtime.TargetName = "Quest Giver: " .. tostring(plan.giverName or plan.id)
    releaseDownFacingLock()
    setAutoSwing(false)

    local target = cf * CFrame.new(0, 1.5, 4)
    root.CFrame = CFrame.lookAt(target.Position, cf.Position)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return (root.Position - cf.Position).Magnitude <= 14
end

local function sendNpcQuestAction(questId, action)
    if not NPCQuestAccept or type(questId) ~= "string" then return false end
    if action == "cancel" then
        NPCQuestAccept:FireServer(questId, "cancel")
    else
        NPCQuestAccept:FireServer(questId)
    end
    Runtime.LastQuestAcceptId = questId
    Runtime.LastQuestAcceptAt = now()
    return true
end

local function autoNPCQuest()
    if now() < (Runtime.ChestSweepUntil or 0) then return end
    if Runtime.LiveEventActive or now() < (Runtime.LiveEventJoiningUntil or 0) then return end
    -- NPC quest acquisition owns world/zone travel, so never let it compete with
    -- dungeon/tower/rotation queues or active runs. Combat inside those activities
    -- still uses the shared farm engine, but quest travel is a World Farm concern.
    if Settings.ActivityMode ~= "World Farm" or Runtime.Activity ~= "World" then return end
    if not NPCController or not NPCQuestAccept then return end

    if Runtime.PendingNpcQuest and now() >= (Runtime.PendingNpcQuestUntil or 0) then
        Runtime.PendingNpcQuest = nil
        Runtime.PendingNpcQuestUntil = 0
        Runtime.QuestReplaceFrom = nil
        Runtime.QuestReplaceTo = nil
        Runtime.QuestReplaceStartedAt = 0
        Runtime.QuestAcquiring = false
    end

    -- If a replacement cancellation was rejected or never replicated, abandon the
    -- switch instead of travelling/retrying forever. Farm the current quest for a
    -- while before reconsidering another replacement.
    if Runtime.QuestReplaceFrom
        and NPCController.ActiveQuestId == Runtime.QuestReplaceFrom
        and now() - (Runtime.QuestReplaceStartedAt or 0) >= 2.0 then
        Runtime.PendingNpcQuest = nil
        Runtime.PendingNpcQuestUntil = 0
        Runtime.QuestReplaceFrom = nil
        Runtime.QuestReplaceTo = nil
        Runtime.QuestReplaceStartedAt = 0
        Runtime.QuestReplaceCooldownUntil = now() + 30
        Runtime.QuestAcquiring = false
        Runtime.QuestAcquireUntil = 0
    end

    -- Keep cooldown/active data fresh without blocking the farm loop. The initial
    -- hydration happens as soon as the script loads; this is only a stale-state refresh.
    refreshAllNpcQuestStates(false)

    local id, def, state = activeNpcQuest()
    if id then
        if Runtime.PendingNpcQuest == id then
            Runtime.PendingNpcQuest = nil
            Runtime.PendingNpcQuestUntil = 0
            Runtime.QuestAcquiring = false
        end
        -- If a substantially better quest unlocks while the current one is still
        -- near the beginning, switch safely. Loot Up only allows one active NPC quest:
        -- a different Accept is reported as activeElsewhere, so cancel the old quest
        -- first and only accept the replacement after that state has cleared.
        local replacement = shouldReplaceActiveNpcQuest(id, def, state)
        if replacement and now() >= (Runtime.QuestReplaceCooldownUntil or 0) then
            Runtime.BestNpcQuest = replacement.id
            Runtime.BestNpcQuestGiver = replacement.giverName
            Runtime.BestNpcQuestScore = replacement.score
            Runtime.PendingNpcQuest = replacement.id
            Runtime.PendingNpcQuestUntil = now() + 12
            Runtime.QuestReplaceFrom = id
            Runtime.QuestReplaceTo = replacement.id
            Runtime.QuestReplaceStartedAt = now()
            Runtime.QuestAcquiring = true
            Runtime.QuestAcquireUntil = now() + 2.0
            Runtime.Target = nil
            Runtime.PositionTarget = nil
            Runtime.CurrentHoverHeight = nil
            Runtime.TargetName = string.format(
                "Switching quest: %s -> %s",
                tostring(id),
                tostring(replacement.id)
            )
            releaseDownFacingLock()
            setAutoSwing(false)

            -- The real NPC quest controller refuses a different quest while one is
            -- active (activeElsewhere). Cancel first, then accept the replacement on a
            -- later tick after the replicated state confirms the old quest is inactive.
            sendNpcQuestAction(id, "cancel")
            if type(NPCController.ApplyOptimisticCancel) == "function" then
                safe(NPCController.ApplyOptimisticCancel, NPCController, id)
            end
            task.delay(0.35, function()
                if Runtime.Alive and type(NPCController.RequestState) == "function" then
                    safe(NPCController.RequestState, NPCController, id)
                end
            end)
            return
        end

        Runtime.BestNpcQuest = id
        Runtime.BestNpcQuestGiver = NPCQuestGiverNameById[id] or def.name or id
        Runtime.BestNpcQuestScore = select(1, scoreNpcQuest(id, def, state))

        if npcQuestCompletion(state, def) then
            -- NPC quests are server auto-claimed and immediately restarted. Firing
            -- Accept here would toggle/cancel the freshly restarted quest. Just wait
            -- for the server's StateChanged("restarted") and refresh if it lingers.
            Runtime.Target = nil
            Runtime.CurrentQuestEnemy = nil
            Runtime.TargetName = "Quest complete • auto-claiming"
            setAutoSwing(false)
            if throttle("npcCompleteSync:" .. id, 0.8) and type(NPCController.RequestState) == "function" then
                task.spawn(function() safe(NPCController.RequestState, NPCController, id) end)
            end
        end
        return
    end

    local plan = refreshBestNpcQuestPlan()
    if not plan then return end

    -- If this quest state was never loaded, ask for only the selected quest now.
    if not plan.state and type(NPCController.RequestState) == "function" then
        safe(NPCController.RequestState, NPCController, plan.id)
        plan.state = NPCController.States and NPCController.States[plan.id]
        if npcQuestCooldown(plan.state) > 0 then
            refreshBestNpcQuestPlan()
            return
        end
    end

    local currentWorld = getData("CurrentWorld")
    local zone = npcQuestZone(plan.world, plan.def, plan.state)
    if currentWorld ~= plan.world then
        if E.TeleportZone then
            Runtime.QuestAcquiring = false
            Runtime.RequestZoneTeleport(plan.world, zone, "NPC quest world")
        end
        return
    end

    -- Move to the actual giver before firing the same Accept remote used by the
    -- normal quest dialogue. This also satisfies any server-side proximity check.
    if moveToQuestGiver(plan) or not Settings.QuestTravelToGiver then
        if now() - Runtime.LastQuestAcceptAt > 1.0 or Runtime.LastQuestAcceptId ~= plan.id then
            Runtime.TargetName = Runtime.QuestReplaceTo == plan.id
                and ("Accepting replacement: " .. tostring(plan.id))
                or ("Accepting quest: " .. tostring(plan.id))
            sendNpcQuestAction(plan.id)
            Runtime.PendingNpcQuest = plan.id
            Runtime.PendingNpcQuestUntil = now() + 10
            Runtime.QuestAcquiring = true
            Runtime.QuestAcquireUntil = now() + 2.0
            if type(NPCController.ApplyOptimisticAccept) == "function" then
                safe(NPCController.ApplyOptimisticAccept, NPCController, plan.id)
            end
            task.wait(0.25)
            if type(NPCController.RequestState) == "function" then
                safe(NPCController.RequestState, NPCController, plan.id)
            end
        end
    end
end

-- World progression --------------------------------------------------------------
local function desiredQuestWorld()
    if Runtime.LiveEventActive or now() < (Runtime.LiveEventJoiningUntil or 0) then return "World1" end
    if Settings.EventBossPriority then
        if workspace:GetAttribute("MageOfDarknessEvent") ~= nil
            or workspace:GetAttribute("KrampusEvent") ~= nil then
            if D.Worlds.World1 and worldUnlocked("World1") then return "World1" end
        end
    end
    local pendingId = Runtime.PendingNpcQuest
    local pendingWorld = pendingId and NPCQuestWorldById[pendingId] or nil
    if type(pendingWorld) == "string" and D.Worlds[pendingWorld] and worldUnlocked(pendingWorld) then
        return pendingWorld
    end
    local _, npcWorld = getNpcTarget()
    if type(npcWorld) == "string" and D.Worlds[npcWorld] and worldUnlocked(npcWorld) then return npcWorld end
    local planned = refreshBestNpcQuestPlan()
    if planned and type(planned.world) == "string" and D.Worlds[planned.world] and worldUnlocked(planned.world) then return planned.world end
    local _, questWorld = getIncompleteWorldQuestTarget()
    if type(questWorld) == "string" and D.Worlds[questWorld] and worldUnlocked(questWorld) then return questWorld end
    return nil
end

local function worldProgression()
    if now() < (Runtime.ChestSweepUntil or 0) then return end
    if not E.TeleportZone then return end
    if Runtime.LiveEventActive or now() < (Runtime.LiveEventJoiningUntil or 0) then
        if getData("CurrentWorld") ~= "World1" and throttle("liveEventWorld", 2.0) then
            Runtime.RequestZoneTeleport("World1", 1, "Live event")
        end
        return
    end
    local nextWorld = nextLockedWorld()
    if nextWorld and requirementsMet(nextWorld) and E.UnlockWorld then
        E.UnlockWorld:FireServer(nextWorld.id)
        task.wait(0.35)
    end
    local targetId = desiredQuestWorld()
    local targetInfo
    if targetId then
        for _, info in ipairs(orderedWorlds) do if info.id == targetId then targetInfo = info break end end
    end
    targetInfo = targetInfo or highestUnlockedWorld()
    if targetInfo then
        local zone
        local pendingId = Runtime.PendingNpcQuest
        if pendingId and NPCQuestWorldById[pendingId] == targetInfo.id then
            local pendingDef = D.NPCQuestDialog[pendingId]
            local pendingState = NPCController and NPCController.States and NPCController.States[pendingId]
            zone = npcQuestZone(targetInfo.id, pendingDef, pendingState)
        else
            local activeId, activeDef, activeState = activeNpcQuest()
            if activeId and NPCQuestWorldById[activeId] == targetInfo.id then
                -- Quest objectives override player-level routing. A high-level player
                -- can still be asked to kill an enemy from zone 1/2 of the same world.
                -- Multi-objective quests follow the first objective that is not finished.
                zone = npcQuestZone(targetInfo.id, activeDef, activeState)
            elseif Runtime.BestNpcQuest and NPCQuestWorldById[Runtime.BestNpcQuest] == targetInfo.id then
                local plannedDef = D.NPCQuestDialog[Runtime.BestNpcQuest]
                local plannedState = NPCController and NPCController.States and NPCController.States[Runtime.BestNpcQuest]
                zone = npcQuestZone(targetInfo.id, plannedDef, plannedState)
            else
                zone = bestZone(targetInfo, numData("Level"))
            end
        end
        local current = getData("CurrentWorld")
        if current ~= targetInfo.id then
            Runtime.RequestZoneTeleport(targetInfo.id, zone, "World progression")
        else
            -- Record the desired zone for status/planning, but never fire a same-world
            -- TeleportZone behind an active farm. Direct enemy/NPC movement already
            -- reaches the correct area without bouncing through the zone spawn.
            Runtime.LastPlannedWorld = targetInfo.id
            Runtime.LastPlannedZone = zone
        end
    end
end

-- Dungeon / tower ---------------------------------------------------------------
Runtime.ResolveDungeonGamemode = function()
    local requested = Settings.AdaptiveDungeonPlanning and "Smart" or tostring(Settings.DungeonGamemode or "Smart")
    if requested == "3Worlds" or requested == "Random" or requested == "Survival" then
        Runtime.DungeonSmartGamemode = requested
        return requested
    end

    local needs = Runtime.GetVariantMaterialNeeds and Runtime.GetVariantMaterialNeeds() or {}
    local chosen = "3Worlds"
    -- Rare variant materials are overwhelmingly a Random-mode specialty.
    if (tonumber(needs.Rare) or 0) > 0 then
        chosen = "Random"
    elseif standardQuestIncomplete("complete_5_dungeons") then
        chosen = "3Worlds"
    elseif standardQuestIncomplete("kill_250_dungeon_mobs") then
        -- Survival is the highest raw mob-throughput mode: 6-10 regular mobs plus
        -- special adds every wave. Smart mode exits once the weekly objective is done.
        chosen = "Survival"
    elseif (tonumber(needs.VeryRare) or 0) > 0 or (tonumber(needs.Normal) or 0) > 0 then
        chosen = "3Worlds"
    elseif numData("Level") >= 1000 and Settings.AutoDungeonGear == false then
        -- With immediate recipe/completion needs satisfied, Survival is useful as
        -- a long uninterrupted endgame material/Soul Crystal farm.
        chosen = "Survival"
    end
    Runtime.DungeonSmartGamemode = chosen
    return chosen
end

Runtime.DungeonDifficultyOrder = {"Easy", "Normal", "Hard", "Extreme"}
Runtime.DungeonDifficultyIndex = {Easy=1, Normal=2, Hard=3, Extreme=4}

Runtime.DungeonRewardRate = function(stat)
    if type(stat) ~= "table" or (tonumber(stat.completions) or 0) <= 0 then return nil end
    local elapsed = math.max(0.1, tonumber(stat.totalElapsed) or 0)
    local soulRate = (tonumber(stat.totalSoulCrystals) or 0) / elapsed
    local expRate = (tonumber(stat.totalExp) or 0) / elapsed
    local goldRate = (tonumber(stat.totalGold) or 0) / elapsed
    -- Soul Crystals are the unique dungeon progression currency; EXP/Gold are
    -- secondary signals so a faster lower difficulty can still win empirically.
    return soulRate * 2500 + expRate + goldRate * 0.10
end

Runtime.CurrentDungeonPower = function()
    local total = 0
    for _, picked in pairs(bestEquipmentBySlot()) do
        total = total + math.max(0, tonumber(picked.score) or 0)
    end
    return total
end

Runtime.ResolveDungeonDifficulty = function(gamemode)
    gamemode = tostring(gamemode or Runtime.DungeonRunGamemode or Runtime.DungeonSmartGamemode or "3Worlds")
    local requested = Settings.AdaptiveDungeonPlanning and "Smart" or tostring(Settings.DungeonDifficulty or "Smart")
    if Runtime.DungeonDifficultyIndex[requested] then
        Runtime.DungeonLastDifficulty = requested
        return requested
    end

    local current = tostring(Runtime.DungeonSmartDifficulty or "Normal")
    if not Runtime.DungeonDifficultyIndex[current] then current = "Normal" end
    local stats = Runtime.DungeonDifficultyStats
    local currentStat = stats[current] or {}
    local currentIndex = Runtime.DungeonDifficultyIndex[current] or 2

    -- Re-test a previously failed tier after meaningful account growth. This
    -- prevents one early failure from permanently pinning a later, much stronger build.
    if (tonumber(currentStat.consecutiveFails) or 0) >= 1 then
        local failureLevel = tonumber(currentStat.failureLevel) or math.huge
        local failurePower = tonumber(currentStat.failurePower) or math.huge
        local levelImproved = numData("Level") >= failureLevel + 25
        local powerNow = Runtime.CurrentDungeonPower()
        local powerImproved = failurePower > 0 and powerNow >= failurePower * 1.25
        if levelImproved or powerImproved then
            currentStat.consecutiveFails = 0
            Runtime.DungeonSmartTested[current] = false
        else
            currentIndex = math.max(1, currentIndex - 1)
            current = Runtime.DungeonDifficultyOrder[currentIndex]
            Runtime.DungeonSmartDifficulty = current
            Runtime.DungeonLastDifficulty = current
            return current
        end
    end

    -- Once a tier has proven stable, test the next *untested* tier. Tested tiers
    -- are compared by their measured reward rate below instead of being promoted blindly.
    local wins = tonumber(currentStat.consecutiveWins) or 0
    local promotionReady = wins >= 2
    if gamemode == "Survival" then
        promotionReady = promotionReady and (tonumber(currentStat.bestWave) or 0) >= 50
    end
    if promotionReady and currentIndex < #Runtime.DungeonDifficultyOrder then
        local nextDifficulty = Runtime.DungeonDifficultyOrder[currentIndex + 1]
        local nextStat = stats[nextDifficulty]
        if Runtime.DungeonSmartTested[nextDifficulty] and type(nextStat) == "table"
            and (tonumber(nextStat.consecutiveFails) or 0) >= 1 then
            local failureLevel = tonumber(nextStat.failureLevel) or math.huge
            local failurePower = tonumber(nextStat.failurePower) or math.huge
            local levelImproved = numData("Level") >= failureLevel + 25
            local powerNow = Runtime.CurrentDungeonPower()
            local powerImproved = failurePower > 0 and powerNow >= failurePower * 1.25
            if levelImproved or powerImproved then
                nextStat.consecutiveFails = 0
                Runtime.DungeonSmartTested[nextDifficulty] = false
            end
        end
        if not Runtime.DungeonSmartTested[nextDifficulty] then
            Runtime.DungeonSmartDifficulty = nextDifficulty
            Runtime.DungeonLastDifficulty = nextDifficulty
            return nextDifficulty
        end
    end

    -- For tiers with enough real samples, compare measured progression per second.
    -- A higher tier only stays selected when it is at least close to the best
    -- lower-tier rate; this accounts for travel/room overhead and actual account DPS.
    local bestDifficulty, bestRate
    for _, difficulty in ipairs(Runtime.DungeonDifficultyOrder) do
        local stat = stats[difficulty]
        local runs = type(stat) == "table" and (tonumber(stat.runs) or 0) or 0
        local completions = type(stat) == "table" and (tonumber(stat.completions) or 0) or 0
        local failures = type(stat) == "table" and (tonumber(stat.failures) or 0) or 0
        local successRate = runs > 0 and completions / runs or 0
        local rate = Runtime.DungeonRewardRate(stat)
        if runs >= 2 and completions >= 1 and successRate >= 0.70 and rate then
            if not bestRate or rate > bestRate then
                bestDifficulty, bestRate = difficulty, rate
            end
        end
    end
    if bestDifficulty then
        Runtime.DungeonSmartDifficulty = bestDifficulty
        Runtime.DungeonLastDifficulty = bestDifficulty
        return bestDifficulty
    end

    Runtime.DungeonSmartDifficulty = current
    Runtime.DungeonLastDifficulty = current
    return current
end

Runtime.DungeonCreatePayload = function()
    local gamemode = Runtime.ResolveDungeonGamemode()
    if Runtime.DungeonLastResolvedGamemode and Runtime.DungeonLastResolvedGamemode ~= gamemode then
        -- Difficulty performance is not comparable across the very different mode
        -- layouts. Re-learn conservatively whenever Smart mode changes its objective.
        Runtime.DungeonSmartDifficulty = "Normal"
        Runtime.DungeonDifficultyStats = {}
        Runtime.DungeonSmartTested = {}
    end
    Runtime.DungeonLastResolvedGamemode = gamemode
    return {
        difficulty = Runtime.ResolveDungeonDifficulty(gamemode),
        gamemode = gamemode,
        maxPlayers = math.clamp(
            tonumber(Settings.DungeonPlayers) or 1,
            1,
            tonumber(D.DungeonsData.MaxPlayersPerRun) or 5
        ),
        friendsOnly = Settings.DungeonFriendsOnly == true,
    }
end

Runtime.RecordDungeonReward = function(payload)
    if type(payload) ~= "table" then return end
    local difficulty = tostring(
        payload.difficulty
        or Runtime.DungeonRunDifficulty
        or Runtime.DungeonLastDifficulty
        or "Normal"
    )
    if not Runtime.DungeonDifficultyIndex[difficulty] then difficulty = "Normal" end

    local stat = Runtime.DungeonDifficultyStats[difficulty]
    if type(stat) ~= "table" then
        stat = {
            runs = 0, completions = 0, failures = 0,
            consecutiveWins = 0, consecutiveFails = 0,
            totalElapsed = 0, totalSoulCrystals = 0, totalExp = 0, totalGold = 0,
        }
        Runtime.DungeonDifficultyStats[difficulty] = stat
    end

    stat.runs = (tonumber(stat.runs) or 0) + 1
    local elapsed = tonumber(payload.elapsed)
    if not elapsed or elapsed <= 0 then
        elapsed = math.max(0, now() - (tonumber(Runtime.DungeonRunStartedAt) or now()))
    end
    stat.totalElapsed = (tonumber(stat.totalElapsed) or 0) + math.max(0, elapsed)
    stat.totalSoulCrystals = (tonumber(stat.totalSoulCrystals) or 0) + math.max(0, tonumber(payload.soulCrystals) or 0)
    stat.totalExp = (tonumber(stat.totalExp) or 0) + math.max(0, tonumber(payload.exp) or 0)
    stat.totalGold = (tonumber(stat.totalGold) or 0) + math.max(0, tonumber(payload.gold) or 0)
    stat.lastElapsed = elapsed
    stat.lastReason = tostring(payload.reason or "unknown")

    local gamemode = tostring(payload.gamemode or Runtime.DungeonRunGamemode or Settings.DungeonGamemode or "3Worlds")
    local completed
    if gamemode == "Survival" then
        local wave = math.max(
            1,
            math.floor(tonumber(payload.wave) or tonumber(Runtime.DungeonSurvivalWave) or 1)
        )
        stat.lastWave = wave
        stat.bestWave = math.max(tonumber(stat.bestWave) or 0, wave)
        -- Survival has no normal completion. Clearing the first boss floor proves
        -- the tier is viable; reaching wave 50 is strong enough to test upward.
        completed = wave >= 25
    else
        completed = payload.reason == "completed"
    end

    if completed then
        stat.completions = (tonumber(stat.completions) or 0) + 1
        stat.consecutiveWins = (tonumber(stat.consecutiveWins) or 0) + 1
        stat.consecutiveFails = 0
    else
        stat.failures = (tonumber(stat.failures) or 0) + 1
        stat.consecutiveFails = (tonumber(stat.consecutiveFails) or 0) + 1
        stat.consecutiveWins = 0
        stat.failureLevel = numData("Level")
        stat.failurePower = Runtime.CurrentDungeonPower()
    end

    Runtime.DungeonSmartTested[difficulty] = true
    Runtime.DungeonLastReward = payload
    Runtime.DungeonRunRewarded = true

    if Settings.DungeonDifficulty == "Smart" then
        if completed then
            Runtime.DungeonSmartDifficulty = difficulty
        else
            local index = Runtime.DungeonDifficultyIndex[difficulty] or 2
            Runtime.DungeonSmartDifficulty = Runtime.DungeonDifficultyOrder[math.max(1, index - 1)]
        end
    end
end

local function findPad(kind)
    local wanted = string.lower(kind)
    local cached = Runtime.CachedPads[wanted]
    if cached and cached.Parent then return cached end
    local _, _, root = getCharacter()
    local best, bestDist
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            local name = string.lower(obj.Name)
            local parentName = obj.Parent and string.lower(obj.Parent.Name) or ""
            if (name:find(wanted,1,true) or parentName:find(wanted,1,true)) and (name:find("pad",1,true) or parentName:find("pad",1,true)) then
                local dist = root and (obj.Position-root.Position).Magnitude or 0
                if not bestDist or dist < bestDist then best,bestDist=obj,dist end
            end
        end
    end
    Runtime.CachedPads[wanted] = best
    return best
end

local function standOnPad(pad)
    local _, _, root = getCharacter()
    if root and pad then
        Runtime.Target = nil
        Runtime.PositionTarget = nil
        Runtime.CurrentHoverHeight = nil
        releaseDownFacingLock()
        setAutoSwing(false)
        root.CFrame = pad.CFrame * CFrame.new(0, 3, 0)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
end

local towerPriority = {
    ["Smart"] = {damage=112,cooldown=100,drops=92,vampiric=58,fortified=55,speed=12},
    ["Damage First"] = {damage=115,cooldown=102,drops=78,vampiric=62,fortified=58,speed=12},
    ["Rewards First"] = {drops=115,damage=100,cooldown=92,vampiric=58,fortified=54,speed=12},
    ["Survival First"] = {vampiric=112,fortified=108,damage=100,cooldown=88,drops=70,speed=12},
}

Runtime.TowerUpgradeMarginal = function(id, stacks)
    local def = D.InfiniteTowerData.Upgrades and D.InfiniteTowerData.Upgrades[id]
    if type(def) ~= "table" then return 0, 0 end
    local currentStacks = math.max(0, math.floor(tonumber(stacks) or 0))

    if def.stat == "fortified" then
        local hpValue = math.max(0, tonumber(def.hpValue) or 0)
        local hpCap = math.max(0, tonumber(def.hpCap) or math.huge)
        local defenseValue = math.max(0, tonumber(def.defenseValue) or 0)
        local defenseCap = math.max(0, tonumber(def.defenseCap) or math.huge)
        local currentHp = math.min(hpValue * currentStacks, hpCap)
        local nextHp = math.min(hpValue * (currentStacks + 1), hpCap)
        local currentDefense = math.min(defenseValue * currentStacks, defenseCap)
        local nextDefense = math.min(defenseValue * (currentStacks + 1), defenseCap)
        -- Damage reduction is slightly more valuable than equal raw HP at deep floors.
        local marginal = (nextHp - currentHp) + (nextDefense - currentDefense) * 1.35
        local first = hpValue + defenseValue * 1.35
        return math.max(0, marginal), math.max(first, 0.000001)
    end

    local value = math.max(0, tonumber(def.value) or 0)
    local cap = math.max(0, tonumber(def.cap) or math.huge)
    local current = math.min(value * currentStacks, cap)
    local nextValue = math.min(value * (currentStacks + 1), cap)
    return math.max(0, nextValue - current), math.max(value, 0.000001)
end

Runtime.TowerUpgradeScore = function(id, stacks, payload)
    local marginal, firstMarginal = Runtime.TowerUpgradeMarginal(id, stacks)
    if marginal <= 0 then return -math.huge end

    local mode = tostring(Settings.TowerUpgrade or "Smart")
    local weights = towerPriority[mode] or towerPriority.Smart
    local base = tonumber(weights[id]) or 0
    local floor = math.max(1, math.floor(tonumber(
        (type(payload) == "table" and (payload.floor or payload.Floor))
        or Runtime.TowerFloor
        or 1
    ) or 1))

    if mode == "Smart" then
        -- The farm teleports directly to targets, so movement speed has very low value.
        -- As boss/Seraphim floors approach, clear-speed and survival matter more.
        local untilBoss = 25 - (floor % 25)
        if untilBoss == 25 then untilBoss = 0 end
        if untilBoss <= 5 then
            if id == "damage" then base = base + 24 end
            if id == "cooldown" then base = base + 18 end
            if id == "vampiric" then base = base + 12 end
            if id == "fortified" then base = base + 10 end
        end
        if floor >= 50 then
            if id == "vampiric" then base = base + 12 end
            if id == "fortified" then base = base + 10 end
        end
        if floor >= 100 then
            if id == "damage" then base = base + 12 end
            if id == "cooldown" then base = base + 10 end
        end
    end

    -- A partially useful final stack is worth only its actual uncapped fraction.
    return base * math.clamp(marginal / firstMarginal, 0, 1)
end

local function chooseTowerUpgrade(payload)
    if not E.InfiniteTowerPad or type(payload) ~= "table" then return end
    local choices = payload.choices or payload.Choices
    if type(choices) ~= "table" then return end

    local pick, bestScore, pickStacks
    for _, choice in ipairs(choices) do
        local id = type(choice) == "table" and (choice.id or choice.Id) or choice
        if type(id) == "string" then
            local stacks = type(choice) == "table" and tonumber(choice.currentStacks or choice.CurrentStacks)
                or tonumber(Runtime.TowerUpgradeStacks[id])
                or 0
            Runtime.TowerUpgradeStacks[id] = math.max(0, math.floor(stacks))
            local score = Runtime.TowerUpgradeScore(id, stacks, payload)
            if not bestScore or score > bestScore then
                pick, bestScore, pickStacks = id, score, stacks
            end
        end
    end

    if pick and bestScore and bestScore > -math.huge then
        E.InfiniteTowerPad:FireServer("chooseUpgrade", pick)
        Runtime.TowerUpgradeStacks[pick] = math.max(0, math.floor(tonumber(pickStacks) or 0)) + 1
        Runtime.TowerLastUpgrade = pick
    end
end

local function ownsTowerSpeed()
    local ids = {3604339134, 3475764387}
    for _, id in ipairs(ids) do
        local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, LocalPlayer.UserId, id)
        if ok and owns then return true end
    end
    return false
end

local towerSpeedChecked, towerSpeedOwned = false, false
local function activityEntryTick()
    if not Settings.Master then return end
    if Runtime.LiveEventActive then
        Runtime.Activity = "LiveEvent"
        if E.TeleportZone and getData("CurrentWorld") ~= "World1" and throttle("liveEventWorld", 2.0) then
            Runtime.RequestZoneTeleport("World1", 1, "Live event entry")
        end
        return
    end
    if now() < (Runtime.LiveEventJoiningUntil or 0) then
        Runtime.Activity = "LiveEventQueue"
        Runtime.Target = nil
        setAutoSwing(false)
        return
    end
    local mode = Settings.ActivityMode
    if mode == "World Farm" then
        Runtime.Activity = "World"
        return
    end
    if Runtime.DungeonSession then Runtime.Activity = "Dungeon" return end
    if Runtime.TowerSession then Runtime.Activity = "Tower" return end

    local effectiveMode = mode
    if mode == "Rotation" then
        effectiveMode = Runtime.RotationChoice or "Dungeons"
    end

    if effectiveMode == "Dungeons" then
        Runtime.Activity = "DungeonQueue"
        if not Runtime.DungeonConfig then
            local pad = findPad("dungeon")
            if pad then standOnPad(pad) end
        end
        if Runtime.DungeonConfig and E.DungeonPad and throttle("dungeonCreate", 1.2) then
            E.DungeonPad:FireServer("create", Runtime.DungeonCreatePayload())
        end
        return
    end

    if effectiveMode == "Infinite Tower" then
        Runtime.Activity = "TowerQueue"
        local pad = findPad("tower")
        if pad then standOnPad(pad) end
        if E.InfiniteTowerPad and type(Runtime.TowerPadState) == "table" then
            local state = Runtime.TowerPadState.state or Runtime.TowerPadState.State
            local first = Runtime.TowerPadState.isFirstJoiner == true
            local openState = D.InfiniteTowerData.PadState and D.InfiniteTowerData.PadState.Open or "Open"
            local lockedState = D.InfiniteTowerData.PadState and D.InfiniteTowerData.PadState.Locked or "Locked"
            if first and (state == openState or state == lockedState or state == "Open" or state == "Locked") and throttle("towerLaunch", 0.6) then
                E.InfiniteTowerPad:FireServer("launch")
            end
        end
    end
end

if E.DungeonSession then
    connect(E.DungeonSession.OnClientEvent, function(payload)
        if type(payload) ~= "table" then return end
        if payload.type == "configurationOpened" then
            Runtime.DungeonConfig = payload
            if Settings.Master and (Settings.ActivityMode == "Dungeons" or Settings.ActivityMode == "Rotation") and E.DungeonPad then
                E.DungeonPad:FireServer("create", Runtime.DungeonCreatePayload())
            end
        elseif payload.type == "runEntered" then
            Runtime.DungeonConfig = nil
            Runtime.DungeonSession = payload
            Runtime.DungeonRunStartedAt = now()
            Runtime.DungeonRunDifficulty = payload.difficulty or Runtime.DungeonLastDifficulty or Runtime.ResolveDungeonDifficulty()
            Runtime.DungeonRunGamemode = payload.gamemode or Runtime.DungeonLastResolvedGamemode or Runtime.ResolveDungeonGamemode()
            Runtime.DungeonRunRewarded = false
            Runtime.DungeonSurvivalWave = Runtime.DungeonRunGamemode == "Survival"
                and math.max(1, math.floor(tonumber(payload.wave) or 1))
                or 0
            Runtime.Activity = "Dungeon"
        elseif payload.type == "survivalWave" then
            Runtime.DungeonSurvivalWave = math.max(
                tonumber(Runtime.DungeonSurvivalWave) or 0,
                math.floor(tonumber(payload.wave) or 0)
            )
        elseif payload.type == "dungeonReward" then
            Runtime.RecordDungeonReward(payload)
        elseif payload.type == "configurationClosed" then
            Runtime.DungeonConfig = nil
        elseif payload.type == "padLeft" then
            Runtime.DungeonConfig = nil
        elseif payload.type == "runExited" then
            Runtime.DungeonConfig = nil
            Runtime.DungeonSession = nil
            Runtime.DungeonRunStartedAt = 0
            Runtime.DungeonRunDifficulty = nil
            Runtime.DungeonRunGamemode = nil
            Runtime.DungeonSurvivalWave = 0
            Runtime.Activity = "World"
            if Settings.ActivityMode == "Rotation" then Runtime.RotationChoice = "Infinite Tower" end
        end
    end)
end

if E.InfiniteTowerSession then
    connect(E.InfiniteTowerSession.OnClientEvent, function(payload)
        if type(payload) ~= "table" then return end
        if payload.type == "padUpdate" then
            Runtime.TowerPadState = payload
        elseif payload.type == "padLeft" then
            Runtime.TowerPadState = nil
        elseif payload.type == "runEntered" then
            Runtime.TowerSession = payload
            Runtime.TowerFloor = math.max(1, math.floor(tonumber(payload.floor) or 1))
            Runtime.TowerUpgradeStacks = {}
            Runtime.TowerLastUpgrade = nil
            Runtime.Activity = "Tower"
            if Settings.Tower2xIfOwned and E.InfiniteTowerPad then
                if not towerSpeedChecked then towerSpeedChecked=true towerSpeedOwned=ownsTowerSpeed() end
                if towerSpeedOwned then E.InfiniteTowerPad:FireServer("setSpeedMultiplier", 2) end
            end
        elseif payload.type == "floorUpdate" then
            Runtime.TowerFloor = math.max(1, math.floor(tonumber(payload.floor) or Runtime.TowerFloor or 1))
        elseif payload.type == "upgradeChoices" then
            if tonumber(payload.floor) then
                Runtime.TowerFloor = math.max(1, math.floor(tonumber(payload.floor)))
            end
            chooseTowerUpgrade(payload)
        elseif payload.type == "runExited" then
            Runtime.TowerSession = nil
            Runtime.TowerPadState = nil
            Runtime.TowerFloor = 0
            Runtime.TowerUpgradeStacks = {}
            Runtime.TowerLastUpgrade = nil
            Runtime.Activity = "World"
            if Settings.ActivityMode == "Rotation" then Runtime.RotationChoice = "Dungeons" end
        end
    end)
end

-- Live Event / World Eater --------------------------------------------------------
-- Only genuine server join prompts are accepted.  No admin/start remote is ever
-- sent; this simply answers the same prompt the normal client displays.
if E.LiveEvent then
    connect(E.LiveEvent.OnClientEvent, function(action, payload)
        if action == "joinPrompt" and type(payload) == "table" then
            Runtime.LiveEventAvailable = true
            local sessionId = payload.sessionId
            local expiresAt = tonumber(payload.expiresAt) or 0
            if Settings.Master and Settings.AutoLiveEvent and type(sessionId) == "string" then
                if expiresAt <= 0 or workspace:GetServerTimeNow() < expiresAt then
                    E.LiveEvent:FireServer("joinResponse", {accepted = true, sessionId = sessionId})
                    Runtime.LiveEventSessionId = sessionId
                    Runtime.LiveEventJoiningUntil = now() + 12
                    Runtime.Activity = "LiveEventQueue"
                    Runtime.QuestAcquiring = false
                    Runtime.Target = nil
                end
            end
        elseif action == "joinPromptCancel" then
            Runtime.LiveEventAvailable = false
        elseif action == "state" and type(payload) == "table" then
            Runtime.LiveEventAvailable = payload.eventAvailable == true
            Runtime.LiveEventSessionId = payload.sessionId or Runtime.LiveEventSessionId
            Runtime.LiveEventActive = payload.active == true and payload.joined == true
            if Runtime.LiveEventActive then
                Runtime.LiveEventJoiningUntil = 0
                Runtime.Activity = "LiveEvent"
                Runtime.Target = nil
                Runtime.TargetName = "World Eater"
                Runtime.QuestAcquiring = false
            elseif Runtime.Activity == "LiveEvent" or Runtime.Activity == "LiveEventQueue" then
                Runtime.LiveEventJoiningUntil = 0
                Runtime.Target = nil
                Runtime.TargetName = "None"
                Runtime.LiveEventSessionId = nil
                Runtime.Activity = "World"
            end
        end
    end)
end

-- SkillTree offer listener.
if E.SkillTree then
    connect(E.SkillTree.OnClientEvent, function(action, payload)
        if action == "Offer" and type(payload) == "table" then
            Runtime.PotentialOffer = payload
            if Settings.Master and Settings.AutoPotentialTree then
                task.defer(choosePotentialOffer, payload)
            end
        elseif action == "Chosen" or action == "State" then
            Runtime.PotentialOffer = nil
        end
    end)
end

-- Loot collection uses the game's own capacity-aware controller when available.
local function updateAutoLoot()
    local loot = Controllers.Render and Controllers.Render.LootDrop
    if loot and type(loot.ToggleAutoCollect) == "function" then
        safe(loot.ToggleAutoCollect, loot, Settings.Master and Settings.AutoLoot)
    end
end

-- Awakening is deliberately opt-in. Ascending resets the run; max-awakening
-- race rerolls are a separate non-premium path that only resets Gold/Shards.
Runtime.ResolveRaceTarget = function()
    local choice = tostring(Settings.RaceTarget or "Smart Farming (Angel)")
    if choice == "Keep Current" then return nil end
    if choice:find("Angel", 1, true) then return "angel" end
    if choice:find("Elf", 1, true) then return "elf" end
    if choice:find("Wizard", 1, true) then return "wizard" end
    if choice:find("Dwarf", 1, true) then return "dwarf" end
    return "angel"
end

Runtime.RaceName = function(raceId)
    if type(raceId) ~= "string" or raceId == "" then return "Human" end
    local def = D.RacesData[raceId]
    if type(def) == "table" and type(def.name) == "string" then return def.name end
    return raceId:gsub("^%l", string.upper)
end

Runtime.RaceRerollReady = function()
    local maxAwakening = tonumber(D.AwakeningData.MAX_AWAKENING) or 3
    if math.floor(numData("Awakening")) < maxAwakening then return false end
    local req = type(D.AwakeningData.Reroll) == "table" and D.AwakeningData.Reroll or {}
    return numData("Gold") >= (tonumber(req.Gold) or math.huge)
        and numData("Shards") >= (tonumber(req.Shards) or math.huge)
end

Runtime.AutoRaceRerollTick = function()
    if not Settings.AutoRaceReroll or not E.Awakening then return false end
    local targetRace = Runtime.ResolveRaceTarget()
    if not targetRace then return false end
    local currentRace = getData("Race")
    if currentRace == targetRace then return false end
    if not Runtime.RaceRerollReady() then return false end
    if Runtime.RaceRerollPending and now() < (Runtime.RaceRerollPendingUntil or 0) then return false end

    -- The normal max-awakening Request consumes only in-game Gold/Shards.
    -- Never call the paid result-screen reroll product (developer product 3602682739).
    Runtime.RaceRerollPending = true
    Runtime.RaceRerollPendingUntil = now() + 12
    E.Awakening:FireServer("Request")
    return true
end

local function autoAwaken()
    if not E.Awakening then return end
    local current = math.floor(numData("Awakening"))
    if current >= (tonumber(D.AwakeningData.MAX_AWAKENING) or 3) then return end
    local req = D.AwakeningData.Ascends and D.AwakeningData.Ascends[current + 1]
    if type(req) ~= "table" then return end
    if numData("Level") >= (tonumber(req.Level) or math.huge)
        and numData("Shards") >= (tonumber(req.Shards) or math.huge)
        and numData("Gold") >= (tonumber(req.Gold) or math.huge) then
        E.Awakening:FireServer("Request")
    end
end

if E.Awakening then
    connect(E.Awakening.OnClientEvent, function(action, payload)
        if type(payload) ~= "table" then
            if action == "Error" then
                Runtime.RaceRerollPending = false
                Runtime.RaceRerollPendingUntil = 0
            end
            return
        end

        local mode = payload.mode
        if action == "Error" then
            Runtime.RaceRerollPending = false
            Runtime.RaceRerollPendingUntil = 0
            return
        end

        if mode == "reroll" then
            Runtime.RaceRerollPending = false
            Runtime.RaceRerollPendingUntil = 0
            Runtime.LastRaceResult = payload.raceId or getData("Race")
            Runtime.LastRaceResultAt = now()
            if Settings.Master and Settings.AutoRaceReroll and payload.token then
                task.delay(0.8, function()
                    if Runtime.Alive and Settings.Master and Settings.AutoRaceReroll then
                        E.Awakening:FireServer("FinishCutscene", payload.token)
                    end
                end)
            end
            return
        end

        if Settings.Master and Settings.AutoAwaken and payload.token
            and (action == "Result" or action == "AwakeningResult" or action == "Success" or mode == "ascend") then
            task.delay(1.0, function()
                if Runtime.Alive and Settings.Master and Settings.AutoAwaken then
                    E.Awakening:FireServer("FinishCutscene", payload.token)
                end
            end)
        end
    end)
end

-- Core worker loops --------------------------------------------------------------
task.spawn(function()
    while Runtime.Alive do
        if Settings.Master then
            if Runtime.QuestAcquiring and now() >= (Runtime.QuestAcquireUntil or 0) then
                Runtime.QuestAcquiring = false
            end
            if Runtime.QuestAcquiring or Runtime.TravelActive() or now() < (Runtime.ChestSweepUntil or 0) then
                Runtime.Target = nil
                releaseDownFacingLock()
                setAutoSwing(false)
            elseif Runtime.Activity == "World" or Runtime.Activity == "Dungeon" or Runtime.Activity == "Tower" or Runtime.Activity == "LiveEvent" then
                local target = Runtime.Target
                if not liveEnemy(target) then
                    finishTargetTiming(target)
                    target = chooseEnemy()
                    Runtime.Target = target
                    beginTargetTiming(target)
                else
                    beginTargetTiming(target)
                end
                Runtime.TargetName = target and target.Name or "None"
                if target then
                    moveToEnemy(target)
                    setAutoSwing(true)
                else
                    setAutoSwing(false)
                end
            else
                setAutoSwing(false)
            end
        else
            Runtime.Target = nil
            Runtime.TargetName = "None"
            setAutoSwing(false)
        end
        task.wait(0.055)
    end
end)

task.spawn(function()
    while Runtime.Alive do
        if Settings.Master and Settings.AutoSkills and not Runtime.TravelActive() and now() >= (Runtime.ChestSweepUntil or 0) and (Runtime.Activity == "World" or Runtime.Activity == "Dungeon" or Runtime.Activity == "Tower" or Runtime.Activity == "LiveEvent") then
            local combat = Controllers.Combat
            if Runtime.Target and liveEnemy(Runtime.Target) and combat and type(combat.Skill) == "function" and not combat._skillQueued then
                local skills = tableData("Skills")
                local serverNow = workspace:GetServerTimeNow()
                for offset = 0, 2 do
                    local slot = ((math.max(1, tonumber(Runtime.NextSkillSlot) or 1) - 1 + offset) % 3) + 1
                    local skillId = skills[tostring(slot)] or skills[slot]
                    if skillId and skillSlotAvailable(slot) then
                        local cd = combat.Cooldowns and combat.Cooldowns[skillId]
                        local readyAt = type(cd) == "table" and tonumber(cd[1]) or 0
                        local debounceKey = "skill" .. tostring(skillId) .. "DB"
                        if readyAt <= serverNow and combat[debounceKey] ~= true then
                            safe(combat.Skill, combat, slot)
                            Runtime.NextSkillSlot = (slot % 3) + 1
                            break
                        end
                    end
                end
            end
        end
        task.wait(0.10)
    end
end)

connect(RunService.Stepped, function()
    if Settings.Master and Settings.Noclip then setNoclip(true) else setNoclip(false) end
end)

-- Final render-time ownership prevents game combat/humanoid facing code from
-- producing even one visible upright frame between farm ticks. Position and
-- pitch come from one stable basis; no lookAt singularity or corrective spam.
local facingSignal = RunService.PreRender or RunService.RenderStepped
if facingSignal then
    connect(facingSignal, applyDownFacingLock)
end

-- Frequently-changing positive progression.
task.spawn(function()
    while Runtime.Alive do
        if Settings.Master then
            updateAutoLoot()
            if (Runtime.LiveEventActive or now() < (Runtime.LiveEventJoiningUntil or 0)) and throttle("world", 2.0) then
                safe(worldProgression)
            elseif Settings.AutoWorlds and Settings.ActivityMode == "World Farm" and throttle("world", 3.5) then
                safe(worldProgression)
            end
            if Settings.AutoWorlds and Settings.AutoBalanceWorldCurrency
                and Settings.ActivityMode == "World Farm" and throttle("currencyBalance", 5.0) then
                safe(autoBalanceWorldCurrency)
            end
            if Settings.AutoGoldMerchant and throttle("goldMerchant", 6.0) then safe(Runtime.AutoGoldMerchantTick) end
            if Settings.AutoSkipTutorial and throttle("tutorialSkip", 4.0) then safe(Runtime.AutoSkipTutorialTick) end
            if Settings.AutoTokenUpgrades and throttle("tokenUpgrade", 10.0) then safe(Runtime.AutoTokenUpgradeTick) end
            if Settings.AutoStats and throttle("stats", 2.0) then safe(autoSpendStats) end
            if Settings.AutoEquip and throttle("equip", 2.1) then safe(autoEquipBest) end
            if Settings.AutoRetrieveVariantBank and throttle("variantBankWithdraw", 7.0) then safe(Runtime.AutoWithdrawVariantBankTick) end
            if Settings.AutoVariantUpgrade and throttle("variant", 3.0) then safe(autoVariantUpgrade) end
            if Settings.AutoBankOverflow and throttle("bankOverflow", 6.0) then safe(Runtime.AutoBankOverflowTick) end
            if Settings.AutoSell and throttle("sell", 4.0) then safe(autoSellJunk) end
            if Settings.AutoForge and throttle("forge", 1.7) then safe(autoForge) end
            if Settings.AutoEnchantWeapon and throttle("enchantWeapon", 1.15) then safe(autoEnchantWeapon) end
            if Settings.AutoEnchantArmor and throttle("enchantArmor", 1.15) then safe(autoEnchantArmor) end
            if Settings.AutoRunes and throttle("runes", 1.25) then safe(autoRunes) end
            if (Settings.AutoUsePotions or Settings.AutoDungeonShopDeals or Settings.AutoDungeonGear)
                and throttle("dungeonEconomy", 2.6) then safe(autoDungeonEconomy) end
            if Settings.AutoPets and throttle("pets", 5.0) then safe(autoEquipPets) end
            if Runtime.Activity == "Dungeon" and Runtime.DungeonRunGamemode == "Survival"
                and Settings.DungeonGamemode == "Smart" and E.DungeonPad
                and not standardQuestIncomplete("kill_250_dungeon_mobs")
                and throttle("smartSurvivalExit", 3.0) then
                local nextMode = Runtime.ResolveDungeonGamemode()
                if nextMode ~= "Survival" then
                    E.DungeonPad:FireServer("leaveRun")
                end
            end
        else
            updateAutoLoot()
        end
        task.wait(0.25)
    end
end)

-- Skill/quest progression kept below economy rate limits.
task.spawn(function()
    while Runtime.Alive do
        if Settings.Master then
            if Settings.AutoQuests and throttle("questclaim", 8) then safe(claimStandardQuests) end
            if Settings.AutoChestQuests and throttle("chestQuest", 1.5) then safe(Runtime.AutoChestQuestTick) end
            if Settings.AutoNPCQuests and throttle("npcquests", 3.0) then safe(autoNPCQuest) end
            if Settings.AutoSkillTree and throttle("stdtree", 2.0) then safe(autoBuyStandardTree) end
            if Settings.AutoPotentialTree and throttle("potential", 1.0) then safe(autoPotential) end
            if Settings.AutoSkillRoll and throttle("skillroll", 2.2) then safe(autoRollSkills) end
            if Settings.AutoSkillEvolve and throttle("evolve", 5.0) then safe(autoEvolveSkills) end
            if Settings.AutoAwaken and throttle("awaken", 12) then safe(autoAwaken) end
            if Settings.AutoRaceReroll and throttle("raceReroll", 3.0) then safe(Runtime.AutoRaceRerollTick) end
        end
        task.wait(0.35)
    end
end)

-- Activity coordinator.
task.spawn(function()
    while Runtime.Alive do
        if Settings.Master and throttle("activity", 1.0) then safe(activityEntryTick) end
        task.wait(0.25)
    end
end)

-- Low-frequency rewards.
task.spawn(function()
    while Runtime.Alive do
        if Settings.Master then
            if (Settings.AutoDaily or Settings.AutoPlaytime) and throttle("rewards", 20) then safe(claimRoutineRewards) end
            if Settings.AutoSeason and throttle("season", 25) then safe(seasonClaims) end
            if Settings.AutoBasicSpin and throttle("basicspin", 18) then safe(autoBasicSpin) end
            if Settings.AutoPremiumFreeSpin and throttle("premiumFreeSpin", 30) then safe(Runtime.AutoPremiumFreeSpinTick) end
            if Settings.AutoSeasonSpin and throttle("seasonspin", 15) then safe(autoSeasonSpin) end
            if Settings.AutoEventChests and throttle("eventChest", 12) then safe(Runtime.AutoEventChestTick) end
            if Settings.AutoCodes and throttle("codes", 45) then safe(redeemCodes) end
            if Settings.AutoGroupReward and throttle("group", 60) then safe(groupReward) end
            if Settings.AutoClanQuests and throttle("clan", 45) then safe(autoClanClaim) end
            if Settings.AutoClanRewards and throttle("clanRewards", 60) then safe(autoClanRewards) end
        end
        task.wait(1)
    end
end)

local function describeQuestPlan()
    if Runtime.TravelActive() then return "Traveling: " .. tostring(Runtime.TravelReason or "World travel") end
    if now() < (Runtime.ChestSweepUntil or 0) then return "Discovering world chest for Daily/Weekly quest" end
    if Runtime.LiveEventActive then return "Paused for World Eater" end
    if now() < (Runtime.LiveEventJoiningUntil or 0) then return "Paused for World Eater queue" end

    local pendingId = Runtime.PendingNpcQuest
    if type(pendingId) == "string" then
        local giver = NPCQuestGiverNameById[pendingId] or pendingId
        if Runtime.QuestReplaceFrom then
            return string.format("Switching safely -> %s @ %s", pendingId, giver)
        end
        return string.format("Accepting -> %s @ %s", pendingId, giver)
    end

    local id, def, state = activeNpcQuest()
    if id and def and state then
        local giver = NPCQuestGiverNameById[id] or def.name or id
        if npcQuestCompletion(state, def) then
            return string.format("%s @ %s • complete / auto-restart", id, giver)
        end
        local objective = npcQuestCurrentObjective(def, state)
        if objective then
            local enemy = objective.enemy or objective.enemyName or objective.id or "Enemy"
            local target = math.max(0, tonumber(objective.target or objective.amount) or 0)
            local progress = type(state.progress) == "table" and math.max(0, tonumber(state.progress[enemy]) or 0) or 0
            if Runtime.BestFarmEnemy and enemy == Runtime.BestFarmEnemy then
                return string.format("%s @ %s • BEST %s %d/%d", id, giver, tostring(enemy), math.floor(progress), math.floor(target))
            end
            return string.format("%s @ %s • %s %d/%d", id, giver, tostring(enemy), math.floor(progress), math.floor(target))
        end
        return string.format("%s @ %s", id, giver)
    end

    if Runtime.BestNpcQuest then
        local giver = Runtime.BestNpcQuestGiver or NPCQuestGiverNameById[Runtime.BestNpcQuest] or Runtime.BestNpcQuest
        if Runtime.BestFarmEnemy then
            return string.format("Next: %s @ %s • target %s", Runtime.BestNpcQuest, giver, Runtime.BestFarmEnemy)
        end
        return string.format("Next: %s @ %s", Runtime.BestNpcQuest, giver)
    end
    return "None available"
end

-- UI ----------------------------------------------------------------------------
-- v1.5.1: simplified user-facing layout. The automation remains comprehensive,
-- but normal users only see the choices that materially change how the farm runs.
-- Rare tuning is isolated in Advanced so the default experience stays clean.
Runtime.Window = PuckUI:CreateWindow({
    Name = "PuckAFK Hub · Loot Up",
    GuiName = "PuckAFK_LootUp",
    ConfigId = "LootUp",
    Width = 520,
    Height = 560,
})

Runtime.HomeTab = Runtime.Window:CreateTab("Home")
Runtime.FarmTab = Runtime.Window:CreateTab("Farm")
Runtime.ProgressTab = Runtime.Window:CreateTab("Progress")
Runtime.ActivityTab = Runtime.Window:CreateTab("Activities")
Runtime.AdvancedTab = Runtime.Window:CreateTab("Advanced")
Runtime.SettingsTab = Runtime.Window:CreateTab("Settings")

-- Home --------------------------------------------------------------------------
Runtime.HomeTab:CreateSection("Autofarm")
Runtime.StatusParagraph = Runtime.HomeTab:CreateParagraph({
    Title = "Status",
    Content = "Ready. Turn on Smart Autofarm to begin.",
    Height = 94,
})
Runtime.HomeTab:CreateToggle({
    Name = "Smart Autofarm",
    CurrentValue = Settings.Master,
    Flag = "MasterAutofarm",
    Callback = function(v)
        Settings.Master = v == true
        updateAutoLoot()
        Runtime.ApplyAFKPerformanceMode(Settings.Master and Settings.AFKPerformanceMode)
        if not Settings.Master then
            Runtime.Target = nil
            Runtime.PositionTarget = nil
            Runtime.CurrentHoverHeight = nil
            Runtime.TargetBodyHeight = nil
            Runtime.TargetBodyWidth = nil
            releaseDownFacingLock()
            setAutoSwing(false)
            setNoclip(false)
        end
    end,
})
Runtime.HomeTab:CreateDropdown({
    Name = "What To Farm",
    Options = {"World Farm", "Dungeons", "Infinite Tower", "Rotation"},
    CurrentOption = Settings.ActivityMode,
    Flag = "ActivityMode",
    Callback = function(v)
        Settings.ActivityMode = normalizeChoice(v) or "World Farm"
        if Settings.ActivityMode == "World Farm" then Runtime.Activity = "World" end
    end,
})
Runtime.HomeTab:CreateLabel("Recommended: World Farm + Smart strategy. The script handles progression, gear, quests and upgrades automatically.")
Runtime.HomeTab:CreateSection("How It Works")
Runtime.HomeTab:CreateLabel("1. Turn on Smart Autofarm")
Runtime.HomeTab:CreateLabel("2. Choose what you want to farm")
Runtime.HomeTab:CreateLabel("3. Leave Smart options enabled unless you want custom behavior")

-- Farm --------------------------------------------------------------------------
Runtime.FarmTab:CreateSection("Farming")
Runtime.FarmTab:CreateDropdown({Name="Farm Strategy",Options={"Smart","Highest Level","Bosses","Closest"},CurrentOption=Settings.FarmStrategy,Flag="FarmStrategy",Callback=function(v)
    Settings.FarmStrategy=normalizeChoice(v) or "Smart"
    Runtime.Target=nil
    Runtime.BestNpcQuest=nil
    Runtime.BestFarmEnemy=nil
    refreshBestNpcQuestPlan()
end})
Runtime.FarmTab:CreateToggle({Name="Smart Quests",CurrentValue=Settings.AutoQuests and Settings.AutoNPCQuests and Settings.QuestMatchBestEnemy,Flag="SimpleSmartQuests",Callback=function(v)
    local on = v == true
    Settings.QuestPriority = on
    Settings.NPCQuestPriority = on
    Settings.AutoQuests = on
    Settings.AutoChestQuests = on
    Settings.AutoNPCQuests = on
    Settings.QuestMatchBestEnemy = on
    Settings.QuestTravelToGiver = on
    Settings.SmartQuestReplacement = on
    Settings.AdaptiveQuestScoring = on
    Runtime.BestNpcQuest = nil
    Runtime.BestFarmEnemy = nil
    if on then refreshBestNpcQuestPlan() end
end})
Runtime.FarmTab:CreateToggle({Name="Auto Skills",CurrentValue=Settings.AutoSkills,Flag="AutoSkills",Callback=function(v) Settings.AutoSkills=v==true end})
Runtime.FarmTab:CreateToggle({Name="Prioritize Event Bosses",CurrentValue=Settings.EventBossPriority,Flag="EventBossPriority",Callback=function(v) Settings.EventBossPriority=v==true end})
Runtime.FarmTab:CreateSection("Positioning")
Runtime.FarmTab:CreateToggle({Name="Look Straight Down At Enemy",CurrentValue=Settings.PerfectDownFacing,Flag="PerfectDownFacing",Callback=function(v)
    Settings.PerfectDownFacing=v==true
    if not Settings.PerfectDownFacing then releaseDownFacingLock() end
end})
Runtime.FarmTab:CreateSlider({Name="Distance Above Enemy",Range={0,20},Increment=0.5,CurrentValue=Settings.HoverHeight,Suffix=" studs",Flag="HoverHeight",Callback=function(v)
    Settings.HoverHeight=tonumber(v) or 6
    Runtime.CurrentHoverHeight=nil
end})
Runtime.FarmTab:CreateToggle({Name="Noclip While Farming",CurrentValue=Settings.Noclip,Flag="Noclip",Callback=function(v) Settings.Noclip=v==true end})
Runtime.FarmTab:CreateLabel("Smart height is enabled by default, so large bosses automatically get more clearance.")

-- Progress ----------------------------------------------------------------------
Runtime.ProgressTab:CreateSection("Main Progression")
Runtime.ProgressTab:CreateToggle({Name="Auto World Progression",CurrentValue=Settings.AutoWorlds,Flag="AutoWorlds",Callback=function(v) Settings.AutoWorlds=v==true end})
Runtime.ProgressTab:CreateToggle({Name="Smart Spending",CurrentValue=Settings.AutoBalanceWorldCurrency and Settings.AutoGoldMerchant and Settings.AutoTokenUpgrades,Flag="SimpleSmartSpending",Callback=function(v)
    local on = v == true
    Settings.AutoBalanceWorldCurrency = on
    Settings.AutoGoldMerchant = on
    Settings.AutoTokenUpgrades = on
end})
Runtime.ProgressTab:CreateToggle({Name="Auto Spend Stats",CurrentValue=Settings.AutoStats,Flag="AutoStats",Callback=function(v) Settings.AutoStats=v==true end})
Runtime.ProgressTab:CreateDropdown({Name="Stat Build",Options={"Smart","Balanced","Damage","Survival"},CurrentOption=Settings.StatBuild,Flag="StatBuild",Callback=function(v) Settings.StatBuild=normalizeChoice(v) or "Smart" end})
Runtime.ProgressTab:CreateSection("Gear")
Runtime.ProgressTab:CreateToggle({Name="Smart Gear & Inventory",CurrentValue=Settings.AutoLoot and Settings.AutoEquip and Settings.AutoSell and Settings.AutoForge and Settings.AutoEnchantWeapon and Settings.AutoRunes,Flag="SimpleSmartGear",Callback=function(v)
    local on = v == true
    Settings.AutoLoot = on
    Settings.AutoEquip = on
    Settings.AutoSell = on
    Settings.EmergencyInventoryCleanup = on
    Settings.AutoBankOverflow = on
    Settings.AutoRetrieveVariantBank = on
    Settings.AutoVariantUpgrade = on
    Settings.AutoForge = on
    Settings.SmartForgeProtection = on
    Settings.ReserveWorldCurrency = on
    Settings.AutoEnchantWeapon = on
    Settings.AutoEnchantArmor = on
    Settings.AutoRunes = on
    updateAutoLoot()
end})
Runtime.ProgressTab:CreateDropdown({Name="Sell Gear Below",Options={"Uncommon","Rare","Epic","Legendary","Mythic"},CurrentOption=Settings.SellBelow,Flag="SellBelow",Callback=function(v) Settings.SellBelow=normalizeChoice(v) or "Rare" end})
Runtime.ProgressTab:CreateSlider({Name="Forge Up To",Range={1,15},Increment=1,CurrentValue=Settings.ForgeTarget,Suffix="",Flag="ForgeTarget",Callback=function(v) Settings.ForgeTarget=math.floor(tonumber(v) or 10) end})
Runtime.ProgressTab:CreateSection("Skills & Pets")
Runtime.ProgressTab:CreateToggle({Name="Smart Skill Progression",CurrentValue=Settings.AutoSkillTree and Settings.AutoPotentialTree and Settings.AutoSkillRoll and Settings.AutoSkillEvolve,Flag="SimpleSmartSkills",Callback=function(v)
    local on = v == true
    Settings.AutoSkillTree = on
    Settings.AutoPotentialTree = on
    Settings.AutoPotentialUpgrade = on
    Settings.AutoPotentialReroll = on
    Settings.AutoSkillRoll = on
    Settings.SmartSkillQuality = on
    Settings.AutoSkillEvolve = on
end})
Runtime.ProgressTab:CreateToggle({Name="Auto Equip Best Pets",CurrentValue=Settings.AutoPets,Flag="AutoPets",Callback=function(v) Settings.AutoPets=v==true end})
Runtime.ProgressTab:CreateSection("Free Rewards")
Runtime.ProgressTab:CreateToggle({Name="Claim All Free Rewards",CurrentValue=Settings.AutoDaily and Settings.AutoPlaytime and Settings.AutoSeason and Settings.AutoBasicSpin and Settings.AutoPremiumFreeSpin and Settings.AutoSeasonSpin and Settings.AutoCodes,Flag="SimpleFreeRewards",Callback=function(v)
    local on = v == true
    Settings.AutoDaily = on
    Settings.AutoPlaytime = on
    Settings.AutoSeason = on
    Settings.AutoBasicSpin = on
    Settings.AutoPremiumFreeSpin = on
    Settings.AutoSeasonSpin = on
    Settings.AutoEventChests = on
    Settings.AutoCodes = on
    Settings.AutoGroupReward = on
    Settings.AutoClanQuests = on
    Settings.AutoClanRewards = on
end})
Runtime.ProgressTab:CreateLabel("Only free/in-game rewards are claimed. Robux purchases are never triggered.")

-- Activities --------------------------------------------------------------------
Runtime.ActivityTab:CreateSection("World Eater")
Runtime.ActivityTab:CreateToggle({Name="Auto Join World Eater",CurrentValue=Settings.AutoLiveEvent and Settings.LiveEventPriority,Flag="SimpleWorldEater",Callback=function(v)
    local on = v == true
    Settings.AutoLiveEvent = on
    Settings.LiveEventPriority = on
end})
Runtime.ActivityTab:CreateSection("Dungeons")
Runtime.ActivityTab:CreateToggle({Name="Smart Dungeon Planning",CurrentValue=Settings.AdaptiveDungeonPlanning,Flag="AdaptiveDungeonPlanning",Callback=function(v) Settings.AdaptiveDungeonPlanning=v==true end})
Runtime.ActivityTab:CreateDropdown({Name="Difficulty",Options={"Smart","Easy","Normal","Hard","Extreme"},CurrentOption=Settings.DungeonDifficulty,Flag="DungeonDifficulty",Callback=function(v) Settings.DungeonDifficulty=normalizeChoice(v) or "Smart" end})
Runtime.ActivityTab:CreateDropdown({Name="Mode",Options={"Smart","3Worlds","Random","Survival"},CurrentOption=Settings.DungeonGamemode,Flag="DungeonGamemode",Callback=function(v) Settings.DungeonGamemode=normalizeChoice(v) or "Smart" end})
Runtime.ActivityTab:CreateSlider({Name="Players",Range={1,5},Increment=1,CurrentValue=Settings.DungeonPlayers,Flag="DungeonPlayers",Callback=function(v) Settings.DungeonPlayers=math.floor(tonumber(v) or 1) end})
Runtime.ActivityTab:CreateToggle({Name="Friends Only",CurrentValue=Settings.DungeonFriendsOnly,Flag="DungeonFriendsOnly",Callback=function(v) Settings.DungeonFriendsOnly=v==true end})
Runtime.ActivityTab:CreateToggle({Name="Smart Dungeon Boosts & Shop",CurrentValue=Settings.AutoUsePotions and Settings.AutoBuyPotions and Settings.AutoDungeonShopDeals and Settings.AutoDungeonGear,Flag="SimpleDungeonSupport",Callback=function(v)
    local on = v == true
    Settings.AutoUsePotions = on
    Settings.AutoBuyPotions = on
    Settings.AutoDungeonShopDeals = on
    Settings.AutoDungeonGear = on
end})
Runtime.ActivityTab:CreateLabel("Smart dungeon mode automatically balances rewards, materials and safe clear speed.")
Runtime.ActivityTab:CreateSection("Infinite Tower")
Runtime.ActivityTab:CreateDropdown({Name="Upgrade Style",Options={"Smart","Damage First","Rewards First","Survival First"},CurrentOption=Settings.TowerUpgrade,Flag="TowerUpgrade",Callback=function(v) Settings.TowerUpgrade=normalizeChoice(v) or "Smart" end})
Runtime.ActivityTab:CreateToggle({Name="Use Owned 2x Speed",CurrentValue=Settings.Tower2xIfOwned,Flag="Tower2x",Callback=function(v) Settings.Tower2xIfOwned=v==true end})

-- Advanced ----------------------------------------------------------------------
Runtime.AdvancedTab:CreateSection("Quest Tuning")
Runtime.AdvancedTab:CreateDropdown({Name="Quest Selection",Options={"Best Progression","Highest XP","Fastest Completion","Highest Level"},CurrentOption=Settings.NPCQuestMode,Flag="NPCQuestMode",Callback=function(v) Settings.NPCQuestMode=normalizeChoice(v) or "Best Progression" Runtime.BestNpcQuest=nil end})
Runtime.AdvancedTab:CreateToggle({Name="Discover Chests For Quests",CurrentValue=Settings.AutoChestQuests,Flag="AutoChestQuests",Callback=function(v) Settings.AutoChestQuests=v==true end})
Runtime.AdvancedTab:CreateToggle({Name="Travel To Quest Giver",CurrentValue=Settings.QuestTravelToGiver,Flag="QuestTravelToGiver",Callback=function(v) Settings.QuestTravelToGiver=v==true end})
Runtime.AdvancedTab:CreateToggle({Name="Replace Worse Quest",CurrentValue=Settings.SmartQuestReplacement,Flag="SmartQuestReplacement",Callback=function(v) Settings.SmartQuestReplacement=v==true end})
Runtime.AdvancedTab:CreateSlider({Name="Switch Quest If Better By",Range={5,100},Increment=5,CurrentValue=Settings.QuestSwitchMinImprovement,Suffix="%",Flag="QuestSwitchMinImprovement",Callback=function(v) Settings.QuestSwitchMinImprovement=tonumber(v) or 25 end})
Runtime.AdvancedTab:CreateSlider({Name="Keep Quest After Progress",Range={0,90},Increment=5,CurrentValue=Settings.QuestKeepProgress,Suffix="%",Flag="QuestKeepProgress",Callback=function(v) Settings.QuestKeepProgress=tonumber(v) or 35 end})
Runtime.AdvancedTab:CreateButton({Name="Recheck Best Quest",Callback=function()
    task.spawn(function()
        if NPCController and type(NPCController.RequestAllStates) == "function" then
            safe(NPCController.RequestAllStates, NPCController)
        end
        refreshBestNpcQuestPlan()
        if Settings.Master and Settings.AutoNPCQuests then safe(autoNPCQuest) end
    end)
end})
Runtime.AdvancedTab:CreateSection("Movement Tuning")
Runtime.AdvancedTab:CreateToggle({Name="Dynamic Height",CurrentValue=Settings.DynamicEnemyHeight,Flag="DynamicEnemyHeight",Callback=function(v) Settings.DynamicEnemyHeight=v==true Runtime.PositionTarget=nil Runtime.CurrentHoverHeight=nil end})
Runtime.AdvancedTab:CreateSlider({Name="Height Adapt Speed",Range={1,30},Increment=1,CurrentValue=Settings.HeightSmoothing,Suffix="x",Flag="HeightSmoothing",Callback=function(v) Settings.HeightSmoothing=tonumber(v) or 14 end})
Runtime.AdvancedTab:CreateSlider({Name="Behind Distance When Look Down Is Off",Range={0,10},Increment=0.5,CurrentValue=Settings.BehindDistance,Suffix=" studs",Flag="BehindDistance",Callback=function(v) Settings.BehindDistance=tonumber(v) or 3 end})
Runtime.AdvancedTab:CreateToggle({Name="Anti-Stuck",CurrentValue=Settings.AntiStuck,Flag="AntiStuck",Callback=function(v) Settings.AntiStuck=v==true end})
Runtime.AdvancedTab:CreateSection("Inventory Tuning")
Runtime.AdvancedTab:CreateSlider({Name="Keep Best Spare Per Slot",Range={0,3},Increment=1,CurrentValue=Settings.KeepSpareBest,Flag="KeepSpareBest",Callback=function(v) Settings.KeepSpareBest=math.floor(tonumber(v) or 1) end})
Runtime.AdvancedTab:CreateSlider({Name="Emergency Cleanup At",Range={80,98},Increment=1,CurrentValue=Settings.InventoryCleanupAt,Suffix="%",Flag="InventoryCleanupAt",Callback=function(v) Settings.InventoryCleanupAt=math.floor(tonumber(v) or 92) end})
Runtime.AdvancedTab:CreateSlider({Name="Start Banking At",Range={70,96},Increment=1,CurrentValue=Settings.AutoBankAt,Suffix="%",Flag="AutoBankAt",Callback=function(v) Settings.AutoBankAt=math.floor(tonumber(v) or 86) end})
Runtime.AdvancedTab:CreateDropdown({Name="Variant Minimum Rarity",Options={"Rare","Epic","Legendary","Mythic"},CurrentOption=Settings.VariantMinRarity,Flag="VariantMinRarity",Callback=function(v) Settings.VariantMinRarity=normalizeChoice(v) or "Epic" end})
Runtime.AdvancedTab:CreateSection("Upgrade Tuning")
Runtime.AdvancedTab:CreateToggle({Name="Always Use Forge Protection",CurrentValue=Settings.ForgeProtection,Flag="ForgeProtection",Callback=function(v) Settings.ForgeProtection=v==true end})
Runtime.AdvancedTab:CreateSlider({Name="Smart Protection Below",Range={10,90},Increment=5,CurrentValue=Settings.ForgeProtectionBelow,Suffix="%",Flag="ForgeProtectionBelow",Callback=function(v) Settings.ForgeProtectionBelow=math.floor(tonumber(v) or 45) end})
Runtime.AdvancedTab:CreateDropdown({Name="Weapon Enchant Target",Options={"Rare","Epic","Legendary","Mythical"},CurrentOption=Settings.WeaponEnchantMin,Flag="WeaponEnchantMin",Callback=function(v) Settings.WeaponEnchantMin=normalizeChoice(v) or "Epic" end})
Runtime.AdvancedTab:CreateDropdown({Name="Armor Enchant Target",Options={"Rare","Epic","Legendary","Mythical"},CurrentOption=Settings.ArmorEnchantMin,Flag="ArmorEnchantMin",Callback=function(v) Settings.ArmorEnchantMin=normalizeChoice(v) or "Epic" end})
Runtime.AdvancedTab:CreateDropdown({Name="Rune Target",Options={"Rare","Epic","Legendary","Mythical"},CurrentOption=Settings.RuneMinRarity,Flag="RuneMinRarity",Callback=function(v) Settings.RuneMinRarity=normalizeChoice(v) or "Epic" end})
Runtime.AdvancedTab:CreateSection("Skill Tuning")
Runtime.AdvancedTab:CreateDropdown({Name="Potential Priority",Options={"Farming First","Combat First","Activities First","Race First"},CurrentOption=Settings.PotentialBranch,Flag="PotentialPriority",Callback=function(v) Settings.PotentialBranch=normalizeChoice(v) or "Farming First" end})
Runtime.AdvancedTab:CreateDropdown({Name="Potential Reroll Until",Options={"Rare","Epic","Legendary","Mythic"},CurrentOption=Settings.PotentialRerollMin,Flag="PotentialRerollMin",Callback=function(v) Settings.PotentialRerollMin=normalizeChoice(v) or "Epic" end})
Runtime.AdvancedTab:CreateDropdown({Name="Keep Skills At / Above",Options=Runtime.SkillRarityOptions,CurrentOption=Settings.SkillMinRarity,Flag="SkillMinRarity",Callback=function(v) Settings.SkillMinRarity=normalizeChoice(v) or "Epic" end})
Runtime.AdvancedTab:CreateSlider({Name="Ancient Scroll Reserve",Range={0,10},Increment=1,CurrentValue=Settings.SkillQualityAncientReserve,Flag="SkillQualityAncientReserve",Callback=function(v) Settings.SkillQualityAncientReserve=math.floor(tonumber(v) or 2) end})
Runtime.AdvancedTab:CreateSection("Awakening & Race")
Runtime.AdvancedTab:CreateToggle({Name="Auto Ascend (Resets Progress)",CurrentValue=Settings.AutoAwaken,Flag="AutoAwaken",Callback=function(v) Settings.AutoAwaken=v==true end})
Runtime.AdvancedTab:CreateLabel("Warning: Ascending resets most normal progression. This stays OFF by default.")
Runtime.AdvancedTab:CreateToggle({Name="Auto Race Reroll At Awakening 3",CurrentValue=Settings.AutoRaceReroll,Flag="AutoRaceReroll",Callback=function(v) Settings.AutoRaceReroll=v==true end})
Runtime.AdvancedTab:CreateDropdown({Name="Race Target",Options={"Smart Farming (Angel)","Fast Combat (Elf)","Crafting / Rolling (Wizard)","Forge Power (Dwarf)","Angel","Elf","Wizard","Dwarf","Keep Current"},CurrentOption=Settings.RaceTarget,Flag="RaceTarget",Callback=function(v) Settings.RaceTarget=normalizeChoice(v) or "Smart Farming (Angel)" end})
Runtime.AdvancedTab:CreateSection("Dungeon Tuning")
Runtime.AdvancedTab:CreateDropdown({Name="Potion Strategy",Options={"Smart","Always"},CurrentOption=Settings.PotionStrategy,Flag="PotionStrategy",Callback=function(v) Settings.PotionStrategy=normalizeChoice(v) or "Smart" end})
Runtime.AdvancedTab:CreateSlider({Name="Soul Crystal Reserve",Range={0,100000},Increment=2500,CurrentValue=Settings.SoulCrystalReserve,Suffix="",Flag="SoulCrystalReserve",Callback=function(v) Settings.SoulCrystalReserve=math.floor(tonumber(v) or 10000) end})

-- Settings ----------------------------------------------------------------------
Runtime.SettingsTab:CreateSection("AFK")
Runtime.SettingsTab:CreateToggle({Name="Prevent Idle Disconnect",CurrentValue=Settings.AntiAFK,Flag="AntiAFK",Callback=function(v) Settings.AntiAFK=v==true end})
Runtime.SettingsTab:CreateToggle({Name="Low-Lag Mode While Farming",CurrentValue=Settings.AFKPerformanceMode,Flag="AFKPerformanceMode",Callback=function(v)
    Settings.AFKPerformanceMode=v==true
    Runtime.ApplyAFKPerformanceMode(Settings.Master and Settings.AFKPerformanceMode)
end})
Runtime.SettingsTab:CreateSection("Script")
Runtime.SettingsTab:CreateParagraph({Title="Build",Content="Loot Up v"..VERSION.." · Simplified UI · Current PuckUI",Height=48})
Runtime.SettingsTab:CreateButton({Name="Unload Script",Callback=function() if ENV.__PUCKAFK_LOOTUP_UNLOAD then ENV.__PUCKAFK_LOOTUP_UNLOAD() end end})

-- PuckUI's Settings tab injects shared interface controls and its built-in Configs tab.

task.spawn(function()
    while Runtime.Alive do
        if Runtime.StatusParagraph and Runtime.StatusParagraph.Set then
            local activity = tostring(Runtime.Activity or Settings.ActivityMode or "World")
            local world = tostring(getData("CurrentWorld") or "?")
            local level = math.floor(numData("Level"))
            local target = tostring(Runtime.TargetName or "None")
            local quest = describeQuestPlan()
            local gold = math.floor(numData("Gold"))
            local shards = math.floor(numData("Shards"))
            local detail = ""

            if Runtime.Activity == "Dungeon" or Runtime.Activity == "DungeonQueue" then
                local mode = Runtime.DungeonRunGamemode or Runtime.ResolveDungeonGamemode()
                local difficulty = Settings.DungeonDifficulty == "Smart"
                    and Runtime.ResolveDungeonDifficulty(mode)
                    or Settings.DungeonDifficulty
                detail = string.format(" • %s / %s", tostring(mode), tostring(difficulty))
            elseif Runtime.Activity == "Tower" or Runtime.Activity == "TowerQueue" then
                detail = string.format(" • Floor %d", math.max(0, math.floor(tonumber(Runtime.TowerFloor) or 0)))
            end

            local text = string.format(
                "%s • %s%s\nLevel %d • %s\nTarget: %s\nQuest: %s\nGold %d • Shards %d",
                Settings.Master and "RUNNING" or "PAUSED",
                activity,
                detail,
                level,
                world,
                target,
                quest,
                gold,
                shards
            )
            safe(Runtime.StatusParagraph.Set, Runtime.StatusParagraph, text)
        end
        task.wait(0.5)
    end
end)

local function unload()
    if not Runtime.Alive then return end
    Runtime.Alive = false
    releaseDownFacingLock()
    setAutoSwing(false, true)
    Settings.Master = false
    Runtime.ApplyAFKPerformanceMode(false)
    if Controllers.Render and Controllers.Render.LootDrop and type(Controllers.Render.LootDrop.ToggleAutoCollect) == "function" then
        safe(Controllers.Render.LootDrop.ToggleAutoCollect, Controllers.Render.LootDrop, false)
    end
    setNoclip(false)
    for _, c in ipairs(Runtime.Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Runtime.Connections)
    if Runtime.Window and type(Runtime.Window.Destroy) == "function" then pcall(Runtime.Window.Destroy, Runtime.Window) end
    if ENV.__PUCKAFK_LOOTUP_UNLOAD == unload then ENV.__PUCKAFK_LOOTUP_UNLOAD = nil end
    if ENV[SCRIPT_KEY] == Runtime then ENV[SCRIPT_KEY] = nil end
end
ENV.__PUCKAFK_LOOTUP_UNLOAD = unload

PuckUI:Notify({
    Title = "Loot Up",
    Content = "Smart autofarm v"..VERSION.." loaded with the simplified UI.",
    Duration = 3,
})

print("[PuckAFK Loot Up] loaded v" .. VERSION)
