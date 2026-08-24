import Foundation

enum RStudioSessionProjects {
    private static var cache: [pid_t: String] = [:]

    static func projectPath(forMainPID mainPID: pid_t) -> String? {
        if let cached = cache[mainPID] {
            return FileManager.default.fileExists(atPath: cached) ? cached : nil
        }
        guard let rsessionPID = rsessionPID(forMainPID: mainPID) else { return nil }
        guard let path = projectPath(forRSessionPID: rsessionPID) else { return nil }
        cache[mainPID] = path
        return path
    }

    /// Exposed for title lookup without requiring a full project-path resolve.
    static func rsessionPIDForTitleLookup(mainPID: pid_t) -> pid_t? {
        rsessionPID(forMainPID: mainPID)
    }

    static func invalidateCache() {
        cache.removeAll()
    }

    static func removeCached(mainPID: pid_t) {
        cache.removeValue(forKey: mainPID)
    }

    /// Also treat a bare working directory as a project only when it contains a .Rproj
    /// whose name matches the folder (avoids labeling blank sessions from shared cwds).
    private static func projectPath(forRSessionPID pid: pid_t) -> String? {
        if let cwd = workingDirectory(of: pid) {
            if let path = rprojInDirectory(cwd) {
                return path
            }
            let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            if let path = rprojInDirectory(parent) {
                return path
            }
        }
        return initialProjectFromEnvironment(of: pid)
    }

    private static func rsessionPID(forMainPID mainPID: pid_t) -> pid_t? {
        var queue = childPIDs(of: mainPID)
        var visited = Set<pid_t>()

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            if visited.contains(pid) { continue }
            visited.insert(pid)

            if commandLine(for: pid).localizedCaseInsensitiveContains("rsession") {
                return pid
            }
            queue.append(contentsOf: childPIDs(of: pid))
        }
        return nil
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let output = runCommand(executable: "/usr/bin/pgrep", arguments: ["-P", String(parent)])
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        let output = runCommand(executable: "/usr/sbin/lsof", arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("n") {
                let raw = String(line.dropFirst())
                let decoded = decodeLsofPath(raw)
                if FileManager.default.fileExists(atPath: decoded) {
                    return decoded
                }
            }
        }
        return nil
    }

    private static func initialProjectFromEnvironment(of pid: pid_t) -> String? {
        let output = commandLine(for: pid)
        guard let range = output.range(of: "RS_INITIAL_PROJECT=") else { return nil }
        let tail = output[range.upperBound...]
        guard let end = tail.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let raw = String(tail[..<end])
        let expanded = expandHome(raw)
        return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
    }

    private static func rprojInDirectory(_ directory: String) -> String? {
        let dirURL = URL(fileURLWithPath: directory)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let projects = items.filter { $0.pathExtension == "Rproj" }
        if projects.isEmpty { return nil }
        if projects.count == 1 { return projects[0].path }

        let baseName = dirURL.lastPathComponent
        if let match = projects.first(where: { $0.deletingPathExtension().lastPathComponent == baseName }) {
            return match.path
        }
        return projects.first?.path
    }

    private static func commandLine(for pid: pid_t) -> String {
        runCommand(executable: "/bin/ps", arguments: ["eww", "-p", String(pid), "-o", "command="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runCommand(executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func decodeLsofPath(_ raw: String) -> String {
        var bytes = Data()
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index] == "\\", raw.index(index, offsetBy: 2, limitedBy: raw.endIndex) != nil {
                let marker = raw[raw.index(after: index)]
                if marker == "x" {
                    let hexStart = raw.index(index, offsetBy: 2)
                    let hexEnd = raw.index(hexStart, offsetBy: 2, limitedBy: raw.endIndex) ?? hexStart
                    let hex = String(raw[hexStart..<hexEnd])
                    if hex.count == 2, let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        index = hexEnd
                        continue
                    }
                }
            }
            bytes.append(contentsOf: String(raw[index]).utf8)
            index = raw.index(after: index)
        }

        return String(data: bytes, encoding: .utf8) ?? raw
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
