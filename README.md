# Codex Runlight

Tiny macOS menu bar app that shows whether Codex Desktop is currently thinking.

## Features
- Menu bar indicator for `thinking` vs `dormant`
- Scope picker: `All` or a specific workspace
- Preset indicator styles (no custom input):
  - Animated Wheel: `◐ ◓ ◑ ◒` / `⏸️`
  - Play/Pause: `▶️` / `⏸️`
  - Run/Sleep: `🏃` / `💤`
- One-click `Copy Diagnostics` for support/debugging
- Launch at login via LaunchAgent

## Install
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

## Privacy
- Reads local Codex state from `~/.codex/.codex-global-state.json`
- Uses local process CPU (`pgrep`, `ps`) to estimate activity
- Sends no analytics and performs no network requests

## License
MIT
