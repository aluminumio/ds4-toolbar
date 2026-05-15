import SwiftUI
import AppKit
import Foundation
import Combine

// MARK: - DS4 API types

struct DS4ServerInfo: Codable {
    let id: String
    let name: String
    let contextLength: Int
    enum CodingKeys: String, CodingKey {
        case id, name
        case contextLength = "context_length"
    }
}

struct DS4ModelsResponse: Codable {
    let data: [DS4ServerInfo]?
}

// MARK: - Server status model

@MainActor
class DS4Status: ObservableObject {
    @Published var alive = false
    @Published var modelName = "—"
    @Published var contextSize = 0
    @Published var prefillTps: Double = 0
    @Published var genTps: Double = 0
    @Published var kvCache = ""
    @Published var lastUpdate = Date.distantPast
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "" {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            if serverURL.isEmpty { detectedURL = nil }
        }
    }

    private let defaultPorts = [8000, 8080, 8081, 11434]
    private(set) var detectedURL: String?

    var effectiveURL: String { detectedURL ?? (serverURL.isEmpty ? "http://127.0.0.1:8000" : serverURL) }

    var contextLabel: String {
        contextSize >= 1_000_000
            ? String(format: "%.1fM", Double(contextSize) / 1_000_000)
            : contextSize >= 1_000
                ? String(format: "%.0fK", Double(contextSize) / 1_000)
                : "\(contextSize)"
    }

    var prefillLabel: String { prefillTps > 0 ? String(format: "%.1f t/s", prefillTps) : "—" }
    var genLabel: String     { genTps > 0 ? String(format: "%.1f t/s", genTps) : "—" }

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private func tryURL(_ urlString: String) async -> Bool {
        guard let base = URL(string: urlString),
              let url = URL(string: "/v1/models", relativeTo: base) else { return false }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let dec = JSONDecoder()
            if let list = try? dec.decode(DS4ModelsResponse.self, from: data),
               let m = list.data?.first {
                alive = true; modelName = m.name; contextSize = m.contextLength; lastUpdate = Date()
                return true
            } else if let single = try? dec.decode(DS4ServerInfo.self, from: data) {
                alive = true; modelName = single.name; contextSize = single.contextLength; lastUpdate = Date()
                return true
            }
            return false
        } catch { return false }
    }

    func poll() async {
        if !serverURL.isEmpty {
            let ok = await tryURL(serverURL)
            if !ok { alive = false; detectedURL = nil }
            return
        }
        if let det = detectedURL {
            if await tryURL(det) { return }
            detectedURL = nil
        }
        for port in defaultPorts {
            let candidate = "http://127.0.0.1:\(port)"
            if await tryURL(candidate) { detectedURL = candidate; return }
        }
        alive = false
    }

    func parseTiming(_ line: String) {
        guard let prefillRange = line.range(of: "prefill: "),
              let genRange = line.range(of: "generation: ") else { return }
        let afterPrefill = line[prefillRange.upperBound...]
        if let tpsEnd = afterPrefill.firstIndex(of: " ") {
            prefillTps = Double(String(afterPrefill[..<tpsEnd])) ?? 0
        }
        let afterGen = line[genRange.upperBound...]
        let suffix = afterGen.trimmingCharacters(in: .whitespaces)
        let endIdx = suffix.firstIndex { $0 == " " || $0 == "\n" } ?? suffix.endIndex
        genTps = Double(String(suffix[..<endIdx])) ?? 0
    }
}

// MARK: - Log parser

class DS4LogParser {
    private var task: Process?
    private var readHandle: FileHandle?
    private weak var status: DS4Status?
    private var recheckTimer: Timer?

    func start(status: DS4Status) {
        self.status = status
        tryFindAndTail()
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.task == nil else { return }
            self.tryFindAndTail()
        }
    }

    private func tryFindAndTail() {
        if let procPath = discoverLogFromProcess() { startTailing(procPath); return }
        let candidates = ["/tmp/ds4-server.log", "~/Projects/local-ai/ds4/logs/server.log"]
        for raw in candidates {
            let path = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { startTailing(path); return }
        }
    }

    private func discoverLogFromProcess() -> String? {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        t.arguments = ["-c", "ds4-serve", "-a", "-d", "2", "-F", "n"]
        let p = Pipe()
        t.standardOutput = p
        do {
            try t.run(); t.waitUntilExit()
            let output = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("n/") {
                    let path = String(trimmed.dropFirst())
                    if FileManager.default.fileExists(atPath: path) { return path }
                }
            }
        } catch {}
        return nil
    }

    private func startTailing(_ path: String) {
        stopTailing()
        task = Process()
        task?.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task?.arguments = ["-f", "-n", "0", path]
        let pipe = Pipe()
        task?.standardOutput = pipe
        readHandle = pipe.fileHandleForReading
        readHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            Task { @MainActor [weak self] in
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    self?.status?.parseTiming(line)
                }
            }
        }
        do { try task?.run() } catch { task = nil; readHandle = nil }
    }

    func stopTailing() { readHandle?.readabilityHandler = nil; task?.terminate(); task = nil; readHandle = nil }
    func stop() { stopTailing(); recheckTimer?.invalidate(); recheckTimer = nil }
    deinit { stop() }
}

// MARK: - Menu item rows (reusable)

struct MenuItemRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).fontDesign(.monospaced)
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
    }
}

struct ServerStatusRow: View {
    let alive: Bool
    var body: some View {
        HStack {
            Circle().fill(alive ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(alive ? "Running" : "Offline").foregroundColor(alive ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var status: DS4Status
    @Binding var isPresented: Bool
    @State private var url: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("DwarfStar 4 Toolbar").font(.headline)
            Text("Auto-detects ds4-server on ports 8000, 8080, 8081, 11434.\nLeave blank for auto-detect.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Divider()
            HStack {
                Text("URL:")
                TextField("(auto-detect)", text: $url).textFieldStyle(.roundedBorder)
            }
            .onAppear { url = status.serverURL }
            HStack {
                Button("Cancel") { isPresented = false }
                Button("Save") { status.serverURL = url; isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 360)
        .fixedSize()
    }
}

// MARK: - Menu content (SwiftUI, hosted in NSPopover)

struct MenuContentView: View {
    @ObservedObject var status: DS4Status
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DwarfStar 4").font(.headline)
                Text("DeepSeek V4 Flash").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()
            ServerStatusRow(alive: status.alive)

            if status.alive {
                MenuItemRow(label: "Model", value: status.modelName)
                MenuItemRow(label: "Context", value: status.contextLabel)
                MenuItemRow(label: "Endpoint", value: status.effectiveURL)

                Divider()
                Text("Performance").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 4)
                MenuItemRow(label: "Prefill", value: status.prefillLabel)
                MenuItemRow(label: "Generation", value: status.genLabel)
                if !status.kvCache.isEmpty { MenuItemRow(label: "KV Cache", value: status.kvCache) }

                Divider()
                if status.lastUpdate != .distantPast {
                    MenuItemRow(label: "Checked", value: "\(Int(-status.lastUpdate.timeIntervalSinceNow))s ago")
                }
            }

            Divider()
            Button(action: { showSettings = true }) { Text("Settings…") }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 4)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 4)
        }
        .frame(width: 280)
        .sheet(isPresented: $showSettings) {
            SettingsView(status: status, isPresented: $showSettings)
        }
    }
}

// MARK: - App Delegate (AppKit status bar)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let status = DS4Status()
    let logParser = DS4LogParser()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "DS4")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.behavior = .transient

        // React to status.alive changes → update icon
        status.$alive.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshIcon()
            }
        }.store(in: &cancellables)

        status.start()
        logParser.start(status: status)
    }

    @MainActor private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let name = status.alive ? "cpu.fill" : "cpu"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "DS4")
        button.contentTintColor = status.alive ? .systemGreen : .secondaryLabelColor
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let menuView = MenuContentView(status: status)
            popover.contentViewController = NSHostingController(rootView: menuView)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let w = popover.contentViewController?.view.window { w.makeKey() }
        }
    }
}

// MARK: - App entry (placeholder scene, AppKit handles the bar)

@main
struct DS4Toolbar: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
