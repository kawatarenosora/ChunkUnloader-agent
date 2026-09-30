# ChunkUnloader [agent] - Chunk range mod that trims unnecessary chunks

A JavaAgent mod for Project Zomboid B42.21. Changes the chunk load range once at startup and cuts outer unnecessary chunks to improve FPS.

The vanilla default (19 at 1080p) covers the full-screen range, but that width is only needed when you zoom out to the maximum render range and look farthest with aim camera pan. In normal play you rarely look that far, so this mod reduces outer chunk loading in tiers.

> [!NOTE]
> The Java part of this mod (cu-agent) must be specified via `-javaagent`. Subscribing alone does not enable it.

- Supported: Build 42.21 / modversion 1.6.0
- Client-side only. No server installation needed

## Base values (auto-adjusted per resolution)

The mod uses the engine-calculated vanilla value as the base. At high resolutions the vanilla value alone is not enough visually, so the base is raised.

| Resolution | Base |
| --- | --- |
| 1080p and below | Vanilla value (19 at 1080p, 13 at 720p, etc.) |
| 1440p class | 21 |
| 4K class | 23 |

Note: at low resolutions the base is never enlarged beyond the vanilla value (to avoid extra load).

## Modes (Base / Base-2 / -4 / -6, default: Base)

Change it in the Mod Options on the title screen. A restart is required after changing it.

| Mode | Description |
| --- | --- |
| OFF | Vanilla (no changes) |
| Base | Applies the base values above as-is (visual priority) |
| Base-2 | Base -2 (equiv. 17 at 1080p. Almost no visual issue) |
| Base-4 | Base -4 (equiv. 15 at 1080p. No practical issue) |
| Base-6 | Base -6 (equiv. 13 at 1080p. Lower limit for on-foot play. Unloaded areas may appear during fast driving + camera pan) |

Note: visual safety is not unified across all resolutions, so if you play at a resolution other than 1080p, verify with `ChunkUnloader.Verify()` and adjust.

## Requirements / Installation

### jar location (when subscribed via Workshop)

```text
<SteamLibrary>\steamapps\workshop\content\108600\3810703793\mods\ChunkUnloader-agent\42.21\agent\cu-agent.jar
```

Note: `<SteamLibrary>` varies by environment (default is `C:\Program Files (x86)\Steam`).
How to check: Steam "Settings -> Storage" library folder, or game Properties -> "Installed Files" -> "Browse".

### Windows (recommended): use the launcher

No manual JVM option editing or jar copying needed. Just point [PZ-JAM-Launcher](https://github.com/kawatarenosora/PZ-JAM-Launcher) to the jar above and launch.

### Windows (manual setup)

1. Open `C:\` in Explorer, create a new folder named `PZAgents` (result: `C:\PZAgents`).
2. Quit the game and copy the jar above into `C:\PZAgents`.
3. Back up `ProjectZomboid64.json` in the game folder, then add the following line inside the existing `vmArgs` array (mind the commas with neighboring entries. No need to replace the whole array).

```json
"-javaagent:C:/PZAgents/cu-agent.jar"
```

Note: if you want another folder, replace the path accordingly (for advanced users).

### macOS / Linux (manual setup)

1. Create a `PZAgents` folder in your home folder and copy the jar above into it.
2. In Project Zomboid Properties -> "Launch Options", add the following (don't forget the trailing `--`).

```text
-javaagent:"~/PZAgents/cu-agent.jar" --
```

Note: if you want another folder, replace the path accordingly (for advanced users).

## Verify / Update / Remove

- Check that the startup log contains a `[CU-Agent]` line. If there is a transformation error, a version mismatch is suspected.
- jar updates are announced in the Workshop changelog. Manual-setup users should re-copy after the announcement (launcher users need no reconfiguration).
- To disable, disable the mod and remove only the argument above.
- Note: no server installation needed (client-side only).

## Notes

- The range is applied only once at startup. Rewriting mid-play breaks chunk management and crashes, so this mod never rewrites after world load.
- Returning to the title screen is not enough to apply setting changes. Quit the game once and restart it.
- Changing mod settings in-game combined with display mode / resolution changes may crash, so change settings in the title screen options.

## Verification (Lua console)

```lua
-- Show current grid / base / applied values
ChunkUnloader.PrintState()

-- Numerically verify render range vs. load range margin
ChunkUnloader.Verify()
```

## Repository layout

```text
42.21/
  media/lua/client/   Lua body (applied once at boot, read-only afterwards)
  agent/cu-agent.jar  Distributable Java agent
agent/src/            cu-agent sources (ByteBuddy hooks)
dist/cu-agent.jar     Distributable copy
```

## Credits

- Uses [ByteBuddy](https://bytebuddy.net/) as the hook foundation for the Java agent.

## License

MIT License. See `LICENSE` for details.
