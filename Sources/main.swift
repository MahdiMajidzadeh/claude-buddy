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
    /// The single number a percentage is measured against.
    func value(_ m: Metric) -> Int { m == .total ? total : input + output }
}

/// Which token figure the limit percentages are computed from.
enum Metric: String, CaseIterable {
    case realUsage
    case total
    var label: String { self == .realUsage ? "Input+Output" : "All tokens" }
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

    // User-defined limits (in millions of tokens) and which metric drives percentages.
    @Published var metric: Metric {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "metric") }
    }
    @Published var sessionLimitM: Double {
        didSet { UserDefaults.standard.set(sessionLimitM, forKey: "sessionLimitM") }
    }
    @Published var weeklyLimitM: Double {
        didSet { UserDefaults.standard.set(weeklyLimitM, forKey: "weeklyLimitM") }
    }

    private var timer: Timer?

    init() {
        let d = UserDefaults.standard
        metric = Metric(rawValue: d.string(forKey: "metric") ?? "") ?? .realUsage
        sessionLimitM = d.object(forKey: "sessionLimitM") as? Double ?? 1
        weeklyLimitM = d.object(forKey: "weeklyLimitM") as? Double ?? 5
        refresh()
        // Recompute every 60s; also keeps the reset countdown roughly current.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    var sessionLimit: Int { Int(sessionLimitM * 1_000_000) }
    var weeklyLimit: Int { Int(weeklyLimitM * 1_000_000) }

    /// Menu bar label: percent of the session limit (chosen metric). Falls back to a count.
    var menuLabel: String {
        guard sessionLimit > 0 else { return fmtTokens(session.value(metric)) }
        let pct = Int((Double(session.value(metric)) / Double(sessionLimit) * 100).rounded())
        return "\(pct)%"
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

/// One window (Session / Week) with its percent-of-limit, stacked bar, and per-category rows.
struct WindowView: View {
    let title: String
    let subtitle: String?
    let t: Tokens
    let limitTokens: Int
    let metric: Metric

    private let labels = ["Input", "Output", "Cache write", "Cache read"]
    private var values: [Int] { [t.input, t.output, t.cacheCreate, t.cacheRead] }
    private var frac: Double? {
        limitTokens > 0 ? min(1, Double(t.value(metric)) / Double(limitTokens)) : nil
    }
    private var color: Color {
        guard let f = frac else { return .secondary }
        return f >= 0.9 ? .red : (f >= 0.7 ? .orange : .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if let f = frac {
                    Text("\(Int((f * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(color)
                }
            }
            if let f = frac {
                ProgressView(value: f).tint(color)
                Text("\(fmtTokens(t.value(metric))) / \(fmtTokens(limitTokens)) tokens")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
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

/// Editable limits and the metric the percentages are based on.
struct SettingsSection: View {
    @EnvironmentObject var store: UsageStore
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Percent of").font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $store.metric) {
                        ForEach(Metric.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
                limitField("Session limit (5h)", value: $store.sessionLimitM)
                limitField("Weekly limit", value: $store.weeklyLimitM)
                Text("Limits in millions of tokens. Percent = chosen metric ÷ limit. These are your own targets — Anthropic doesn't publish exact seat limits.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.top, 4)
        } label: {
            Text("Settings").font(.system(size: 12, weight: .semibold))
        }
    }

    func limitField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 11))
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text("M").font(.system(size: 10)).foregroundStyle(.secondary)
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
                       t: store.session,
                       limitTokens: store.sessionLimit,
                       metric: store.metric)

            Divider()

            WindowView(title: "This week",
                       subtitle: "rolling 7 days",
                       t: store.week,
                       limitTokens: store.weeklyLimit,
                       metric: store.metric)

            HStack {
                Text("Today").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(fmtTokens(store.today.value(store.metric))) tokens")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }

            Text("Token counts from local transcripts. Percent is vs your own limits below — not your plan's % usage, which Anthropic computes server-side.")
                .font(.system(size: 9)).foregroundStyle(.secondary)

            Divider()

            SettingsSection()

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
