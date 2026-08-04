import Darwin
import Foundation

/// Every filesystem, stat and permission read. Not compiled by the harness — the decisions it defers to are the pure half.
enum UninstallScanner {
    struct SizeBudget: Sendable {
        /// Generous: an editor's support folder runs to ~90k entries, and stopping short would show "≥ 796 MB" for 1.9 GB.
        /// Roughly a second at 250k, off-main behind a progress state.
        var maxEntries = 250_000
        static let `default` = SizeBudget()
    }

    enum Failure: LocalizedError, Sendable {
        case refused

        var errorDescription: String? {
            switch self {
            case .refused:
                return "Tinycast can’t uninstall this app."
            }
        }
    }

    /// Runs off-main via `Task.detached`, like `AppIndex.refresh()`.
    nonisolated static func scan(
        target: UninstallTarget, otherAppNames: [String], otherBundleIDs: [String],
        isTargetRunning: Bool, roots: [UninstallSearchRoot] = UninstallSearchRoot.all,
        budget: SizeBudget = .default
    ) throws -> UninstallPlan {
        let home = NSHomeDirectory()
        let environment = UninstallEnvironment(
            home: home, hasFullDiskAccess: detectFullDiskAccess(home: home))
        guard
            let identity = UninstallIdentity.make(
                target: target, otherAppNames: otherAppNames, otherBundleIDs: otherBundleIDs,
                ownBundleID: Bundle.main.bundleIdentifier, ownBundleURL: Bundle.main.bundleURL)
        else { throw Failure.refused }

        let bundlePath = target.bundleURL.standardizedFileURL.path
        var candidates: [UninstallCandidate] = [
            candidate(
                path: bundlePath, evidence: .bundle, environment: environment, budget: budget,
                displayName: target.bundleURL.deletingPathExtension().lastPathComponent)
        ].compactMap { $0 }

        var seen = Set(candidates.map(\.path))
        for root in roots {
            try Task.checkCancellation()
            let rootPath = root.path(home: home)
            guard let names = childNames(of: rootPath) else { continue }
            // One stat per root, not per row.
            let parent = parentFacts(of: rootPath)
            for match in UninstallRules.matches(childNames: names, in: root, identity: identity) {
                let path = (rootPath + "/" + match.name as NSString).standardizingPath
                guard
                    UninstallRules.isAcceptableCandidate(
                        path: path, rootPath: rootPath, home: home, bundlePath: bundlePath),
                    seen.insert(path).inserted,
                    let candidate = candidate(
                        path: path, evidence: match.evidence, environment: environment,
                        budget: budget, parent: parent)
                else { continue }
                candidates.append(candidate)
            }
        }

        for directory in UninstallSearchRoot.binDirectories {
            try Task.checkCancellation()
            let rootPath = (directory as NSString).expandingTildeInPath
            guard let names = childNames(of: rootPath) else { continue }
            let parent = parentFacts(of: rootPath)
            for name in names {
                let path = (rootPath + "/" + name as NSString).standardizingPath
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                else { continue }
                // A relative link resolves against its own directory, not the cwd.
                let resolved =
                    target.hasPrefix("/")
                    ? target : (rootPath as NSString).appendingPathComponent(target)
                guard UninstallRules.isBundleSymlink(target: resolved, bundlePath: bundlePath),
                    seen.insert(path).inserted,
                    let candidate = candidate(
                        path: path, evidence: .binSymlink, environment: environment, budget: budget,
                        parent: parent)
                else { continue }
                candidates.append(candidate)
            }
        }

        // Bundle pinned first; the rest by path, which is the order the list shows.
        let leftovers = candidates.filter { $0.evidence != .bundle }.sorted { $0.path < $1.path }
        return UninstallPlan(
            target: target, candidates: candidates.filter { $0.evidence == .bundle } + leftovers,
            isTargetRunning: isTargetRunning)
    }

    // MARK: - Private

    private static func childNames(of directory: String) -> [String]? {
        // Not `.skipsHiddenFiles`: dot-named leftovers are the ones a user would never find.
        try? FileManager.default.contentsOfDirectory(atPath: directory)
    }

    private static func candidate(
        path: String, evidence: UninstallEvidence, environment: UninstallEnvironment,
        budget: SizeBudget, displayName: String? = nil, parent: ParentFacts? = nil
    ) -> UninstallCandidate? {
        guard let scanned = inspect(path, parent: parent) else { return nil }
        let protection = UninstallProtectionRules.classify(scanned.facts, environment: environment)
        guard protection != .missing else { return nil }
        // A symlink is trashed as the link, so it never costs more than its own bytes.
        let walkable = scanned.isDirectory && !scanned.facts.isSymbolicLink
        return UninstallCandidate(
            path: path,
            name: displayName ?? (path as NSString).lastPathComponent,
            locationLabel: UninstallRules.abbreviate(
                (path as NSString).deletingLastPathComponent, home: environment.home),
            evidence: evidence,
            isDirectory: scanned.isDirectory,
            size: walkable
                ? directorySize(of: path, budget: budget) : MeasuredSize(bytes: scanned.byteSize),
            protection: protection)
    }

    /// `lstat`, never `stat`: a symlink is judged as the link, not as whatever it points at.
    private static func inspect(_ path: String, parent: ParentFacts?)
        -> (facts: PathFacts, isDirectory: Bool, byteSize: Int64)?
    {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let parent = parent ?? parentFacts(of: (path as NSString).deletingLastPathComponent)
        let volumeIsReadOnly =
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly ?? false
        let facts = PathFacts(
            path: path,
            isSymbolicLink: (info.st_mode & S_IFMT) == S_IFLNK,
            volumeIsReadOnly: volumeIsReadOnly,
            isSystemRestricted: info.st_flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE) != 0,
            isUserImmutable: info.st_flags & UInt32(UF_IMMUTABLE) != 0,
            isOwnedByCurrentUser: info.st_uid == geteuid(),
            parentIsWritable: parent.isWritable,
            parentIsSticky: parent.isSticky)
        return (facts, (info.st_mode & S_IFMT) == S_IFDIR, Int64(info.st_blocks) * 512)
    }

    /// The permission that actually governs a trash, resolved once per root.
    private static func parentFacts(of directory: String) -> ParentFacts {
        var info = stat()
        let sticky = stat(directory, &info) == 0 && (info.st_mode & S_ISVTX) != 0
        return ParentFacts(
            isWritable: FileManager.default.isWritableFile(atPath: directory), isSticky: sticky)
    }

    private struct ParentFacts {
        let isWritable: Bool
        let isSticky: Bool
    }

    /// On-disk bytes, like Finder. The error handler keeps counting past an unreadable subtree instead of abandoning the row.
    private static func directorySize(of path: String, budget: SizeBudget) -> MeasuredSize {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [],
                errorHandler: { _, _ in true })
        else { return .zero }

        var size = MeasuredSize()
        var entries = 0
        for case let item as URL in enumerator {
            entries += 1
            if entries > budget.maxEntries {
                size.isLowerBound = true
                break
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            size.bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return size
    }

    /// Detected, never requested: TCC denies this read silently, no prompt. It can only under-report, which just leaves a row locked.
    private static func detectFullDiskAccess(home: String) -> Bool {
        let descriptor = open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
