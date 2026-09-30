-- ChunkUnloader_Client.lua (v1.6.0: base/-2/-4/-6 tiers + hi-res base)
-- B42. Chooses IsoChunkMap.chunkGridWidth at boot, never mid-game.
--
-- WHY boot-once (b42.20.04, javap verified, learned from a StackOverflow crash):
--   IsoChunkMap.<init> allocates chunksSwapA/B = new IsoChunk[grid*grid]
--   ONCE at world load. Every hot path (getChunk index math, Load*/SwapChunkBuffers
--   loops, getGridSquare bounds, LoadedAreas) then reads the LIVE static grid.
--   Changing the static mid-game desyncs index math vs array contents: coordinates
--   alias into wrong slots, getGridSquare returns cyclic squares, and
--   IsoGridSquare.isWallTo diagonal ping-pong never resolves (its depth guard only
--   zeroes a flag, it does not return) -> StackOverflowError in wall checks.
--   Observed: first write at tick ~20 with grid=5 -> crash at f:21.
--   ZBBetterFPS is safe because it hooks CalcChunkWidth exit (boot-time point).
--   We do the equivalent: single write at OnGameBoot (pre world-load), then
--   READ-ONLY forever. Dynamic vehicle/aim switching is REMOVED (was the crash
--   vector). Resolution change mid-session is also suspect -> don't, or restart.
--
-- Lua table note: IsoChunkMap.* in Lua is a snapshot mirror; real writes go
-- through the CUControl Java bridge (cu-agent). Mirror kept consistent
-- for display only.

ChunkUnloader = ChunkUnloader or {}
local CU = ChunkUnloader

CU.MOD_ID = "ChunkUnloader"
CU.capturedBootGrid = nil
CU.requestedBase = false -- true in base mode (規定値)
CU.requestedOffset = nil -- resolution-relative request (minus6 mode, v1.5+)
CU.requestedGrid = nil -- absolute request (custom mode, or pre-1.4 agent fallback)
CU.bootApplied = false
CU.tickCounter = 0
CU.THROTTLE_TICKS = 20
CU.statusTick = 0
CU.cfg = CU.cfg or nil       -- live config from ModOptions apply (Options file)
CU.divergeWarned = false

local function toOdd(n)
    n = math.floor(tonumber(n) or 0)
    if n < 3 then n = 3 end
    if n > 19 then n = 19 end
    if (n % 2) == 0 then n = n + 1 end
    if n > 19 then n = 19 end
    return n
end

-- Hardcoded defaults (PZAPI-absent fallback). Sandbox options were removed
-- in v1.0.2: client-side Java mod settings belong in ModOptions, and there
-- is no server-side consumer left to feed.
local function readSandbox()
    return {
        mode = 2, -- base tier by default
        fixed = 13,
        logIntervalSec = 0, -- finalized: silent
    }
end

-- Tier table (v1.6.0: base and base-2/-4/-6; appearance cannot be
-- guaranteed per resolution, so absolute grids were dropped).
--   Off = vanilla untouched / Base (規定値) = resolution-adjusted base
--   (vanilla; raised to 21 on 1440p class, 23 on 4K class for coverage) /
--   Minus2/4/6 (規定-2/-4/-6) = base minus N /
--   Custom = FixedGrid slider (absolute, debug only, hidden unless
--   SHOW_CUSTOM in the Options file).
-- Combo index note: v1.5 had only base/minus6 (minus6 was index 3);
-- v1.6 inserts minus2/minus4, so a v1.5 minus6 ini now reads as minus2
-- (weaker = safe direction; re-select once). Out-of-range indices fall
-- back to base (index 2, the conservative choice). A fixed-kind entry
-- with nil FixedGrid (stale ini, slider was hidden) also resolves to
-- base, never to a surprise fixed grid.
local MODES = {
    [1] = { name = "off",    kind = "off" },
    [2] = { name = "base",   kind = "base" },
    [3] = { name = "minus2", kind = "offset", offset = 2 },
    [4] = { name = "minus4", kind = "offset", offset = 4 },
    [5] = { name = "minus6", kind = "offset", offset = 6 },
    [6] = { name = "custom", kind = "fixed" },
}

-- 1080p-equivalent vanilla, used ONLY as a fallback when the loaded agent
-- predates offset support (then absolute 19-offset == old 13/15/17).
local VANILLA_1080P = 19

local function getCfg()
    local cfg = CU.cfg
    if cfg == nil then
        cfg = readSandbox()
        CU.cfg = cfg
    end
    local idx = math.floor(tonumber(cfg.mode) or 2)
    if idx < 1 or idx > #MODES then idx = 2 end
    cfg.modeIdx = idx
    local m = MODES[idx]
    cfg.modeName = m.name
    cfg.useBase = false
    cfg.offset = nil
    cfg.target = nil
    if m.kind == "fixed" and cfg.fixed == nil then
        -- Stale-ini rescue: a fixed grid with no saved FixedGrid value means
        -- Custom was NOT deliberately chosen (slider was hidden), so resolve
        -- to base instead of a surprise fixed grid.
        cfg.modeName = "base(legacy)"
        cfg.useBase = true
    elseif m.kind == "base" then
        cfg.useBase = true
    elseif m.kind == "offset" then
        cfg.offset = m.offset
    elseif m.kind == "fixed" then
        cfg.target = toOdd(cfg.fixed or 13)
    end
    -- off kind: all three stay nil/false (engine default stands)
    cfg.logIntervalSec = tonumber(cfg.logIntervalSec) or 30
    return cfg
end

-- Safe Java call: pre-check method existence via index BEFORE calling.
-- Calling a static (e.g. Core.getTileScale) with colon syntax throws a
-- Java-side error that Kahlua pcall does NOT catch (v0.2.1 Verify crash).
local function safeCall1(obj, method, arg)
    if obj == nil then return nil end
    local f = obj[method]
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(function()
        if arg ~= nil then return f(obj, arg) else return f(obj) end
    end)
    if not ok then return nil end
    return r
end

-- Real (materialized) zombie count in the loaded cell. O(1) size read.
local function countZombies()
    local okC, cell = pcall(function() return getCell() end)
    if not okC or not cell then return nil end
    if type(cell.getZombieList) ~= "function" then return nil end
    local okL, list = pcall(function() return cell:getZombieList() end)
    if not okL or not list then return nil end
    if type(list.size) ~= "function" then return nil end
    local okS, n = pcall(function() return list:size() end)
    if not okS or type(n) ~= "number" then return nil end
    return math.floor(n)
end

-- Java-side truth via instance dispatch (getWidthInTiles reads the real
-- static chunkWidthInTiles with getstatic). Guarded, console-safe.
local function javaWidthTiles()
    local okC, cell = pcall(function() return getCell() end)
    if not okC or not cell then return nil end
    if type(cell.getChunkMap) ~= "function" then return nil end
    local okM, cm = pcall(function() return cell:getChunkMap(0) end)
    if not okM or not cm then return nil end
    if type(cm.getWidthInTiles) ~= "function" then return nil end
    local okW, w = pcall(function() return cm:getWidthInTiles() end)
    if not okW or type(w) ~= "number" then return nil end
    return math.floor(w)
end

-- Java bridge (cu-agent javaagent, global CUControl; package table cu.CUControl as fallback).
local function bridge()
    local b = rawget(_G, "CUControl")
    if b ~= nil then return b end
    local ns = rawget(_G, "cu")
    if type(ns) == "table" then
        local c = rawget(ns, "CUControl")
        if c ~= nil then return c end
    end
    return nil
end

-- Lua mirror read (display/fallback only; NEVER authoritative for writes).
local GRID_CANDIDATES = { "chunkGridWidth", "ChunkGridWidth" }
local function readMirrorGrid()
    if not IsoChunkMap then return nil end
    if CU.fieldGrid then
        local ok, v = pcall(function() return IsoChunkMap[CU.fieldGrid] end)
        if ok and type(v) == "number" then return v end
        return nil
    end
    for _, name in ipairs(GRID_CANDIDATES) do
        local ok, v = pcall(function() return IsoChunkMap[name] end)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

-- Authoritative grid: bridge (Java truth) first, mirror fallback.
local function readGrid()
    local b = bridge()
    if b ~= nil and type(b.getGrid) == "function" then
        local ok, v = pcall(function() return b.getGrid() end)
        if ok and type(v) == "number" and v > 1 then return math.floor(v) end
    end
    return readMirrorGrid()
end

-- THE single write path. Called ONLY from onGameBoot (pre world-load).
-- Calling this mid-game corrupts chunk mapping -> wall-query infinite
-- recursion -> StackOverflowError. Never call it from OnTick/apply.
-- NOTE (v1.3.0): boot no longer calls this directly. The request goes
-- through setPendingGrid and the Calc-exit hook applies min(requested,
-- vanilla) so a low-res rig is never ENLARGED past its resolution default.
-- Kept for console debug only.
local function writeGridOnce(grid)
    local b = bridge()
    if b == nil or type(b.setGrid) ~= "function" then
        print("[CU] WARN: CUControl bridge absent (cu-agent?). No engine write; mirror-only (degraded).")
        return false
    end
    local ok, r = pcall(function() return b.setGrid(grid) end)
    if ok and type(r) == "number" and r > 1 then
        if IsoChunkMap then
            pcall(function()
                if CU.fieldGrid then IsoChunkMap[CU.fieldGrid] = r end
            end)
        end
        return true
    end
    print("[CU] WARN: bridge.setGrid failed")
    return false
end

local function detectMirrorField()
    if CU.fieldGrid then return true end
    if not IsoChunkMap then return false end
    for _, name in ipairs(GRID_CANDIDATES) do
        local ok, v = pcall(function() return IsoChunkMap[name] end)
        if ok and type(v) == "number" and v > 1 then
            CU.fieldGrid = name
            return true
        end
    end
    return false
end

-- Java-observed values (nil when the loaded agent predates v1.3.0).
local function javaVanilla()
    local b = bridge()
    if b ~= nil and type(b.getVanillaGrid) == "function" then
        local ok, v = pcall(function() return b.getVanillaGrid() end)
        if ok and type(v) == "number" and v > 1 then return math.floor(v) end
    end
    return nil
end

local function javaEffective()
    local b = bridge()
    if b ~= nil and type(b.getEffectiveGrid) == "function" then
        local ok, v = pcall(function() return b.getEffectiveGrid() end)
        if ok and type(v) == "number" and v > 1 then return math.floor(v) end
    end
    return nil
end

local function javaBase()
    local b = bridge()
    if b ~= nil and type(b.getBaseGrid) == "function" then
        local ok, v = pcall(function() return b.getBaseGrid() end)
        if ok and type(v) == "number" and v > 1 then return math.floor(v) end
    end
    return nil
end

local function onGameBoot()
    if CU.bootApplied then return end
    -- options first (own OnGameBoot in Options file may run after us;
    -- reload explicitly so boot uses ModOptions.ini values, not defaults)
    if type(CU.reloadOptions) == "function" then
        pcall(CU.reloadOptions)
    end
    local cfg = getCfg()
    detectMirrorField()
    CU.capturedBootGrid = readGrid()
    CU.requestedBase = cfg.useBase == true
    CU.requestedOffset = cfg.offset -- 6 in minus6 mode, else nil
    CU.requestedGrid = cfg.target -- absolute, custom mode (or fallback) only
    local b = bridge()
    local reqStr = CU.requestedBase and "base"
        or (CU.requestedOffset and ("-" .. tostring(CU.requestedOffset))
            or tostring(CU.requestedGrid))
    print("[CU] boot: engine grid=" .. tostring(CU.capturedBootGrid)
        .. " mode=" .. tostring(cfg.modeName)
        .. " requested=" .. reqStr
        .. " bridge=" .. tostring(b ~= nil))
    if not CU.requestedBase and CU.requestedOffset == nil and CU.requestedGrid == nil then
        print("[CU] boot: mode=off, no write. Engine default stands.")
        -- setPendingGrid(0) clears every pending kind on all agent versions.
        if b ~= nil and type(b.setPendingGrid) == "function" then
            pcall(function() b.setPendingGrid(0) end)
        end
        CU.bootApplied = true
        return
    end
    -- NOTE: the boot-time engine reading may be the class-init default (13),
    -- NOT the resolution value: CalcChunkWidth runs AFTER Lua boot
    -- (proven: boot wrote 9, engine showed 19 at load). So an "equal, skip"
    -- shortcut here would silently drop legitimate requests. ALWAYS register
    -- pending; the Calc-exit hook resolves it at the sanctioned point
    -- (base/minus6 against the resolution-adjusted base, custom as
    -- min(fixed, vanilla)). v1.5 pending-only (no direct uncapped write);
    -- the Java side covers both boot orders (hook for Calc-after-boot,
    -- fast-path for Calc-before-boot).
    if b ~= nil then
        if CU.requestedBase then
            if type(b.setPendingBase) == "function" then
                local okS, rS = pcall(function() return b.setPendingBase() end)
                print(string.format("[CU] boot forensic: setPendingBase() -> %s (ok=%s) vanilla=%s base=%s",
                    tostring(rS), tostring(okS), tostring(javaVanilla()), tostring(javaBase())))
            elseif type(b.setPendingGrid) == "function" then
                -- Pre-1.5 agent has no raised base: leave vanilla standing.
                pcall(function() b.setPendingGrid(0) end)
                print("[CU] boot forensic (legacy agent): no base support, vanilla stands")
            end
        elseif CU.requestedOffset ~= nil then
            if type(b.setPendingOffset) == "function" then
                local okS, rS = pcall(function() return b.setPendingOffset(CU.requestedOffset) end)
                print(string.format("[CU] boot forensic: setPendingOffset(-%s) -> %s (ok=%s) vanilla=%s base=%s",
                    tostring(CU.requestedOffset), tostring(rS), tostring(okS),
                    tostring(javaVanilla()), tostring(javaBase())))
            elseif type(b.setPendingGrid) == "function" then
                -- Pre-1.4 agent: fall back to the 1080p-equivalent absolute.
                local abs = VANILLA_1080P - CU.requestedOffset
                if abs < 3 then abs = 3 end
                CU.requestedGrid = abs
                local okS, rS = pcall(function() return b.setPendingGrid(abs) end)
                print(string.format("[CU] boot forensic (legacy agent): setPendingGrid(%s) -> %s (ok=%s)",
                    tostring(abs), tostring(rS), tostring(okS)))
            end
        elseif CU.requestedGrid ~= nil and type(b.setPendingGrid) == "function" then
            local okS, rS = pcall(function() return b.setPendingGrid(CU.requestedGrid) end)
            print(string.format("[CU] boot forensic: setPendingGrid(%s) -> %s (ok=%s) vanilla=%s",
                tostring(CU.requestedGrid), tostring(rS), tostring(okS), tostring(javaVanilla())))
        end
    end
    CU.bootApplied = true
    print("[CU] boot: done. Changing grid now requires RESTART.")
end

local function onGameStart()
    -- READ-ONLY reconciliation + world-loaded mark (hook skips writes after
    -- this point; post-construction writes corrupt chunk mapping).
    -- NEVER rewrite here even on mismatch (restart to re-apply).
    CU.tickCounter = 0
    CU.statusTick = 0
    CU.divergeWarned = false
    local b = bridge()
    if b ~= nil and type(b.setWorldLoaded) == "function" then
        pcall(function() b.setWorldLoaded(true) end)
    end
    local cfg = getCfg()
    local vanilla, base, eff = javaVanilla(), javaBase(), javaEffective()
    local reqNote = CU.requestedBase and "base"
        or (CU.requestedOffset and ("-" .. tostring(CU.requestedOffset))
            or tostring(CU.requestedGrid))
    local extraNote = ""
    if CU.requestedBase and base and eff and eff ~= base then
        extraNote = " (MISMATCH: effective differs from base?)"
    elseif CU.requestedOffset and base and eff and eff ~= base - CU.requestedOffset then
        extraNote = " (FLOORED at min grid: base " .. tostring(base)
            .. " too small for -" .. tostring(CU.requestedOffset) .. ")"
    elseif CU.requestedGrid and vanilla and CU.requestedGrid > vanilla then
        extraNote = " (CAPPED at vanilla: request above resolution default is a no-op)"
    end
    print("[CU] started. mode=" .. tostring(cfg.modeName)
        .. " requested=" .. reqNote
        .. " vanilla=" .. tostring(vanilla)
        .. " base=" .. tostring(base)
        .. " effective=" .. tostring(eff)
        .. " cfgFixedNow=" .. tostring(cfg.fixed)
        .. " bootApplied=" .. tostring(CU.bootApplied)
        .. " engineNow=" .. tostring(readGrid())
        .. " javaTiles=" .. tostring(javaWidthTiles())
        .. " logEvery=" .. tostring(cfg.logIntervalSec) .. "s"
        .. extraNote)
end

local function onMainMenuEnter()
    -- world gone: allow the hook to apply pending again (e.g. menu-time
    -- resolution change followed by a fresh load rebuilds arrays anyway).
    local b = bridge()
    if b ~= nil and type(b.setWorldLoaded) == "function" then
        pcall(function() b.setWorldLoaded(false) end)
    end
end

-- Periodic status line (reads only - safe mid-game).
CU.statusTick = CU.statusTick or 0
local function statusLog(cfg)
    local interval = tonumber(cfg.logIntervalSec) or 30
    if interval <= 0 then return end
    CU.statusTick = CU.statusTick + 1
    if CU.statusTick < math.max(1, math.floor(interval * 3 + 0.5)) then return end
    CU.statusTick = 0
    local g = readGrid()
    local jwt = javaWidthTiles()
    local path = bridge() ~= nil and "java" or "mirror(DEGRADED)"
    local b = bridge()
    local pend = nil
    if b ~= nil and type(b.getPendingGrid) == "function" then
        local okP, pv = pcall(function() return b.getPendingGrid() end)
        if okP and type(pv) == "number" then pend = pv end
    end
    print(string.format("[CU-Status] mode=%s grid=%s pending=%s base=%s effective=%s zombies=%s javaTiles=%s via=%s",
        tostring(cfg.modeName), tostring(g), tostring(pend), tostring(javaBase()),
        tostring(javaEffective()), tostring(countZombies()),
        tostring(jwt), path))
    local vanillaNow = javaVanilla()
    local effNow = javaEffective()
    local want = effNow or CU.requestedGrid
    if want and g and g ~= want and not CU.divergeWarned then
        CU.divergeWarned = true
        if CU.requestedGrid and vanillaNow and CU.requestedGrid > vanillaNow and not effNow then
            print(string.format("[CU] capped: requested=%s above vanilla=%s, engine grid=%s stands (intended; not a fault).",
                tostring(CU.requestedGrid), tostring(vanillaNow), tostring(g)))
        else
            print(string.format("[CU] WARN: engine grid=%s differs from effective=%s (resolution change?). RESTART to re-apply; mid-game writes are unsafe.",
                tostring(g), tostring(want)))
        end
    end
end

local function onTick()
    CU.tickCounter = CU.tickCounter + 1
    if (CU.tickCounter % CU.THROTTLE_TICKS) ~= 0 then return end
    if not IsoChunkMap then return end
    statusLog(getCfg())
end

Events.OnGameBoot.Add(onGameBoot)
Events.OnGameStart.Add(onGameStart)
Events.OnTick.Add(onTick)
if Events.OnMainMenuEnter then
    Events.OnMainMenuEnter.Add(onMainMenuEnter)
end

--- Console debug helper (reads only - safe anytime)
function CU.PrintState()
    local cfg = getCfg()
    print("[CU] grid=" .. tostring(readGrid())
        .. " mode=" .. tostring(cfg.modeName)
        .. " base=" .. tostring(CU.requestedBase)
        .. " offset=" .. tostring(CU.requestedOffset)
        .. " requested=" .. tostring(CU.requestedGrid)
        .. " vanilla=" .. tostring(javaVanilla())
        .. " baseNow=" .. tostring(javaBase())
        .. " effective=" .. tostring(javaEffective())
        .. " bootGrid=" .. tostring(CU.capturedBootGrid)
        .. " bootApplied=" .. tostring(CU.bootApplied)
        .. " fixed=" .. tostring(cfg.fixed)
        .. " zombies=" .. tostring(countZombies())
        .. " javaTiles=" .. tostring(javaWidthTiles())
        .. " via=" .. tostring(bridge() ~= nil and "java" or "mirror"))
    for i = 0, 3 do
        local ok, p = pcall(getSpecificPlayer, i)
        if ok and p then
            local aiming, vehicle = nil, nil
            if type(p.isAiming) == "function" then
                local okA, a = pcall(function() return p:isAiming() end)
                if okA then aiming = a end
            end
            if type(p.getVehicle) == "function" then
                local okV, v = pcall(function() return p:getVehicle() end)
                if okV then vehicle = v end
            end
            print("[CU] player" .. i
                .. " vehicle=" .. tostring(vehicle)
                .. " aiming=" .. tostring(aiming))
        end
    end
end

--- Numeric verification (reads only - safe anytime)
function CU.Verify()
    local grid = readGrid()
    local radius = grid and (grid * 4) or nil
    print("[CU-Verify] chunkGrid=" .. tostring(grid)
        .. " radius~" .. tostring(radius) .. " tiles"
        .. " (" .. tostring(grid and grid * grid or nil) .. " chunks resident)")

    local okCore, core = pcall(function() return getCore() end)
    if okCore and core then
        local zoom = safeCall1(core, "getZoom", 0)
        local sw = safeCall1(core, "getScreenWidth")
        local sh = safeCall1(core, "getScreenHeight")
        print("[CU-Verify] zoom=" .. tostring(zoom)
            .. " screen=" .. tostring(sw) .. "x" .. tostring(sh))
    end

    local renderW, renderH = nil, nil
    local loadedW = nil
    local okCell, cell = pcall(function() return getCell() end)
    if okCell and cell then
        if type(cell.getMinX) == "function" and type(cell.getMaxX) == "function"
                and type(cell.getMinY) == "function" and type(cell.getMaxY) == "function" then
            local okR, minX, maxX, minY, maxY = pcall(function()
                return cell:getMinX(), cell:getMaxX(), cell:getMinY(), cell:getMaxY()
            end)
            if okR and minX and maxX and minY and maxY then
                renderW, renderH = maxX - minX, maxY - minY
                print(string.format("[CU-Verify] render window tiles: X %d..%d (%d)  Y %d..%d (%d)",
                    minX, maxX, renderW, minY, maxY, renderH))
            end
        end
        local cm = safeCall1(cell, "getChunkMap", 0)
        if cm and type(cm.getWidthInTiles) == "function" then
            loadedW = safeCall1(cm, "getWidthInTiles")
            local x0 = safeCall1(cm, "getWorldXMinTiles")
            local y0 = safeCall1(cm, "getWorldYMinTiles")
            local x1 = safeCall1(cm, "getWorldXMaxTiles")
            local y1 = safeCall1(cm, "getWorldYMaxTiles")
            print(string.format("[CU-Verify] loaded window tiles: X %s..%s  Y %s..%s  width=%s",
                tostring(x0), tostring(x1), tostring(y0), tostring(y1), tostring(loadedW)))
        end
    end

    if renderW and loadedW then
        local need = math.max(renderW, renderH)
        local margin = loadedW - need
        print(string.format("[CU-Verify] margin = loaded(%s) - render(%s) = %+.0f tiles %s",
            tostring(loadedW), tostring(need), margin,
            margin >= 0 and "(COVERED)" or "(SHORT: edges may void/pop)"))
    else
        print("[CU-Verify] window readings incomplete; cannot judge coverage")
    end
    print("[CU-Verify] real zombies=" .. tostring(countZombies()))
end
