import SwiftUI
import AppKit
import Foundation

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

    /// Ports to auto-detect, tried in order.
    private let defaultPorts = [8000, 8080, 8081, 11434]
    /// The port we last successfully connected to.
    private(set) var detectedURL: String?

    var effectiveURL: String {
        detectedURL ?? (serverURL.isEmpty ? "http://127.0.0.1:8000" : serverURL)
    }

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

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Try to reach one specific URL.
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
        } catch {
            return false
        }
    }

    func poll() async {
        // 1) If user configured a URL, try only that.
        if !serverURL.isEmpty {
            let ok = await tryURL(serverURL)
            if !ok { alive = false; detectedURL = nil }
            return
        }

        // 2) If we already detected a working URL, try it first (fast path).
        if let det = detectedURL {
            if await tryURL(det) { return }
            detectedURL = nil  // stale, re-scan
        }

        // 3) Auto-scan default ports.
        for port in defaultPorts {
            let candidate = "http://127.0.0.1:\(port)"
            if await tryURL(candidate) {
                detectedURL = candidate
                return
            }
        }

        alive = false
    }

    /// Parse timing line: "ds4: prefill: 250.11 t/s, generation: 21.47 t/s"
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

    deinit {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Log parser — auto-discovers the ds4-server log file

class DS4LogParser {
    private var task: Process?
    private var readHandle: FileHandle?
    private weak var status: DS4Status?
    private var recheckTimer: Timer?
    /// Known log paths to try, in priority order.
    private let candidatePaths: [String] = [
        "/tmp/ds4-server.log",
        "~/Projects/local-ai/ds4/logs/server.log",
    ]

    func start(status: DS4Status) {
        self.status = status
        tryFindAndTail()

        // Re-check every 30 s in case the server is restarted later.
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only re-scan if we aren't already tailing something.
            if self.task == nil { self.tryFindAndTail() }
        }
    }

    /// Find the first readable ds4-server log file and start tailing it.
    private func tryFindAndTail() {
        // 1) Try to discover from the live process via lsof
        if let procPath = discoverLogFromProcess() {
            startTailing(procPath)
            return
        }

        // 2) Fall back to candidate paths
        for raw in candidatePaths {
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              // Only use if modified in the last hour
              mtime.timeIntervalSinceNow > -3600 else { continue }
            startTailing(path)
            return
        }
    }

    /// Use lsof to find where the running ds4-server writes stderr.
    private func discoverLogFromProcess() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = [
            "-c", "ds4-serve",
            "-a", "-d", "2",   // stderr fd
            "-F", "n"          // print file node path
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = nil
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // lsof -F n outputs lines like "n/path/to/file"
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("n/") {
                    let path = String(trimmed.dropFirst())
                    if FileManager.default.fileExists(atPath: path),
                       FileManager.default.isWritableFile(atPath: path) == false || true {
                        return path
                    }
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

        do {
            try task?.run()
            print("ds4toolbar: tailing log \(path)")
        } catch {
            task = nil; readHandle = nil
        }
    }

    func stopTailing() {
        readHandle?.readabilityHandler = nil
        task?.terminate()
        task = nil
        readHandle = nil
    }

    func stop() {
        stopTailing()
        recheckTimer?.invalidate()
        recheckTimer = nil
    }

    deinit { stop() }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let status = DS4Status()
    let logParser = DS4LogParser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.start()
        logParser.start(status: status)
    }
}

// MARK: - Menu item rows

struct MenuItemRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).fontDesign(.monospaced)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
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
            Text("Auto-detects ds4-server on ports 8000, 8080, 8081, 11434.\nSet a custom URL to lock to a specific address.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.leading)

            Divider()

            HStack {
                Text("Custom URL:")
                TextField("(leave blank for auto-detect)", text: $url)
                    .textFieldStyle(.roundedBorder)
            }
            .onAppear { url = status.serverURL }

            HStack {
                Button("Cancel") { isPresented = false }
                Button("Save") {
                    status.serverURL = url
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 380)
        .fixedSize()
    }
}

// MARK: - Menu bar app

@main
struct DS4Toolbar: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettings = false

    var body: some Scene {
        let status = appDelegate.status

        return MenuBarExtra {
            Group {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DwarfStar 4").font(.headline)
                    Text("DeepSeek V4 Flash").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)

                Divider()

                ServerStatusRow(alive: status.alive)

                if status.alive {
                    MenuItemRow(label: "Model", value: status.modelName)
                    MenuItemRow(label: "Context", value: status.contextLabel)
                    MenuItemRow(label: "Endpoint", value: status.effectiveURL)

                    Divider()

                    Text("Performance").font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                    MenuItemRow(label: "Prefill", value: status.prefillLabel)
                    MenuItemRow(label: "Generation", value: status.genLabel)
                    if !status.kvCache.isEmpty {
                        MenuItemRow(label: "KV Cache", value: status.kvCache)
                    }

                    Divider()

                    if status.lastUpdate != .distantPast {
                        MenuItemRow(label: "Checked", value: "\(Int(-status.lastUpdate.timeIntervalSinceNow))s ago")
                    }
                }

                Divider()

                Button("Settings…") { showSettings = true }.keyboardShortcut(",")

                Divider()

                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(status: status, isPresented: $showSettings)
            }
        } label: {
            Label {
                Text("ds4")
            } icon: {
                Image(systemName: status.alive ? "cpu.fill" : "cpu")
                    .foregroundStyle(status.alive ? .green : .gray)
            }
        }
    }
}
