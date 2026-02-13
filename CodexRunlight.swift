import AppKit
import ApplicationServices
import Foundation

final class CodexRunlightApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var animationTimer: Timer?
    private var spinnerFrameIndex: Int = 0
    private var lastComputedBusyForSelectedScope: Bool = false

    private let refreshInterval: TimeInterval = 2
    private let processCpuBusyThresholdPercent: Double = 8.0
    private let stateFreshnessWindowSeconds: TimeInterval = 12

    private let codexStatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")
        .appendingPathComponent(".codex-global-state.json")
        .path

    private let defaults = UserDefaults.standard
    private let selectedKey = "CodexRunlight.selectedScope" // "ALL" or workspace root path
    private let styleKey = "CodexRunlight.style"

    // Hysteresis so indicator doesn't flap with noisy signals.
    private var stableBusyState: Bool = false
    private var consecutiveSamplesTowardFlip: Int = 0
    private let samplesRequiredToFlip: Int = 2

    // Last signal snapshot for diagnostics and status details.
    private var lastSignalSnapshot = SignalSnapshot.empty

    private struct IndicatorStyle {
        let id: String
        let title: String
        let runningFrames: [String]
        let dormantGlyph: String
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

    private struct SignalSnapshot {
        let codexPids: [Int]
        let processCpuPercent: Double
        let processBusy: Bool

        let stateFileExists: Bool
        let stateFileAgeSeconds: Double?
        let stateFresh: Bool

        let accessibilityTrusted: Bool
        let accessibilityMatched: Bool

        let rawScore: Double
        let confidence: String
        let finalBusy: Bool

        static let empty = SignalSnapshot(
            codexPids: [],
            processCpuPercent: 0,
            processBusy: false,
            stateFileExists: false,
            stateFileAgeSeconds: nil,
            stateFresh: false,
            accessibilityTrusted: false,
            accessibilityMatched: false,
            rawScore: 0,
            confidence: "low",
            finalBusy: false
        )
    }

    private struct PulseState {
        let savedWorkspaceRoots: [String]
        let activeWorkspaceRoots: [String]
        let labelsByRoot: [String: String]
        let anyBusy: Bool
        let confidence: String
        let signals: SignalSnapshot
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

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tickSpinner()
        }
    }

    @objc private func refreshNow() {
        refreshUI()
    }

    @objc private func openCodex() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app"))
    }

    @objc private func copyDiagnostics() {
        let scope = selectedScope().persistedValue
        let style = selectedStyle().id
        let s = lastSignalSnapshot

        let payload: [String: Any] = [
            "app": "Codex Runlight",
            "scope": scope,
            "style": style,
            "state_path": codexStatePath,
            "state_file_exists": s.stateFileExists,
            "state_file_age_seconds": s.stateFileAgeSeconds as Any,
            "state_fresh_signal": s.stateFresh,
            "codex_pids": s.codexPids,
            "codex_pid_count": s.codexPids.count,
            "process_cpu_percent": s.processCpuPercent,
            "process_busy_threshold_percent": processCpuBusyThresholdPercent,
            "process_busy_signal": s.processBusy,
            "accessibility_trusted": s.accessibilityTrusted,
            "accessibility_signal": s.accessibilityMatched,
            "raw_score": s.rawScore,
            "confidence": s.confidence,
            "stable_busy_state": s.finalBusy,
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

    private func selectedScope() -> Scope {
        let raw = defaults.string(forKey: selectedKey) ?? "ALL"
        if raw == "ALL" { return .all }
        return .workspaceRoot(raw)
    }

    private func selectedStyle() -> IndicatorStyle {
        let raw = defaults.string(forKey: styleKey) ?? "animated-wheel"
        return styles.first(where: { $0.id == raw }) ?? styles[0]
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

    private func currentState() -> PulseState {
        let (saved, active, labels) = readCodexState()
        let signals = computeHybridSignals()

        return PulseState(
            savedWorkspaceRoots: saved,
            activeWorkspaceRoots: active,
            labelsByRoot: labels,
            anyBusy: signals.finalBusy,
            confidence: signals.confidence,
            signals: signals
        )
    }

    private func computeHybridSignals() -> SignalSnapshot {
        let pids = codexPids()
        let cpu = combinedCpuPercent(pids: pids)
        let processBusy = !pids.isEmpty && cpu >= processCpuBusyThresholdPercent

        let (exists, ageSeconds) = stateFileFreshnessAgeSeconds()
        let stateFresh = exists && ((ageSeconds ?? 9_999) <= stateFreshnessWindowSeconds)

        let a11yTrusted = isAccessibilityTrusted()
        let a11yMatched = a11yTrusted && codexAccessibilityIndicatesThinking()

        // Weighted blend: A11y is strongest when available; process and state help as backup.
        var score = 0.0
        if a11yMatched { score += 0.60 }
        if processBusy { score += 0.25 }
        if stateFresh { score += 0.15 }

        let rawBusy = score >= 0.60
        let finalBusy = applyHysteresis(rawBusy)
        let confidence = confidenceLabel(score: score, a11yTrusted: a11yTrusted)

        let snapshot = SignalSnapshot(
            codexPids: pids,
            processCpuPercent: cpu,
            processBusy: processBusy,
            stateFileExists: exists,
            stateFileAgeSeconds: ageSeconds,
            stateFresh: stateFresh,
            accessibilityTrusted: a11yTrusted,
            accessibilityMatched: a11yMatched,
            rawScore: score,
            confidence: confidence,
            finalBusy: finalBusy
        )

        lastSignalSnapshot = snapshot
        return snapshot
    }

    private func applyHysteresis(_ rawBusy: Bool) -> Bool {
        if rawBusy == stableBusyState {
            consecutiveSamplesTowardFlip = 0
            return stableBusyState
        }

        consecutiveSamplesTowardFlip += 1
        if consecutiveSamplesTowardFlip >= samplesRequiredToFlip {
            stableBusyState = rawBusy
            consecutiveSamplesTowardFlip = 0
        }
        return stableBusyState
    }

    private func confidenceLabel(score: Double, a11yTrusted: Bool) -> String {
        if score >= 0.75 { return "high" }
        if score >= 0.45 { return a11yTrusted ? "medium" : "medium (heuristic)" }
        return a11yTrusted ? "low" : "low (heuristic)"
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
            return state.anyBusy ? "Codex: thinking (\(state.confidence))" : "Codex: dormant (\(state.confidence))"
        case .workspaceRoot(let root):
            let label = shortLabel(forRoot: root, labelsByRoot: state.labelsByRoot)
            let busy = state.anyBusy && state.activeWorkspaceRoots.contains(root)
            return busy ? "\(label): thinking (\(state.confidence))" : "\(label): dormant (\(state.confidence))"
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

        let saved = state.savedWorkspaceRoots
        if !saved.isEmpty {
            for (idx, root) in saved.enumerated() {
                let base = shortLabel(forRoot: root, labelsByRoot: state.labelsByRoot)
                let isActive = state.anyBusy && state.activeWorkspaceRoots.contains(root)
                let title = isActive ? "\(base) (active)" : base

                let item = NSMenuItem(title: title, action: #selector(selectScope(_:)), keyEquivalent: "")
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
        menu.addItem(statusLineItem(state: state))
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Runlight", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func statusLineItem(state: PulseState) -> NSMenuItem {
        let title: String
        if !state.anyBusy {
            title = "Dormant (\(state.confidence))"
        } else if state.activeWorkspaceRoots.isEmpty {
            title = "Thinking (workspace unknown, \(state.confidence))"
        } else if state.activeWorkspaceRoots.count == 1 {
            let label = shortLabel(forRoot: state.activeWorkspaceRoots[0], labelsByRoot: state.labelsByRoot)
            title = "Thinking: \(label) (\(state.confidence))"
        } else {
            let labels = state.activeWorkspaceRoots
                .map { shortLabel(forRoot: $0, labelsByRoot: state.labelsByRoot) }
                .joined(separator: ", ")
            title = "Thinking: \(labels) (\(state.confidence))"
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

    private func clamp(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 3)) + "..."
    }

    private func readCodexState() -> (saved: [String], active: [String], labels: [String: String]) {
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
                for (k, v) in raw where v is String {
                    labels[k] = v as? String
                }
            }
            return (saved, active, labels)
        } catch {
            return ([], [], [:])
        }
    }

    private func stateFileFreshnessAgeSeconds() -> (exists: Bool, age: Double?) {
        let path = codexStatePath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else {
            return (FileManager.default.fileExists(atPath: path), nil)
        }
        let age = Date().timeIntervalSince(modified)
        return (true, age)
    }

    private func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    private func codexAccessibilityIndicatesThinking() -> Bool {
        guard let app = codexRunningApplicationForAccessibility() else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let text = accessibilityFlattenedText(from: appElement, maxNodes: 260).lowercased()

        // Keep this broad to survive moderate UI wording changes.
        let keywords = [
            "thinking",
            "running",
            "in progress",
            "working",
            "generating",
            "streaming",
            "applying",
            "executing"
        ]

        return keywords.contains(where: { text.contains($0) })
    }

    private func codexRunningApplicationForAccessibility() -> NSRunningApplication? {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            if let bundleID = app.bundleIdentifier, bundleID == "com.openai.codex" { return true }
            if let bundleURL = app.bundleURL?.path, bundleURL.contains("/Codex.app") { return true }
            return app.localizedName == "Codex"
        }

        // Prefer frontmost Codex window if multiple helpers are present.
        return candidates.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.processIdentifier > b.processIdentifier
        }.first
    }

    private func accessibilityFlattenedText(from root: AXUIElement, maxNodes: Int) -> String {
        var queue: [AXUIElement] = [root]
        var visited = 0
        var parts: [String] = []

        while !queue.isEmpty && visited < maxNodes {
            let node = queue.removeFirst()
            visited += 1

            if let s = axString(node, attribute: kAXTitleAttribute) { parts.append(s) }
            if let s = axString(node, attribute: kAXValueAttribute) { parts.append(s) }
            if let s = axString(node, attribute: kAXDescriptionAttribute) { parts.append(s) }
            if let s = axString(node, attribute: kAXHelpAttribute) { parts.append(s) }

            if let children = axChildren(node, attribute: kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }

        return parts.joined(separator: " ")
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let v = value else { return nil }

        if CFGetTypeID(v) == CFStringGetTypeID() {
            return (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let n = v as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    private func axChildren(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let v = value else { return nil }
        if let arr = v as? [AXUIElement] { return arr }
        if let arr = v as? [Any] {
            return arr.compactMap { item in
                let type = CFGetTypeID(item as CFTypeRef)
                return type == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
            }
        }
        return nil
    }

    private func codexPids() -> [Int] {
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
        guard !pids.isEmpty else { return 0 }
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
