import SwiftUI
import AppKit
import Foundation

// MARK: - DS4 Server Stats

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

class DS4Status: ObservableObject {
    @Published var alive = false
    @Published var modelName = "—"
    @Published var contextSize = 0
    @Published var prefillTps: Double = 0
    @Published var genTps: Double = 0
    @Published var kvCache = ""
    @Published var lastUpdate = Date.distantPast
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://127.0.0.1:8080" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }

    var contextLabel: String {
        contextSize >= 1_000_000
            ? String(format: "%.1fM", Double(contextSize) / 1_000_000)
            : contextSize >= 1_000
                ? String(format: "%.0fK", Double(contextSize) / 1_000)
                : "\(contextSize)"
    }

    var prefillLabel: String {
        prefillTps > 0 ? String(format: "%.1f t/s", prefillTps) : "—"
    }

    var genLabel: String {
        genTps > 0 ? String(format: "%.1f t/s", genTps) : "—"
    }

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

    @MainActor
    func poll() async {
        guard let base = URL(string: serverURL) else { return }
        guard let url = URL(string: "/v1/models", relativeTo: base) else { return }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                alive = false; return
            }

            let dec = JSONDecoder()
            if let list = try? dec.decode(DS4ModelsResponse.self, from: data),
               let m = list.data?.first {
                alive = true
                modelName = m.name
                contextSize = m.contextLength
                lastUpdate = Date()
            } else if let single = try? dec.decode(DS4ServerInfo.self, from: data) {
                alive = true
                modelName = single.name
                contextSize = single.contextLength
                lastUpdate = Date()
            }
        } catch {
            alive = false
        }
    }

    /// Parses a timing line like:
    /// "ds4: prefill: 250.11 t/s, generation: 21.47 t/s"
    func parseTiming(_ line: String) {
        guard let prefillRange = line.range(of: "prefill: "),
              let genRange = line.range(of: "generation: ") else { return }

        let afterPrefill = line[prefillRange.upperBound...]
        if let tpsEnd = afterPrefill.firstIndex(of: " ") {
            let val = String(afterPrefill[..<tpsEnd])
            prefillTps = Double(val) ?? 0
        }

        let afterGen = line[genRange.upperBound...]
        let suffix = afterGen.trimmingCharacters(in: .whitespaces)
        let endIdx = suffix.firstIndex { $0 == " " || $0 == "\n" } ?? suffix.endIndex
        let val = String(suffix[..<endIdx])
        genTps = Double(val) ?? 0
    }
}

// MARK: - Log Parser (tails ds4-server stderr log)

class DS4LogParser {
    private var task: Process?
    private var readHandle: FileHandle?

    func start(status: DS4Status) {
        let logFile = "/tmp/ds4-server.log"
        guard FileManager.default.fileExists(atPath: logFile) else { return }

        task = Process()
        task?.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task?.arguments = ["-f", "-n", "0", logFile]

        let pipe = Pipe()
        task?.standardOutput = pipe
        readHandle = pipe.fileHandleForReading

        readHandle?.readabilityHandler = { [weak status] handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            Task { @MainActor [weak status] in
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    status?.parseTiming(line)
                }
            }
        }

        do {
            try task?.run()
        } catch {
            // Can't watch logs, silently ignore
        }
    }

    func stop() {
        readHandle?.readabilityHandler = nil
        task?.terminate()
        task = nil
        readHandle = nil
    }

    deinit { stop() }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let status = DS4Status()
    let logParser = DS4LogParser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.start()
        logParser.start(status: status)
    }
}

// MARK: - Reusable View Components

struct MenuItemRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .fontDesign(.monospaced)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

struct ServerStatusRow: View {
    let alive: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(alive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(alive ? "Running" : "Offline")
                .foregroundColor(alive ? .primary : .secondary)
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
            Text("DwarfStar 4 Toolbar")
                .font(.headline)
            Text("Monitor your local DS4 inference server")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            HStack {
                Text("Server URL:")
                TextField("http://127.0.0.1:8080", text: $url)
                    .textFieldStyle(.roundedBorder)
            }
            .onAppear { url = status.serverURL }

            Text("Tip: Pipe ds4-server stderr to /tmp/ds4-server.log for live stats:\n  ds4-server 2>/tmp/ds4-server.log &")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

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

// MARK: - Menu Bar App

@main
struct DS4Toolbar: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettings = false

    var body: some Scene {
        // Capture status in a local let so it's in scope for the label builder
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
                    MenuItemRow(label: "Endpoint", value: status.serverURL)

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

                Button("Settings…") { showSettings = true }
                    .keyboardShortcut(",")

                Divider()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
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
