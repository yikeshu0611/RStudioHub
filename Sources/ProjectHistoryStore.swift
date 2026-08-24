import Foundation

struct ProjectHistoryEntry: Codable, Equatable {
    var name: String
    var path: String?
    var lastOpenedAt: Date
}

final class ProjectHistoryStore {
    static let shared = ProjectHistoryStore()

    private let queue = DispatchQueue(label: "com.zhangjing.RStudioHub.ProjectHistory")
    private let fileURL: URL
    private let maxEntries = 40

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RStudioHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("project-history.json")
    }

    /// Hub history merged with RStudio MRU paths; only entries with a real .Rproj path.
    func allEntries() -> [ProjectHistoryEntry] {
        queue.sync {
            migratePathsLocked()
            var byPath: [String: ProjectHistoryEntry] = [:]

            for entry in loadEntries() {
                guard let path = resolvedPath(for: entry) else { continue }
                byPath[path] = ProjectHistoryEntry(
                    name: entry.name.isEmpty ? RStudioRecentProjects.displayName(for: path) : entry.name,
                    path: path,
                    lastOpenedAt: entry.lastOpenedAt
                )
            }

            for mru in RStudioRecentProjects.entries() {
                guard let path = mru.path else { continue }
                if var existing = byPath[path] {
                    if existing.name.isEmpty || existing.name.hasPrefix("RStudio") {
                        existing.name = mru.name
                    }
                    byPath[path] = existing
                } else {
                    byPath[path] = mru
                }
            }

            return HubNameSort.sorted(Array(byPath.values)) { $0.name }
        }
    }

    func record(name: String, path: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isGenericTitle(trimmedName) else { return }

        let resolved = normalizeExistingPath(path)
            ?? RStudioRecentProjects.resolvePath(forName: trimmedName)

        queue.async {
            var entries = self.loadEntries()
            let key = self.dedupeKey(name: trimmedName, path: resolved)
            entries.removeAll { self.dedupeKey(name: $0.name, path: $0.path) == key }
            if let resolved {
                entries.removeAll { $0.path == resolved }
            }
            entries.insert(
                ProjectHistoryEntry(name: trimmedName, path: resolved, lastOpenedAt: Date()),
                at: 0
            )
            if entries.count > self.maxEntries {
                entries = Array(entries.prefix(self.maxEntries))
            }
            self.saveEntries(entries)
            ActivityLogger.shared.log("project.record name=\(trimmedName) path=\(resolved ?? "nil")")
        }
    }

    func record(from instance: RStudioInstance) {
        guard let name = instance.projectName else { return }
        let path = Self.extractPath(from: instance.title)
            ?? RStudioRecentProjects.resolvePath(forName: name)
        record(name: name, path: path)
    }

    func resolveOpenPath(for entry: ProjectHistoryEntry) -> String? {
        if let path = normalizeExistingPath(entry.path) {
            return path
        }
        return RStudioRecentProjects.resolvePath(forName: entry.name)
    }

    static func extractPath(from title: String) -> String? {
        let cleaned = title
            .replacingOccurrences(of: " - RStudio", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix(".Rproj") {
            let expanded = cleaned.hasPrefix("~/")
                ? FileManager.default.homeDirectoryForCurrentUser.path + String(cleaned.dropFirst(1))
                : cleaned
            if FileManager.default.fileExists(atPath: expanded) {
                return expanded
            }
        }
        return RStudioRecentProjects.resolvePath(forName: cleaned)
    }

    private func migratePathsLocked() {
        var entries = loadEntries()
        var changed = false
        for index in entries.indices {
            if entries[index].path == nil || !FileManager.default.fileExists(atPath: entries[index].path!) {
                if let path = RStudioRecentProjects.resolvePath(forName: entries[index].name) {
                    entries[index].path = path
                    changed = true
                }
            }
        }
        if changed {
            saveEntries(entries)
        }
    }

    private func resolvedPath(for entry: ProjectHistoryEntry) -> String? {
        normalizeExistingPath(entry.path) ?? RStudioRecentProjects.resolvePath(forName: entry.name)
    }

    private func normalizeExistingPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let expanded = path.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
            : path
        return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
    }

    private func isGenericTitle(_ title: String) -> Bool {
        title == "RStudio" || title.hasPrefix("RStudio (")
    }

    private func dedupeKey(name: String, path: String?) -> String {
        if let path {
            return "path:\(path)"
        }
        return "name:\(name.lowercased())"
    }

    private func loadEntries() -> [ProjectHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ProjectHistoryEntry].self, from: data)) ?? []
    }

    private func saveEntries(_ entries: [ProjectHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
