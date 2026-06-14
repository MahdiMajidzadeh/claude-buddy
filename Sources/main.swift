import SwiftUI
import ServiceManagement

// MARK: - Models

/// A bucket of token counts.
struct Tokens: Equatable {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    var total: Int { input + output + cacheCreate + cacheRead }
    static func + (a: Tokens, b: Tokens) -> Tokens {
        Tokens(input: a.input + b.input,
               output: a.output + b.output,
               cacheCreate: a.cacheCreate + b.cacheCreate,
               cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// One usage record parsed from a transcript line.
private struct Entry {
    let date: Date
    let id: String?
    let tokens: Tokens
}

// MARK: - JSONL decoding (minimal, only the fields we need)

private struct Line: Decodable {
    let timestamp: String?
    let type: String?
    let message: Msg?
    struct Msg: Decodable {
        let id: String?
        let usage: Usage?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
}

// MARK: - Admin API (official org usage report)

/// Minimal decoding of GET /v1/organizations/usage_report/messages.
private struct OrgReport: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable {
        let starting_at: String
        let results: [Result]
    }
    struct Result: Decodable {
        let uncached_input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation: CacheCreation?
    }
    struct CacheCreation: Decodable {
        let ephemeral_1h_input_tokens: Int?
        let ephemeral_5m_input_tokens: Int?
    }
}

struct OrgError: Error { let message: String; init(_ m: String) { message = m } }

/// Stores the admin key in the macOS Keychain (never in plaintext on disk).
enum Keychain {
    private static let service = "local.claude.usage.menubar"
    private static let account = "anthropic-admin-key"
    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func save(_ value: String) {
        SecItemDelete(base() as CFDictionary)
        var add = base()
        add[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load() -> String? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete() { SecItemDelete(base() as CFDictionary) }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    // Current 5-hour session block
    @Published var session = Tokens()
    @Published var blockEnd: Date? = nil
    // Rolling windows
    @Published var today = Tokens()
    @Published var week = Tokens()
    @Published var lastUpdated = Date()
    @Published var isRefreshing = false

    // Official Admin API org usage (developer platform — not the seat plan %).
    @Published var orgConfigured = false
    @Published var orgWeek = Tokens()
    @Published var orgToday = Tokens()
    @Published var orgStatus = "Not configured"

    private var timer: Timer?

    init() {
        orgConfigured = Keychain.load() != nil
        refresh()
        if orgConfigured { refreshOrg() }
        // Recompute every 60s; also keeps the reset countdown roughly current.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Short label shown in the menu bar: real consumption (input + output) this 5h window.
    var menuLabel: String {
        fmtTokens(session.input + session.output)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) {
            let result = UsageStore.scan(now: Date())
            await MainActor.run {
                self.session = result.session
                self.blockEnd = result.blockEnd
                self.today = result.today
                self.week = result.week
                self.lastUpdated = Date()
                self.isRefreshing = false
            }
        }
    }

    // MARK: Admin API

    func saveOrgKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.save(trimmed)
        orgConfigured = true
        orgStatus = "Loading…"
        refreshOrg()
    }

    func clearOrgKey() {
        Keychain.delete()
        orgConfigured = false
        orgWeek = Tokens(); orgToday = Tokens()
        orgStatus = "Not configured"
    }

    func refreshOrg() {
        guard let key = Keychain.load() else { orgStatus = "Not configured"; return }
        orgStatus = "Loading…"
        Task {
            do {
                let (week, today) = try await UsageStore.fetchOrg(key: key, now: Date())
                self.orgWeek = week
                self.orgToday = today
                self.orgStatus = "Updated \(Date().formatted(date: .omitted, time: .standard))"
            } catch let e as OrgError {
                self.orgStatus = e.message
            } catch {
                self.orgStatus = "Network error"
            }
        }
    }

    nonisolated private static func fetchOrg(key: String, now: Date) async throws -> (Tokens, Tokens) {
        var comps = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
        let iso = ISO8601DateFormatter()
        let start = Calendar.current.startOfDay(for: now.addingTimeInterval(-6 * 24 * 3600))
        comps.queryItems = [
            URLQueryItem(name: "starting_at", value: iso.string(from: start)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "7"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OrgError("No response") }
        switch http.statusCode {
        case 200: break
        case 401: throw OrgError("Auth failed — check admin key")
        case 403: throw OrgError("Key lacks admin permission")
        default: throw OrgError("HTTP \(http.statusCode)")
        }

        let report = try JSONDecoder().decode(OrgReport.self, from: data)
        let todayStart = Calendar.current.startOfDay(for: now)
        var week = Tokens(); var today = Tokens()
        for bucket in report.data {
            var bt = Tokens()
            for r in bucket.results {
                bt = bt + Tokens(input: r.uncached_input_tokens ?? 0,
                                 output: r.output_tokens ?? 0,
                                 cacheCreate: (r.cache_creation?.ephemeral_1h_input_tokens ?? 0)
                                            + (r.cache_creation?.ephemeral_5m_input_tokens ?? 0),
                                 cacheRead: r.cache_read_input_tokens ?? 0)
            }
            week = week + bt
            if let s = iso.date(from: bucket.starting_at), s >= todayStart { today = today + bt }
        }
        return (week, today)
    }

    // MARK: Scanning (runs off the main actor)

    private struct ScanResult {
        var session = Tokens()
        var blockEnd: Date? = nil
        var today = Tokens()
        var week = Tokens()
    }

    nonisolated private static func scan(now: Date) -> ScanResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var out = ScanResult()

        let cutoff = now.addingTimeInterval(-8 * 24 * 3600) // only files touched in last 8 days
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return out }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var entries: [Entry] = []
        var seen = Set<String>()
        let dec = JSONDecoder()

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < cutoff { continue }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = raw.data(using: .utf8),
                      let line = try? dec.decode(Line.self, from: lineData),
                      line.type == "assistant",
                      let u = line.message?.usage,
                      let ts = line.timestamp else { continue }
                guard let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts) else { continue }

                // Dedup repeated log lines by message id.
                if let id = line.message?.id {
                    if seen.contains(id) { continue }
                    seen.insert(id)
                }
                let tok = Tokens(input: u.input_tokens ?? 0,
                                 output: u.output_tokens ?? 0,
                                 cacheCreate: u.cache_creation_input_tokens ?? 0,
                                 cacheRead: u.cache_read_input_tokens ?? 0)
                entries.append(Entry(date: date, id: line.message?.id, tokens: tok))
            }
        }

        entries.sort { $0.date < $1.date }

        // Rolling windows.
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        for e in entries {
            if e.date >= startOfDay { out.today = out.today + e.tokens }
            if e.date >= weekAgo { out.week = out.week + e.tokens }
        }

        // 5-hour session blocks (mirrors how Claude's usage resets).
        let blockDur: TimeInterval = 5 * 3600
        var blockStart: Date? = nil
        var blockEnd = Date.distantPast
        var lastDate = Date.distantPast
        var blockTok = Tokens()
        var blocks: [(start: Date, end: Date, tok: Tokens)] = []

        func floorHour(_ d: Date) -> Date {
            let c = cal.dateComponents([.year, .month, .day, .hour], from: d)
            return cal.date(from: c) ?? d
        }

        for e in entries {
            if blockStart == nil {
                blockStart = floorHour(e.date)
                blockEnd = blockStart!.addingTimeInterval(blockDur)
                blockTok = Tokens()
            } else if e.date >= blockEnd || e.date.timeIntervalSince(lastDate) > blockDur {
                blocks.append((blockStart!, blockEnd, blockTok))
                blockStart = floorHour(e.date)
                blockEnd = blockStart!.addingTimeInterval(blockDur)
                blockTok = Tokens()
            }
            blockTok = blockTok + e.tokens
            lastDate = e.date
        }
        if let s = blockStart { blocks.append((s, blockEnd, blockTok)) }

        // Active block = one whose [start, end) contains now.
        if let active = blocks.last, active.start <= now, now < active.end {
            out.session = active.tok
            out.blockEnd = active.end
        } else {
            out.session = Tokens()   // window has reset since last activity
            out.blockEnd = nil
        }
        return out
    }
}

// MARK: - Formatting helpers

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1_000_000 { return String(format: "%.2fM", d / 1_000_000) }
    if d >= 1_000 { return String(format: "%.0fk", d / 1_000) }
    return "\(n)"
}

func fmtCountdown(_ end: Date) -> String {
    let s = max(0, Int(end.timeIntervalSinceNow))
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
}

// MARK: - Views

// Fixed colors per token category, reused by the stacked bar and the legend rows.
private let catColors: [Color] = [.blue, .green, .orange, Color(white: 0.55)]

/// A proportional stacked bar showing how a window's tokens split across the 4 categories.
struct StackedBar: View {
    let t: Tokens
    private var parts: [Int] { [t.input, t.output, t.cacheCreate, t.cacheRead] }

    var body: some View {
        GeometryReader { geo in
            let total = max(1, t.total)
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, v in
                    catColors[i].frame(width: geo.size.width * CGFloat(v) / CGFloat(total))
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
    }
}

/// One window (Session / Week) with its stacked bar and per-category rows. No combined total.
struct WindowView: View {
    let title: String
    let subtitle: String?
    let t: Tokens

    private let labels = ["Input", "Output", "Cache write", "Cache read"]
    private var values: [Int] { [t.input, t.output, t.cacheCreate, t.cacheRead] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            StackedBar(t: t)
            VStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle().fill(catColors[i]).frame(width: 7, height: 7)
                        Text(labels[i]).font(.system(size: 11))
                        Spacer()
                        Text(fmtTokens(values[i]))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Official org usage via the Admin API. Separate from local token tracking.
struct OrgSection: View {
    @EnvironmentObject var store: UsageStore
    @State private var keyInput = ""
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if store.orgConfigured {
                    Text(store.orgStatus).font(.system(size: 9)).foregroundStyle(.secondary)
                    WindowView(title: "Org — this week", subtitle: "API platform", t: store.orgWeek)
                    WindowView(title: "Org — today", subtitle: nil, t: store.orgToday)
                    HStack {
                        Button("Refresh") { store.refreshOrg() }
                            .buttonStyle(.borderless).font(.system(size: 11))
                        Spacer()
                        Button("Remove key") { store.clearOrgKey() }
                            .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.red)
                    }
                } else {
                    Text("Paste an Admin API key (sk-ant-admin…). Stored in your macOS Keychain. Reports developer-platform org usage — not your seat's plan %.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    SecureField("sk-ant-admin…", text: $keyInput)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button("Save key") { store.saveOrgKey(keyInput); keyInput = "" }
                        .font(.system(size: 11))
                }
            }.padding(.top, 4)
        } label: {
            Text("Org usage (Admin API)").font(.system(size: 12, weight: .semibold))
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: UsageStore
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text("Claude Usage").font(.system(size: 13, weight: .bold))
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).help("Refresh now")
            }

            WindowView(title: "Session (5h window)",
                       subtitle: store.blockEnd.map(fmtCountdown) ?? "idle — reset",
                       t: store.session)

            Divider()

            WindowView(title: "This week",
                       subtitle: "rolling 7 days",
                       t: store.week)

            HStack {
                Text("Today").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(fmtTokens(store.today.input + store.today.output)) in+out")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }

            Text("Token counts from local transcripts. Not the same as your plan's % usage, which Anthropic computes server-side.")
                .font(.system(size: 9)).foregroundStyle(.secondary)

            Divider()

            OrgSection()

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Revert the toggle if the system rejected the change.
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

            HStack {
                Text("Updated \(store.lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

// MARK: - App

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()
    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            // SwiftUI renders the SF Symbol + percent text in the menu bar.
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text(store.menuLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
