-- ChunkUnloader_Options.lua (v1.6.0: base/-2/-4/-6 tiers)
-- PZAPI.ModOptions UI (ships with B42, no dependency).
-- The grid is applied ONCE at game boot (pre world-load). Changing it here
-- takes effect after RESTART. Mid-game writes corrupt chunk mapping
-- (StackOverflow in wall checks), so apply() NEVER writes the engine.
-- If PZAPI is unavailable, the client falls back to hardcoded defaults.

local MOD_ID = "ChunkUnloader"
local MOD_NAME = "Chunk Unloader"

-- Debug switch: normal play shows Off + Base + -2/-4/-6 only.
-- Set true to restore the Custom tier + FixedGrid slider immediately
-- (same combo index 6, ini-compatible).
local SHOW_CUSTOM = false

local options = nil
pcall(function()
    options = PZAPI.ModOptions:create(MOD_ID, MOD_NAME)
end)
if not options then
    print("[CU] PZAPI.ModOptions unavailable, using hardcoded defaults")
    return
end

options:addTitle(getText("UI_options_CU_Title"))
options:addDescription(getText("UI_options_CU_RestartNote"))

-- v1.6 combo: Off / Base / Base-2 / Base-4 / Base-6 (+Custom when
-- SHOW_CUSTOM). ModOptions.ini stores the 1-based INDEX; pre-v1.6 values
-- migrate in the client (out-of-range -> base, stale fixed -> base).
-- New tiers go on the end.
local mode = options:addComboBox("Mode", getText("UI_options_CU_Mode"),
    getText("UI_options_CU_Mode_desc"))
mode:addItem(getText("UI_options_CU_Mode_off"), false)
mode:addItem(getText("UI_options_CU_Mode_base"), true)
mode:addItem(getText("UI_options_CU_Mode_minus2"), false)
mode:addItem(getText("UI_options_CU_Mode_minus4"), false)
mode:addItem(getText("UI_options_CU_Mode_minus6"), false)
if SHOW_CUSTOM then
    mode:addItem(getText("UI_options_CU_Mode_custom"), false)
    options:addSlider("FixedGrid", getText("UI_options_CU_FixedGrid"), 5, 17, 1, 13,
        getText("UI_options_CU_FixedGrid_desc"))
end
-- NOTE: LogIntervalSec (periodic [CU-Status]) exists in code
-- as a debug switch, but is intentionally NOT exposed here (finalized: silent
-- by default). Re-enable live via console:
--   ChunkUnloader.cfg.logIntervalSec = 30

local function readOpt(self, id, fb)
    local ok, opt = pcall(function() return self:getOption(id) end)
    if not ok or not opt then return fb end
    local ok2, v = pcall(function() return opt:getValue() end)
    if not ok2 or v == nil then return fb end
    return v
end

local function applyToCfg(self)
    ChunkUnloader = ChunkUnloader or {}
    local c = ChunkUnloader.cfg or {}
    ChunkUnloader.cfg = c
    local rawMode = readOpt(self, "Mode", 2)
    -- FixedGrid exists only when SHOW_CUSTOM added the slider. A nil marks
    -- "not deliberately chosen", letting the client tell a stale ini
    -- (fixed kind without a saved slider value) apart from a real
    -- Custom request.
    local rawFixed = nil
    local okF, optF = pcall(function() return self:getOption("FixedGrid") end)
    if okF and optF ~= nil then
        rawFixed = readOpt(self, "FixedGrid", 13)
    end
    print(string.format("[CU] apply forensic: Mode raw=%s(%s) FixedGrid raw=%s(%s)",
        tostring(rawMode), type(rawMode),
        tostring(rawFixed), type(rawFixed)))
    c.mode = rawMode
    c.fixed = rawFixed
    c.logIntervalSec = 0 -- finalized: silent (debug via console)
    return c
end

-- Called by the client boot handler BEFORE its single engine write,
-- so boot uses ModOptions.ini values regardless of file load order.
function ChunkUnloader.reloadOptions()
    if not options then return nil end
    local ok, c = pcall(function()
        PZAPI.ModOptions:load()
        return applyToCfg(options)
    end)
    if not ok then return nil end
    return c
end

options.apply = function(self)
    local c = applyToCfg(self)
    print(string.format("[CU] applied: mode=%s fixed=%s (takes effect after RESTART)",
        tostring(c.mode), tostring(c.fixed)))
end

Events.OnGameBoot.Add(function()
    pcall(function()
        PZAPI.ModOptions:load()
        applyToCfg(options)
    end)
    print("[CU] OnGameBoot: settings loaded (engine write happens once, pre world-load)")
end)
