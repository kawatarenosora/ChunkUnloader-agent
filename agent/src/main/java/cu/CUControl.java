package cu;

/**
 * Lua bridge for ChunkUnloader (exposed as global CUControl via cu-agent).
 *
 * Background: the Lua-side IsoChunkMap table is a snapshot mirror, so writing
 * IsoChunkMap.chunkGridWidth from Lua never reaches the engine (proven:
 * Lua grid=5 while Java tiles stayed 152). These setters write the real
 * public static fields (javap verified on b42.20.04 / B42.21).
 * All methods are static and pcall-safe; every setter logs.
 *
 * Agent edition: identical logic to the former ZombieBuddy edition, minus
 * the ZB {@code Exposer} coupling. Publication to Lua is done by the
 * javaagent (cu.Agent hooking LuaManager$Exposer.exposeAll), and the
 * CalcChunkWidth hook by ByteBuddy advice (former ZB @Patch).
 */
public class CUControl {
    public static final String VERSION = "1.5.0-agent";
    public static final int MIN_GRID = 3;
    public static final int MAX_GRID = 19;
    public static final int TILES_PER_CHUNK = 8;

    /** Pending request kind: 0 = none, 1 = absolute grid, 2 = offset/base. */
    public static volatile int pendingKind = 0;
    /** Pending absolute grid for the CalcChunkWidth hook. 0 = none. Pre-load only. */
    public static volatile int pendingGrid = 0;
    /** Pending resolution-relative request (base minus this, 0 = base itself).
     * Takes precedence over pendingGrid; the setters keep them mutually
     * exclusive via {@link #pendingKind}. */
    public static volatile int pendingOffset = 0;
    /** Last CalcChunkWidth-computed (vanilla, resolution-derived) grid.
     * 0 = not yet observed this boot. Updated on EVERY Calc exit, even
     * mid-game (observation only; writes still gated by worldLoaded). */
    public static volatile int vanillaGrid = 0;
    /** Last resolution-adjusted base actually used (vanilla, or the raised
     * 1440p/4K base). 0 = none yet. */
    public static volatile int lastBase = 0;
    /** Last grid actually written by the hook / pending fast-path. 0 = none. */
    public static volatile int lastEffective = 0;
    /** True while a world is loaded. The hook skips writes then (mid-game
     * static rewrites desync chunk mapping and crash the game). */
    public static volatile boolean worldLoaded = false;

    public static String version() {
        return VERSION;
    }

    public static int toOdd(int n) {
        if (n < MIN_GRID) n = MIN_GRID;
        if (n > MAX_GRID) n = MAX_GRID;
        if ((n % 2) == 0) n = n + 1;
        if (n > MAX_GRID) n = MAX_GRID;
        return n;
    }

    /** Set chunk grid width (forced odd, clamped 3..19). Returns applied grid, or -1 on failure. */
    public static int setGrid(int grid) {
        try {
            int g = toOdd(grid);
            zombie.iso.IsoChunkMap.chunkGridWidth = g;
            zombie.iso.IsoChunkMap.chunkWidthInTiles = g * TILES_PER_CHUNK;
            System.out.println("[CU-Java] chunkGridWidth=" + g
                + " chunkWidthInTiles=" + zombie.iso.IsoChunkMap.chunkWidthInTiles);
            return g;
        } catch (Throwable t) {
            System.err.println("[CU-Java] setGrid failed: " + t);
            return -1;
        }
    }

    /** Real engine grid width, or -1 on failure. */
    public static int getGrid() {
        try {
            return zombie.iso.IsoChunkMap.chunkGridWidth;
        } catch (Throwable t) {
            System.err.println("[CU-Java] getGrid failed: " + t);
            return -1;
        }
    }

    /** Real engine tiles width, or -1 on failure. */
    public static int getTiles() {
        try {
            return zombie.iso.IsoChunkMap.chunkWidthInTiles;
        } catch (Throwable t) {
            System.err.println("[CU-Java] getTiles failed: " + t);
            return -1;
        }
    }

    public static String status() {
        try {
            return "grid=" + zombie.iso.IsoChunkMap.chunkGridWidth
                + " tiles=" + zombie.iso.IsoChunkMap.chunkWidthInTiles
                + " kind=" + pendingKind
                + " pending=" + pendingGrid
                + " offset=" + pendingOffset
                + " vanilla=" + vanillaGrid
                + " base=" + lastBase
                + " effective=" + lastEffective
                + " loaded=" + worldLoaded;
        } catch (Throwable t) {
            return "error: " + t;
        }
    }

    /** Last observed vanilla (resolution-derived) grid, or 0 if Calc has
     * not run yet this boot. -1 on failure. */
    public static int getVanillaGrid() {
        try {
            return vanillaGrid;
        } catch (Throwable t) {
            return -1;
        }
    }

    /** Last resolution-adjusted base used (vanilla, or raised 21/23 at
     * high resolution). 0 if not yet resolved this boot. -1 on failure. */
    public static int getBaseGrid() {
        try {
            return lastBase;
        } catch (Throwable t) {
            return -1;
        }
    }

    /** Last grid actually applied by the hook / pending fast-path (0 = none). */
    public static int getEffectiveGrid() {
        try {
            return lastEffective;
        } catch (Throwable t) {
            return -1;
        }
    }

    /** Write both statics. Caller must have decided the value already. */
    private static void writeGrid(int g) {
        zombie.iso.IsoChunkMap.chunkGridWidth = g;
        zombie.iso.IsoChunkMap.chunkWidthInTiles = g * TILES_PER_CHUNK;
    }

    /** Cap a request at the observed vanilla grid (never enlarge).
     * Vanilla <= 0 means "not yet observed": no cap possible. */
    private static int capAtVanilla(int requested, int vanilla) {
        int r = toOdd(requested);
        if (vanilla >= MIN_GRID) {
            int v = toOdd(vanilla);
            if (r > v) {
                return v;
            }
        }
        return r;
    }

    /** Resolve a resolution-relative request against a base grid.
     * Bases are odd and offsets even, so the result stays odd; any even
     * outcome is rounded DOWN (never enlarge past base-offset), then floored
     * at MIN_GRID. */
    private static int resolveOffset(int offset, int base) {
        int b = base;
        if ((b % 2) == 0) {
            b = b - 1;
        }
        if (b < MIN_GRID) {
            b = MIN_GRID;
        }
        int e = b - offset;
        if ((e % 2) == 0) {
            e = e - 1;
        }
        if (e < MIN_GRID) {
            e = MIN_GRID;
        }
        if (e > b) {
            e = b;
        }
        return e;
    }

    /** Screen-size ratio mirroring the engine's own CalcChunkWidth measure
     * (max(w/1920, h/1080)), but WITHOUT the engine's 1.0 clamp so high
     * resolutions are visible. 0 when unreadable (fail safe: vanilla base). */
    private static float resScale() {
        try {
            zombie.core.Core core = zombie.core.Core.getInstance();
            if (core == null) {
                return 0f;
            }
            float w = (float) core.getScreenWidth() / 1920.0f;
            float h = (float) core.getScreenHeight() / 1080.0f;
            return Math.max(w, h);
        } catch (Throwable t) {
            return 0f;
        }
    }

    /** Resolution-adjusted base: the vanilla grid, raised to 21 on 1440p
     * class (r >= 1.2) and 23 on 4K class (r >= 1.75) so the view stays
     * covered on Escape-large screens. Never lowered below vanilla.
     * Enlargement is applied only at the pre-load sanctioned point
     * (Calc exit / pending fast-path, both before IsoChunkMap allocates
     * its grid*grid arrays), never mid-game. */
    private static int raisedBase(int vanilla) {
        int base = toOdd(vanilla);
        float r = resScale();
        if (r >= 1.75f) {
            if (base < 23) {
                base = 23;
            }
        } else if (r >= 1.2f) {
            if (base < 21) {
                base = 21;
            }
        }
        return base;
    }

    /** Register an absolute grid for the CalcChunkWidth hook. 0 or negative
     * clears every pending request (must NOT pass through toOdd: its floor
     * is 3, which would turn a clear into a bogus grid=3 request -
     * observed bug v0.4.1).
     * If Calc already ran before Lua boot (vanilla known) and no world is
     * loaded yet, the capped value is applied immediately (still pre-load,
     * safe): this covers the Calc-before-boot order. Otherwise the Calc-exit
     * hook applies it when Calc runs (boot order independent).
     * Returns stored value, -1 on failure. */
    public static int setPendingGrid(int grid) {
        try {
            if (grid <= 0) {
                pendingKind = 0;
                pendingGrid = 0;
                pendingOffset = 0;
                System.out.println("[CU-Java] pending cleared (0)");
                return 0;
            }
            pendingKind = 1;
            pendingGrid = toOdd(grid);
            pendingOffset = 0;
            System.out.println("[CU-Java] pendingGrid=" + pendingGrid
                + " vanilla=" + vanillaGrid + " loaded=" + worldLoaded);
            if (!worldLoaded && vanillaGrid >= MIN_GRID) {
                int eff = capAtVanilla(pendingGrid, vanillaGrid);
                writeGrid(eff);
                lastEffective = eff;
                if (eff < pendingGrid) {
                    System.out.println("[CU-Java] pending fast-path capped grid=" + eff
                        + " (requested " + pendingGrid + " > vanilla " + vanillaGrid + ")");
                } else {
                    System.out.println("[CU-Java] pending fast-path applied grid=" + eff);
                }
            }
            return pendingGrid;
        } catch (Throwable t) {
            System.err.println("[CU-Java] setPendingGrid failed: " + t);
            return -1;
        }
    }

    /** Register a resolution-relative request (base minus offset) for the
     * CalcChunkWidth hook. 0 or negative clears every pending request
     * (kept from v1.4: plain 0 stays a clear, the base itself is requested
     * via {@link #setPendingBase}). Same boot-order coverage as
     * {@link #setPendingGrid}: fast-path when vanilla is already known,
     * else the Calc-exit hook resolves it against the resolution-adjusted
     * base. Returns stored offset, -1 on failure. */
    public static int setPendingOffset(int offset) {
        try {
            if (offset <= 0) {
                pendingKind = 0;
                pendingGrid = 0;
                pendingOffset = 0;
                System.out.println("[CU-Java] pending cleared (0)");
                return 0;
            }
            pendingKind = 2;
            pendingOffset = offset;
            pendingGrid = 0;
            System.out.println("[CU-Java] pendingOffset=" + pendingOffset
                + " vanilla=" + vanillaGrid + " loaded=" + worldLoaded);
            if (!worldLoaded && vanillaGrid >= MIN_GRID) {
                int base = raisedBase(vanillaGrid);
                lastBase = base;
                int eff = resolveOffset(pendingOffset, base);
                writeGrid(eff);
                lastEffective = eff;
                System.out.println("[CU-Java] pending fast-path applied grid=" + eff
                    + " (base " + base + " - " + pendingOffset
                    + ", vanilla " + vanillaGrid + ")");
            }
            return pendingOffset;
        } catch (Throwable t) {
            System.err.println("[CU-Java] setPendingOffset failed: " + t);
            return -1;
        }
    }

    /** Request the resolution-adjusted base itself (規定値: vanilla, or the
     * raised 21/23 on high resolution). Separate from
     * {@link #setPendingOffset} so plain 0 keeps its v1.4 clear meaning.
     * Returns 0, -1 on failure. */
    public static int setPendingBase() {
        try {
            pendingKind = 2;
            pendingOffset = 0;
            pendingGrid = 0;
            System.out.println("[CU-Java] pendingBase vanilla=" + vanillaGrid
                + " loaded=" + worldLoaded);
            if (!worldLoaded && vanillaGrid >= MIN_GRID) {
                int base = raisedBase(vanillaGrid);
                lastBase = base;
                writeGrid(base);
                lastEffective = base;
                System.out.println("[CU-Java] pending fast-path applied base grid=" + base
                    + " (vanilla " + vanillaGrid + ")");
            }
            return 0;
        } catch (Throwable t) {
            System.err.println("[CU-Java] setPendingBase failed: " + t);
            return -1;
        }
    }

    public static int getPendingOffset() {
        try {
            return pendingOffset;
        } catch (Throwable t) {
            return -1;
        }
    }

    public static int getPendingGrid() {
        try {
            return pendingGrid;
        } catch (Throwable t) {
            return -1;
        }
    }

    public static void setWorldLoaded(boolean v) {
        try {
            worldLoaded = v;
            System.out.println("[CU-Java] worldLoaded=" + v);
        } catch (Throwable t) {
            System.err.println("[CU-Java] setWorldLoaded failed: " + t);
        }
    }

    /**
     * CalcChunkWidth-exit hook body (former ZB @Patch exit).
     * The engine has JUST computed its vanilla (resolution-derived) grid at
     * this point, so: (1) record it as vanillaGrid, then (2) apply the
     * pending request while still pre world-load - an offset/base request
     * resolved against the resolution-adjusted base (vanilla, or raised
     * 21/23 at high resolution), else an absolute request capped at vanilla.
     * Skipped once a world is loaded (mid-game static rewrites desync chunk
     * mapping -&gt; wall-query infinite recursion -&gt; StackOverflow,
     * observed at f:21); vanilla is still recorded then for display.
     */
    public static void applyPending() {
        try {
            int vanilla = zombie.iso.IsoChunkMap.chunkGridWidth;
            if (vanilla >= MIN_GRID) {
                vanillaGrid = vanilla;
            }
            if (worldLoaded) {
                return;
            }
            if (pendingKind == 2 && vanillaGrid >= MIN_GRID) {
                int base = raisedBase(vanillaGrid);
                lastBase = base;
                int g = resolveOffset(pendingOffset, base);
                writeGrid(g);
                lastEffective = g;
                System.out.println("[CU-Java] Calc hook applied grid=" + g
                    + " (base " + base + " - " + pendingOffset
                    + ", vanilla " + vanillaGrid + ")");
                return;
            }
            if (pendingKind != 1) {
                return;
            }
            int pending = pendingGrid;
            if (pending < MIN_GRID) {
                return;
            }
            int g = capAtVanilla(pending, vanillaGrid);
            writeGrid(g);
            lastEffective = g;
            if (g < pending) {
                System.out.println("[CU-Java] Calc hook capped grid=" + g
                    + " (requested " + pending + " > vanilla " + vanillaGrid + ")");
            } else {
                System.out.println("[CU-Java] Calc hook applied grid=" + g);
            }
        } catch (Throwable t) {
            System.err.println("[CU-Java] Calc hook failed: " + t);
        }
    }
}
