import AppKit
import Foundation

final class CodexRunlightApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var animationTimer: Timer?
    private var spinnerFrameIndex: Int = 0
    private var lastComputedBusyForSelectedScope: Bool = false

    private let refreshInterval: TimeInterval = 3
    private let cpuBusyThresholdPercent: Double = 8.0

    private let codexStatePath = (FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")
        .appendingPathComponent(".codex-global-state.json")).path

    private let defaults = UserDefaults.standard
    private let selectedKey = "CodexRunlight.selectedScope" // "ALL" or workspace root path
    private let styleKey = "CodexRunlight.style"

    private struct IndicatorStyle {
        let id: String
        let title: String
        let runningFrames: [String]
        let dormantGlyph: String

        var isAnimated: Bool { runningFrames.count > 1 }
        var runningGlyph: String { runningFrames.first ?? "▶️" }
    }

    private let styles: [IndicatorStyle] = [
        IndicatorStyle(
            id: "animated-wheel",
            title: "Animated Wheel (◐◓◑◒ / ⏸️)",
            runningFrames: ["◐", "◓", "◑", "◒"],
            dormantGlyph: "⏸️"
        ),
        IndicatorStyle(
            id: "play-pause",
            title: "Play/Pause (▶️ / ⏸️)",
            runningFrames: ["▶️"],
            dormantGlyph: "⏸️"
        ),
        IndicatorStyle(
            id: "run-sleep",
            title: "Run/Sleep (🏃 / 💤)",
            runningFrames: ["🏃"],
            dormantGlyph: "💤"
        )
    ]

    private enum Scope: Equatable {
        case all
        case workspaceRoot(String)

        var persistedValue: String {
            switch self {
            case .all: return "ALL"
            case .workspaceRoot(let p): return p
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageLeft
        statusItem.menu = buildMenu(state: currentState())

        refreshUI()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }

        // Animate the "thinking" indicator smoothly; we only update the title here,
        // and refreshUI() updates whether we're actually busy.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tickSpinner()
        }
    }

    @objc private func refreshNow() {
        refreshUI()
    }

    @objc private func openCodex() {
        let path = "/Applications/Codex.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func copyDiagnostics() {
        let scope = selectedScope().persistedValue
        let style = selectedStyle().id
        let pids = codexPids()
        let cpu = combinedCpuPercent(pids: pids)
        let statePath = codexStatePath
        let stateExists = FileManager.default.fileExists(atPath: statePath)

        let payload: [String: Any] = [
            "app": "Codex Runlight",
            "scope": scope,
            "style": style,
            "state_path": statePath,
            "state_exists": stateExists,
            "codex_pid_count": pids.count,
            "combined_cpu_percent": cpu,
            "busy_threshold_percent": cpuBusyThresholdPercent,
        ]

        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: selectedKey)
        refreshUI()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: styleKey)
        spinnerFrameIndex = 0
        refreshUI()
    }

    private struct PulseState {
        let savedWorkspaceRoots: [String]
        let activeWorkspaceRoots: [String]
        let labelsByRoot: [String: String]
        let anyBusy: Bool
    }

    private func currentState() -> PulseState {
        let (saved, active, labels) = readCodexState()
        let anyBusy = isCodexBusy(cpuThresholdPercent: cpuBusyThresholdPercent)
        return PulseState(
            savedWorkspaceRoots: saved,
            activeWorkspaceRoots: active,
            labelsByRoot: labels,
            anyBusy: anyBusy
        )
    }

    private func selectedScope() -> Scope {
        let raw = defaults.string(forKey: selectedKey) ?? "ALL"
        if raw == "ALL" { return .all }
        return .workspaceRoot(raw)
    }

    private func refreshUI() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let state = self.currentState()
            let scope = self.selectedScope()

            let busy = self.isBusy(scope: scope, state: state)

            DispatchQueue.main.async {
                self.statusItem.button?.image = nil
                self.lastComputedBusyForSelectedScope = busy
                if !busy {
                    self.statusItem.button?.title = self.selectedStyle().dormantGlyph
                }
                self.statusItem.button?.toolTip = self.tooltipText(scope: scope, state: state)
                self.statusItem.menu = self.buildMenu(state: state)
            }
        }
    }

    private func isBusy(scope: Scope, state: PulseState) -> Bool {
        switch scope {
        case .all:
            return state.anyBusy
        case .workspaceRoot(let root):
            return state.anyBusy && state.activeWorkspaceRoots.contains(root)
        }
    }

    private func tickSpinner() {
        guard let button = statusItem.button else { return }
        let style = selectedStyle()
        if lastComputedBusyForSelectedScope {
            let frames = style.runningFrames
            let glyph = frames[spinnerFrameIndex % frames.count]
            spinnerFrameIndex = (spinnerFrameIndex + 1) % frames.count
            button.title = glyph
        } else {
            button.title = style.dormantGlyph
        }
    }

    private func tooltipText(scope: Scope, state: PulseState) -> String {
        switch scope {
        case .all:
            return state.anyBusy ? "Codex: thinking" : "Codex: dormant"
        case .workspaceRoot(let root):
            let label = shortLabel(forRoot: root, labelsByRoot: state.labelsByRoot)
            let busy = state.anyBusy && state.activeWorkspaceRoots.contains(root)
            return busy ? "\(label): thinking" : "\(label): dormant"
        }
    }

    private func buildMenu(state: PulseState) -> NSMenu {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let diagItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "d")
        diagItem.target = self
        menu.addItem(diagItem)

        menu.addItem(.separator())

        let styleHeader = NSMenuItem(title: "Indicator Style", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        menu.addItem(styleHeader)

        let selectedStyleId = selectedStyle().id
        for style in styles {
            let item = NSMenuItem(title: style.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.id
            item.state = (style.id == selectedStyleId) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let scopeHeader = NSMenuItem(title: "Scope", action: nil, keyEquivalent: "")
        scopeHeader.isEnabled = false
        menu.addItem(scopeHeader)

        let selected = selectedScope().persistedValue

        let allItem = NSMenuItem(title: "All", action: #selector(selectScope(_:)), keyEquivalent: "1")
        allItem.target = self
        allItem.representedObject = "ALL"
        allItem.state = (selected == "ALL") ? .on : .off
        menu.addItem(allItem)

        // Prefer showing all known workspaces so you can pre-select a project,
        // but annotate active ones in the title so it's obvious what's running.
        let saved = state.savedWorkspaceRoots
        if !saved.isEmpty {
            for (idx, root) in saved.enumerated() {
                let base = shortLabel(forRoot: root, labelsByRoot: state.labelsByRoot)
                let isActive = state.anyBusy && state.activeWorkspaceRoots.contains(root)
                let title = isActive ? "\(base) (active)" : base

                let item = NSMenuItem(title: title, action: #selector(selectScope(_:)), keyEquivalent: "")
                // Optional quick keys for first 9 workspaces.
                if idx < 9 { item.keyEquivalent = "\(idx + 2)" }
                item.target = self
                item.representedObject = root
                item.state = (selected == root) ? .on : .off
                menu.addItem(item)
            }
        } else {
            let noneItem = NSMenuItem(title: "No workspaces detected", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        }

        menu.addItem(.separator())

        let statusLine = statusLineItem(state: state)
        menu.addItem(statusLine)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Runlight", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func statusLineItem(state: PulseState) -> NSMenuItem {
        let anyBusy = state.anyBusy
        let active = state.activeWorkspaceRoots
        let title: String

        if !anyBusy {
            title = "Dormant"
        } else if active.isEmpty {
            title = "Thinking (workspace unknown)"
        } else if active.count == 1 {
            let label = shortLabel(forRoot: active[0], labelsByRoot: state.labelsByRoot)
            title = "Thinking: \(label)"
        } else {
            let labels = active.map { shortLabel(forRoot: $0, labelsByRoot: state.labelsByRoot) }.joined(separator: ", ")
            title = "Thinking: \(labels)"
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func shortLabel(forRoot root: String, labelsByRoot: [String: String]) -> String {
        if let label = labelsByRoot[root], !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clamp(label, max: 14)
        }
        let last = URL(fileURLWithPath: root).lastPathComponent
        if !last.isEmpty { return clamp(last, max: 14) }
        return clamp(root, max: 14)
    }

    private func selectedStyle() -> IndicatorStyle {
        let raw = defaults.string(forKey: styleKey) ?? "animated-wheel"
        return styles.first(where: { $0.id == raw }) ?? styles[0]
    }

    private func clamp(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 3)) + "..."
    }

    private func readCodexState() -> (saved: [String], active: [String], labels: [String: String]) {
        // This file appears to be shared state between Codex Desktop and the CLI.
        // We only depend on a few keys and fail soft if the file is missing/invalid.
        guard let data = FileManager.default.contents(atPath: codexStatePath) else {
            return ([], [], [:])
        }

        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else { return ([], [], [:]) }

            let saved = dict["electron-saved-workspace-roots"] as? [String] ?? []
            let active = dict["active-workspace-roots"] as? [String] ?? []

            var labels: [String: String] = [:]
            if let raw = dict["electron-workspace-root-labels"] as? [String: Any] {
                for (k, v) in raw {
                    if let s = v as? String { labels[k] = s }
                }
            }

            return (saved, active, labels)
        } catch {
            return ([], [], [:])
        }
    }

    private func isCodexBusy(cpuThresholdPercent: Double) -> Bool {
        // Heuristic: if the combined CPU usage of Codex-related processes is above a threshold,
        // treat it as "thinking". This is not perfect (network-wait phases can appear idle),
        // but it's a reliable lightweight signal without tapping private app internals.
        let pids = codexPids()
        if pids.isEmpty { return false }

        let cpu = combinedCpuPercent(pids: pids)
        return cpu >= cpuThresholdPercent
    }

    private func codexPids() -> [Int] {
        // Match Codex Desktop's app bundle paths.
        let patterns = [
            "/Applications/Codex.app/Contents/MacOS/Codex",
            "/Applications/Codex.app/Contents/Frameworks/",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]

        var out: Set<Int> = []
        for pat in patterns {
            let pgrep = runProcess("/usr/bin/pgrep", args: ["-f", pat])
            for tok in pgrep.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
                if let pid = Int(tok) { out.insert(pid) }
            }
        }
        return out.sorted()
    }

    private func combinedCpuPercent(pids: [Int]) -> Double {
        // ps can take a comma-separated pid list.
        let pidList = pids.map(String.init).joined(separator: ",")
        let psOut = runProcess("/bin/ps", args: ["-p", pidList, "-o", "%cpu="])

        var total: Double = 0
        for line in psOut.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let v = Double(trimmed) { total += v }
        }
        return total
    }

    private func runProcess(_ path: String, args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

let app = NSApplication.shared
let delegate = CodexRunlightApp()
app.delegate = delegate
app.run()
