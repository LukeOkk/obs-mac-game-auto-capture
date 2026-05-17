# Contributing

Thanks for considering a contribution. This is a small Obj-C / C plugin for
OBS on macOS — pull requests for new detection rules, locales, and bug fixes
are welcome.

## Build locally

```sh
chmod +x build.sh
./build.sh
```

`build.sh` will install `cmake` via Homebrew if missing, download a cached
copy of `obs-deps`, clone obs-studio source for the libobs headers, build the
plugin against `/Applications/OBS.app/Contents/Frameworks/libobs.framework/libobs`,
and install the resulting `.plugin` bundle into
`~/Library/Application Support/obs-studio/plugins/`.

To produce distributable `.zip` and `.dmg` artifacts:

```sh
chmod +x package.sh
./package.sh
# Artifacts land in dist/.
```

## Adding detection for a new game / launcher / emulator

There are four place to extend, in priority order:

1. **`kKnownGameBundles`** (`src/game-auto-source.m`) — exact bundle ID match.
   Add the game's `CFBundleIdentifier`. Best for stable, well-known games.
2. **`kGameWrapperPathHints`** — substring matched against the executable
   path of any ancestor process of the running app. Use for runtimes/wrappers
   that host arbitrary games (CrossOver, Whisky, Wineskin, GameHub).
3. **`kWindowTitleGamePrefixes`** — prefix matched against window titles, for
   processes that have no useful bundle ID (e.g. Minecraft Java via JVM).
4. **`kCrossOverHelperPrefixes`** — bundle-ID prefixes for static helper
   wrappers; rarely matches at runtime, mostly a fallback.

If your addition is a launcher you do **not** want captured, also add it to
the appropriate blocklist (`kLauncherBundleHints`, `kCrossOverLauncherNames`,
`kIOSUtilityBlocklist`, or `kWineLauncherExes`).

When you submit a PR, please include:

- The bundle ID (or path hint / window title).
- A short note on how you verified detection works (one log line is enough).

## Adding a locale

1. Copy `data/locale/en-US.ini` to `data/locale/<your-locale>.ini`.
2. Translate the values on the right side of `=`.
3. Keep the keys (left side) unchanged.

OBS auto-picks the locale based on its UI language with `en-US` as fallback.

## Code style

- Prefer explicit over clever.
- ARC is on (`-fobjc-arc`) — no manual retain/release of Obj-C objects.
- Free `obs_data_t *` with `obs_data_release` and array handles with
  `obs_data_array_release` — the OBS C API uses manual reference counting.
- All log lines go through the `PLUGIN_LOG` macro so they share the
  `[mac-game-auto]` prefix and are greppable in `~/Library/Application
  Support/obs-studio/logs/`.

## License

By contributing, you agree your work is licensed under the MIT License
(see `LICENSE`).
