# Changelog

All notable changes are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

First public release.

### Detection
- Apple-recognized games via `LSSupportsGameMode` (Info.plist).
- Apps declaring a games category in `LSApplicationCategoryType`.
- CrossOver / Wine / Whisky / Wineskin / Kegworks / Heroic / GameHub /
  PortingKit / PlayCover / UTM children, detected via a `sysctl` +
  `proc_pidpath` walk up the process tree.
- iOS-on-Mac apps (Mac Catalyst / iPhone-app-on-Mac), with a blocklist of
  obvious utilities (Moovit, Waze, Uber, social/streaming apps).
- Hardcoded known-games list for stable big titles (Roblox, Minecraft launcher,
  Stumble Guys, Fortnite, LoL, Valorant, Dota 2, WoW, Overwatch, Diablo IV,
  Hearthstone, CoD MW, EA app), all common emulators (OpenEmu, Ryujinx,
  RPCS3, Dolphin, RetroArch, ScummVM, Citra, DuckStation, PCSX2, Mednafen,
  PPSSPP, Cemu, Provenance, shadPS4, Azahar, Suyu, snes9x), and wine `.exe`
  launcher exclusion (Steam UI, Epic Games Launcher, Battle.net, etc.).
- Window-title fallback for processes with no bundle ID (e.g. Minecraft Java
  via the JVM).
- Manual whitelist edited via a click-based picker of currently-running apps.

### Capture
- Video via `SCContentFilter initWithDesktopIndependentWindow:` (crosses
  macOS Spaces, so fullscreen-Space games keep capturing when OBS is on a
  different Space).
- Output normalized to 1920×1080 with `scalesToFit = YES` so small launcher
  windows don't appear as a tiny icon on the OBS canvas.
- Audio for the same app the video filter targets (`cfg.capturesAudio = YES`),
  delivered as non-interleaved Float32 PCM at 48 kHz stereo and pushed to OBS
  via `obs_source_output_audio` with `AUDIO_FORMAT_FLOAT_PLANAR`. Background
  apps (browser, chat) are not in the filter so their audio doesn't enter the
  stream.
- Sticky window logic: rebind only when the current window is gone, has
  shrunk below 400×300, has been replaced by a window ≥1.5× the current
  area, or by a window matching a known game-title pattern.
- 3-second polling timer plus an `NSWorkspace` activation observer so
  launcher → game-window transitions (Minecraft launcher → world, Ryujinx
  menu → ROM) catch up.
- `keep_capturing_on_alt_tab` toggle (default on) keeps the stream alive
  when the user alt-tabs to OBS / chat / a browser, so the preview doesn't
  go black mid-stream.

### UI / packaging
- Localized in `en-US`, `es-ES`, `pt-BR`, `fr-FR`, `de-DE`, `it-IT`, `ja-JP`,
  `ko-KR`, `zh-CN`, `ru-RU`.
- `build.sh` handles cmake install, obs-deps download, obs-studio header
  clone, `obsconfig.h` synthesis, and `.plugin` bundle install — single
  command from a fresh checkout.
- `package.sh` produces `.zip` and `.dmg` artifacts in `dist/` for releases.
