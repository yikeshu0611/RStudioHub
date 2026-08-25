import Foundation

struct FileHistoryEntry: Equatable {
    let name: String
    let path: String
}

enum RStudioRecentFiles {
    private static var mruURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/rstudio/monitored/lists/file_mru")
    }

    /// Recent source files from RStudio's file MRU (newest first in file, sorted by pinyin for menu).
    static func allEntries() -> [FileHistoryEntry] {
        guard let content = try? String(contentsOf: mruURL, encoding: .utf8) else {
            return []
        }

        let paths = content
            .components(separatedBy: .newlines)
            .map { expandHome($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { path in
                !path.isEmpty
                    && !path.hasSuffix(".Rproj")
                    && FileManager.default.fileExists(atPath: path)
            }

        // Keep first (newest) when the same path appears again; compare case-insensitively.
        var seen = Set<String>()
        var uniquePaths: [String] = []
        uniquePaths.reserveCapacity(paths.count)
        for path in paths {
            let key = path.lowercased()
            guard seen.insert(key).inserted else { continue }
            uniquePaths.append(path)
        }

        let entries = uniquePaths.map { path in
            FileHistoryEntry(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
        return HubNameSort.sorted(entries) { $0.name }
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
