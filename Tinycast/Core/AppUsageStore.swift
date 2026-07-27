import AppKit

/// One rankable entry's Tinycast-launch frequency: keyed by `bundleID ?? id`, persisted as
/// Codable JSON so the launcher can promote the most-launched apps and commands to the top of
/// the palette. No system-wide activation tracking — only explicit launches through
/// `AppCore.launch(_:)` are recorded, so hotkey toggles and direct system-app activations
/// never count.
struct AppUsageRecord: Codable, Hashable, Sendable {
    var key: String
    var count: Int
    var lastUsed: Date
}

/// Tracks how often launcher entries are launched from inside Tinycast and splits the
/// launcher list into a small ranked prefix (the most-used applications and commands) plus
/// the remaining entries in their original order. Records are local-only, bounded, and
/// persisted atomically; the per-entry key (`bundleID ?? id`) is the only identifier stored.
///
/// Splitting is deterministic: ranked entries are ordered by count (desc), then last-used
/// (desc), then input order; favorites are supplied via `excluding` and never appear in the
/// ranked group. System settings are never ranked — they stay in `rest` in input order.
@MainActor
final class AppUsageStore: ObservableObject {
    /// Bounded record cap; oldest-beyond-cap are dropped by lowest count then oldest
    /// last-used so the on-disk file stays stable and small.
    private static let cap = 400
    /// Promote at most this many non-favorite `.application`/`.command` entries.
    private static let rankedLimit = 5

    private let fileURL: URL

    @Published private(set) var records: [String: AppUsageRecord] = [:]

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("app-usage.json")
        load()
    }

    /// Stable key for an entry: bundle id when present, else the entry's unique id.
    /// Matches the FavoritesStore key space (`app.bundleID ?? app.id`).
    func key(for app: AppEntry) -> String {
        app.bundleID ?? app.id
    }

    /// Records one Tinycast-initiated launch of `app`. Only `.application` and `.command`
    /// entries are rankable; system settings and any unrankable entry are ignored. Call this
    /// solely from the launcher launch path — never from hotkey toggles or system activations.
    func record(_ app: AppEntry) {
        guard app.kind == .application || app.kind == .command else { return }
        let k = key(for: app)
        let now = Date()
        var rec = records[k] ?? AppUsageRecord(key: k, count: 0, lastUsed: now)
        rec.count += 1
        rec.lastUsed = now
        records[k] = rec
        persist()
    }

    /// Splits `entries` into a ranked prefix (at most `rankedLimit` non-excluded
    /// `.application`/`.command` entries, ordered by count desc → last-used desc → input
    /// order) and `rest` containing every other entry exactly once, in original input order.
    /// `excludedKeys` (favorites) never appear in `ranked`; system settings always fall to
    /// `rest` regardless of usage.
    func split(
        _ entries: [AppEntry],
        excluding excludedKeys: Set<String> = []
    ) -> (ranked: [AppEntry], rest: [AppEntry]) {
        guard !entries.isEmpty else { return ([], []) }

        // Select rankable, non-excluded entries with a recorded count > 0.
        let candidates: [(offset: Int, entry: AppEntry, count: Int, lastUsed: Date)] = entries
            .enumerated()
            .compactMap { offset, app in
                guard app.kind == .application || app.kind == .command else { return nil }
                let k = key(for: app)
                guard !excludedKeys.contains(k) else { return nil }
                guard let rec = records[k], rec.count > 0 else { return nil }
                return (offset, app, rec.count, rec.lastUsed)
            }

        let ranked = candidates
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
                return a.offset < b.offset
            }
            .prefix(Self.rankedLimit)
            .map(\.entry)

        let rankedKeys = Set(ranked.map(key(for:)))
        // `rest` preserves original input order; drop only ranked entries, and never promote
        // an excluded-or-unranked entry into their place.
        let rest = entries.filter { rankedKeys.contains(key(for: $0)) == false }

        return (Array(ranked), rest)
    }

    /// Clears all in-memory records and removes the persisted file. The next `record` starts
    /// fresh.
    func reset() {
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        records.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Cheap legacy migration: the old format was [AppUsageRecord] keyed on `bundleID` with
        // optional weekday/hour `buckets`. Decode the union shape then drop the buckets — a
        // single stray activation never re-ranks anything under the new frequency-only model, so
        // the buckets carry no signal worth keeping.
        if let migrated = try? JSONDecoder().decode([LegacyRecord].self, from: data) {
            for r in migrated {
                if let u = r.upgraded { records[u.key] = u }
            }
        } else if let decoded = try? JSONDecoder().decode([AppUsageRecord].self, from: data) {
            for r in decoded { records[r.key] = r }
        }
    }

    /// Encodes a bounded, deterministic dense array (sorted by count desc then key asc) so the
    /// on-disk file is stable across writes and capped at `cap` records.
    private func persist() {
        var all = Array(records.values)
        all.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.key < $1.key
        }
        if all.count > Self.cap { all.removeLast(all.count - Self.cap) }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Union decode shape for the legacy routine-bucketed format; `buckets` is read then
    /// discarded by `upgraded`.
    private struct LegacyRecord: Codable {
        var bundleID: String?
        var key: String?
        var total: Int?
        var count: Int?
        var lastActivated: Date?
        var lastUsed: Date?
        var buckets: [[Int]]?

        var upgraded: AppUsageRecord? {
            guard let k = bundleID ?? key, !k.isEmpty else { return nil }
            return AppUsageRecord(
                key: k,
                count: max(total ?? 0, count ?? 0),
                lastUsed: lastUsed ?? lastActivated ?? Date()
            )
        }
    }
}
