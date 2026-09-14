import Foundation

/// One learned launcher choice, keyed by the whole query the user submitted, never a prefix of it.
/// A table written when this field held one row per prefix cannot decode here — that is the reset.
struct LauncherRankingRecord: Codable, Hashable, Sendable {
    let itemKey: String
    let submittedQuery: String
    var count: Int
    var lastUsed: Date
}

/// Learns which result a query leads to, as bounded on-device frecency data.
@MainActor
@Observable
final class LauncherRankingStore {
    private static let cap = 1_000
    /// Bounded, so `SearchRelevance.protectionFloor` stays out of reach however deep a habit runs.
    nonisolated static let maximumUsage = SearchRelevance.usageCeiling - 1

    private let fileURL: URL
    private let now: () -> Date

    private(set) var records: [LauncherRankingRecord]
    /// Part of `AppIndex`'s cache key, invalidating a result after a visit or a reset.
    private(set) var revision = 0

    /// The in-flight persist, awaited by the next one so a burst can't land out of order.
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.now = now

        if let data = try? Data(contentsOf: self.fileURL),
            let decoded = try? JSONDecoder().decode([LauncherRankingRecord].self, from: data)
        {
            records = decoded.filter {
                !$0.itemKey.isEmpty && $0.count > 0
            }
        } else {
            records = []
        }
    }

    var isEmpty: Bool { records.isEmpty }

    /// Awaits the pending persist. The launcher never needs it; reading the file back does.
    func flush() async {
        await writeTask?.value
    }

    /// Records every interactive launch overall and, when queried, under the submitted query.
    /// Search ranking expands submitted queries across prefixes; recommendations use the overall row.
    func record(itemKey: String, query: String) {
        guard !itemKey.isEmpty else { return }
        let normalized = Self.normalize(query)
        let timestamp = now()
        var targets = [""]
        if !normalized.isEmpty, normalized.count <= Self.queryLimit {
            targets.append(normalized)
        }

        for target in targets {
            if let index = records.firstIndex(where: {
                $0.itemKey == itemKey && $0.submittedQuery == target
            }) {
                records[index].count += 1
                records[index].lastUsed = timestamp
            } else {
                records.append(
                    LauncherRankingRecord(
                        itemKey: itemKey, submittedQuery: target, count: 1, lastUsed: timestamp))
            }
        }

        if records.count > Self.cap {
            records.sort {
                $0.count != $1.count ? $0.count > $1.count : $0.lastUsed > $1.lastUsed
            }
            records.removeLast(records.count - Self.cap)
        }
        didMutate()
    }

    /// Returns at most `limit` recommended keys ordered by overall launch frecency with deterministic source-order tie-breaking.
    func recommendedKeys(
        from candidateKeys: [String],
        excluding excludedKeys: Set<String> = [],
        limit: Int = 5
    ) -> [String] {
        guard limit > 0, !candidateKeys.isEmpty else { return [] }

        var totals: [String: (count: Int, lastUsed: Date)] = [:]
        for record in records where record.submittedQuery.isEmpty {
            let running = totals[record.itemKey]
            totals[record.itemKey] = (
                (running?.count ?? 0) + record.count,
                max(running?.lastUsed ?? .distantPast, record.lastUsed)
            )
        }
        guard !totals.isEmpty else { return [] }
        let bucket = totals.values.reduce(0) { $0 + $1.count }
        let timestamp = now()

        var seen = Set<String>()
        var scored: [(key: String, usage: Int, index: Int)] = []
        scored.reserveCapacity(min(candidateKeys.count, limit))
        for (index, key) in candidateKeys.enumerated() {
            guard !excludedKeys.contains(key), seen.insert(key).inserted,
                let total = totals[key]
            else { continue }
            let score = Self.usage(
                count: total.count, lastUsed: total.lastUsed,
                share: Double(total.count) / Double(bucket), at: timestamp)
            if score > 0 { scored.append((key: key, usage: score, index: index)) }
        }

        scored.sort { a, b in
            a.usage != b.usage ? a.usage > b.usage : a.index < b.index
        }
        return Array(scored.prefix(limit).map(\.key))
    }

    /// What the user has taught this query; the fold and the clock read happen once, not per row.
    func usage(query: String) -> [String: Int] {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return [:] }
        var totals: [String: (count: Int, lastUsed: Date)] = [:]
        for record in records where record.submittedQuery.hasPrefix(query) {
            let running = totals[record.itemKey]
            totals[record.itemKey] = (
                (running?.count ?? 0) + record.count,
                max(running?.lastUsed ?? .distantPast, record.lastUsed)
            )
        }
        guard !totals.isEmpty else { return [:] }
        let bucket = totals.values.reduce(0) { $0 + $1.count }
        let timestamp = now()
        return totals.mapValues {
            Self.usage(
                count: $0.count, lastUsed: $0.lastUsed, share: Double($0.count) / Double(bucket),
                at: timestamp)
        }
    }

    /// Frequency never flattens, recency decays, and confidence falls as a query's picks spread.
    nonisolated static func usage(count: Int, lastUsed: Date, share: Double, at timestamp: Date) -> Int {
        let ageInDays = max(0, timestamp.timeIntervalSince(lastUsed)) / 86_400
        let frequency = 2_000 * (1 - pow(Double(count) + 1, -0.30))
        let recency = 700 * exp(-ageInDays / 14)
        let confidence = 300 * share * min(1, Double(count) / 3)
        return min(maximumUsage, Int((frequency + recency + confidence).rounded()))
    }

    func hasRanking(for itemKey: String) -> Bool {
        records.contains { $0.itemKey == itemKey }
    }

    func reset(itemKey: String) {
        let oldCount = records.count
        records.removeAll { $0.itemKey == itemKey }
        guard records.count != oldCount else { return }
        didMutate()
    }

    func resetAll() {
        guard !records.isEmpty else { return }
        records = []
        didMutate()
    }

    /// Replaces the table wholesale from a backup; the same filter and cap the initialiser applies.
    func replace(_ imported: [LauncherRankingRecord]) {
        records = Array(
            imported
                .filter { !$0.itemKey.isEmpty && $0.count > 0 }
                .prefix(Self.cap))
        didMutate()
    }

    /// The launcher's own fold, so a query matches and is learned under one key.
    nonisolated static func normalize(_ query: String) -> String {
        FuzzyMatch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Caps pasted input, so one visit cannot evict the bounded table with a novel key.
    private static let queryLimit = 64

    private func didMutate() {
        revision &+= 1
        // Off-main: this lands on ↵, in front of the launch. Chained, so writes stay ordered.
        let snapshot = records
        let fileURL = fileURL
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Application Support, not Caches: relearning a ranking takes the user weeks of use.
    private static func defaultFileURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("launcher-ranking.json")
    }
}
