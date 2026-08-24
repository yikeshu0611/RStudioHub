import Foundation

enum RStudioRecentProjects {
    private static var mruURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/rstudio/monitored/lists/project_mru")
    }

    /// Absolute .Rproj paths from RStudio's recent project list (newest first).
    static func paths() -> [String] {
        guard let content = try? String(contentsOf: mruURL, encoding: .utf8) else {
            return []
        }
        return content
            .components(separatedBy: .newlines)
            .map { expandHome($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && $0.hasSuffix(".Rproj") && FileManager.default.fileExists(atPath: $0) }
    }

    static func entries() -> [ProjectHistoryEntry] {
        paths().map { path in
            ProjectHistoryEntry(
                name: displayName(for: path),
                path: path,
                lastOpenedAt: (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date.distantPast
            )
        }
    }

    static func resolvePath(forName name: String) -> String? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        let candidates = paths()
        if let exact = candidates.first(where: { displayName(for: $0).caseInsensitiveCompare(needle) == .orderedSame }) {
            return exact
        }
        if let byFile = candidates.first(where: {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame
        }) {
            return byFile
        }
        if let byDir = candidates.first(where: {
            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame
        }) {
            return byDir
        }
        return nil
    }

    static func displayName(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func expandHome(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }
}
