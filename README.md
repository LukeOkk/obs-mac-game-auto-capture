# obs-mac-game-auto-capture

An OBS Studio plugin for macOS that automatically captures **only the games
you're actually playing** — never the desktop, browser, Discord, chat
windows, or whatever else happens to be open.

It works across native Mac games, iOS-on-Mac apps, CrossOver / Whisky / Wine
games, Windows games launched from Steam-via-CrossOver, Java games
(Minecraft), and emulators (Ryujinx, OpenEmu, RPCS3, Dolphin, RetroArch, …).

## Install

### Option A — Drag-and-drop `.dmg` (easiest)

1. Download the latest `obs-mac-game-auto-capture-<version>-arm64.dmg` from
   the [Releases](../../releases) page.
2. Open the `.dmg`. Drag `obs-mac-game-auto-capture.plugin` onto the
   "Drag plugin here" alias inside the disk image.
3. Quit OBS Studio if it's running, then open it again.
4. In any scene, click **+ → Mac Game Auto Capture**.

If macOS warns that the plugin is from an unidentified developer, open
**System Settings → Privacy & Security**, scroll down, and click
**Open Anyway** next to the plugin's warning.

### Option B — Manual `.zip`

1. Download `obs-mac-game-auto-capture-<version>-arm64.zip` from
   [Releases](../../releases).
2. Unzip and copy `obs-mac-game-auto-capture.plugin` to
   `~/Library/Application Support/obs-studio/plugins/`.
3. Restart OBS.

### Option C — Build from source

```sh
git clone https://github.com/<you>/obs-mac-game-auto-capture.git
cd obs-mac-game-auto-capture
chmod +x build.sh
./build.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## What it does

Adds a new source to OBS called **Mac Game Auto Capture**. Once added to a
scene, the source:

1. Watches which application is frontmost (and polls window changes every
   3 seconds).
2. Decides whether that app is a game using a layered rule cascade
   (Apple's `LSSupportsGameMode`, game-category `LSApplicationCategoryType`,
   CrossOver / Whisky / GameHub / Wineskin process-tree match, hardcoded
   known-games list, iOS-on-Mac heuristic, Minecraft window-title fallback,
   manual whitelist). The first matching rule wins.
3. If yes, captures the app's main window with
   [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit),
   normalized to 1920×1080 so it fills the OBS canvas.
4. Captures the app's audio as well (only the captured app — background
   browser / chat / music audio is excluded by design).
5. If you alt-tab to OBS, the game keeps streaming (with
   `Keep capturing on alt-tab`). Switching to a different game rebinds.
6. If no app passes the rules, the stream tears down so the source is
   visibly blank instead of streaming your desktop.

## Settings

In the source's properties:

- **Strict mode** (default: on) — only capture apps recognized as games.
- **Use category hint** (default: on) — accept apps with a games
  `LSApplicationCategoryType`.
- **Treat iOS apps as games** (default: on) — Stumble Guys, Among Us,
  Pokémon Unite, etc.
- **Fullscreen fallback** (default: off) — when strict mode is off, also
  capture any fullscreen non-launcher app.
- **Keep capturing on alt-tab** (default: on) — don't tear the stream
  down when you switch to chat / OBS / a browser.
- **Capture game audio** (default: on) — pull the captured app's audio
  into OBS too.
- **Manual whitelist** — pick a running app from the dropdown, click
  *Add*. Listed bundle IDs are always captured. Click an entry's *X* to
  remove (takes effect within the next 3-second poll).

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon
- OBS Studio 30.0 or newer
- For building from source: Xcode Command Line Tools, CMake 3.28+

OBS needs **Screen & System Audio Recording** permission. macOS will prompt
on first capture.

## Known limitations

- Games using exclusive Metal layers can return black frames when not the
  frontmost app. Borderless-windowed mode usually works around this.
- iOS-on-Mac apps (Mac Catalyst / iPhone-app-on-Mac) pause rendering when
  not frontmost — capture goes blank if you alt-tab away from such a game.
  Native Mac games and emulators don't have this limitation.
- macOS doesn't expose a public API for "Game Mode is active right now."
  We use `LSSupportsGameMode` + `LSApplicationCategoryType` as the
  closest public proxies, plus the wrapper-process-tree walk and the
  hardcoded known-games list.

## License

MIT — see [LICENSE](LICENSE).
