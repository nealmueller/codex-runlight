# Codex Runlight

Tiny macOS menu bar app that shows whether Codex Desktop is currently thinking.

## Features
- Menu bar indicator for `thinking` vs `dormant`
- Scope picker: `All` or a specific workspace
- Hybrid detection engine:
  - Accessibility signal from Codex UI text
  - Process CPU activity signal
  - Recent Codex state-file activity signal
  - Hysteresis to reduce flicker
- Preset indicator styles (no custom input):
  - Animated Wheel: `◐ ◓ ◑ ◒` / `⏸️`
  - Play/Pause: `▶️` / `⏸️`
  - Run/Sleep: `🏃` / `💤`
- One-click `Copy Diagnostics` for support/debugging
- Launch at login via LaunchAgent

## Install (Easiest)
1. Download `CodexRunlight-macos.dmg` from Releases.
2. Open the DMG and drag `Codex Runlight.app` into `Applications`.
3. Launch `Codex Runlight.app`.

## Install (CLI)
```bash
./install.sh
```

## Uninstall
```bash
launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/io.github.codex-runlight.agent.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/io.github.codex-runlight.agent.plist"
rm -rf "$HOME/Library/Application Support/CodexRunlight"
```

## Build Locally
```bash
/usr/bin/swiftc -O -framework AppKit -framework Foundation -o CodexRunlight CodexRunlight.swift
```

## Build App + DMG Locally
```bash
chmod +x scripts/build_macos_artifacts.sh
VERSION=0.1.2 scripts/build_macos_artifacts.sh
```

By default, artifacts are unsigned. For smoother install on other machines, use Developer ID signing + notarization with:
- `CODESIGN_IDENTITY`
- `NOTARY_PROFILE`

## Privacy
- Reads local Codex state from `~/.codex/.codex-global-state.json`
- Uses local process CPU (`pgrep`, `ps`) to estimate activity
- Optionally uses Accessibility data (if granted) to improve accuracy
- Sends no analytics and performs no network requests

## License
MIT
