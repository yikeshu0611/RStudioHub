import AppKit
import Foundation

enum HubUpdateService {
    private static let repoOwner = "yikeshu0611"
    private static let repoName = "RStudioHub"
    private static var isChecking = false
    private static var downloader: HubUpdateDownloadController?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func menuTitle() -> String {
        "更新 (\(currentVersion))"
    }

    static func checkForUpdates(interactive: Bool) {
        guard !isChecking else {
            if interactive {
                showAlert(title: "正在检查更新", message: "请稍候…")
            }
            return
        }
        isChecking = true
        ActivityLogger.shared.log("update.check start interactive=\(interactive) local=\(currentVersion)")

        fetchLatestRelease { result in
            DispatchQueue.main.async {
                isChecking = false
                switch result {
                case .failure(let error):
                    ActivityLogger.shared.log("update.check failed error=\(error.localizedDescription)")
                    if interactive {
                        showAlert(title: "检查更新失败", message: error.localizedDescription)
                    }
                case .success(let release):
                    ActivityLogger.shared.log("update.check remote=\(release.version) source=\(release.source)")
                    if compareVersion(release.version, greaterThan: currentVersion) {
                        promptToInstallUpdate(version: release.version, downloadURL: release.downloadURL)
                    } else if interactive {
                        showAlert(title: "已是最新版本", message: "当前版本：\(currentVersion)")
                    }
                }
            }
        }
    }

    private struct LatestRelease {
        let version: String
        let downloadURL: URL
        let source: String
    }

    private static func fetchLatestRelease(completion: @escaping (Result<LatestRelease, Error>) -> Void) {
        let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RStudioHub/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let release = decodeGitHubRelease(data: data) {
                completion(.success(release))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            completion(.failure(NSError(domain: "RStudioHub.Update", code: status, userInfo: [
                NSLocalizedDescriptionKey: "无法读取 GitHub 发布信息（HTTP \(status)）",
            ])))
        }.resume()
    }

    private static func decodeGitHubRelease(data: Data?) -> LatestRelease? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            return nil
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !version.isEmpty else { return nil }

        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      name.hasSuffix(".dmg"),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else {
                    continue
                }
                return LatestRelease(version: version, downloadURL: url, source: "api-asset")
            }
        }

        guard let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/v\(version)/RStudioHub-\(version).dmg") else {
            return nil
        }
        return LatestRelease(version: version, downloadURL: url, source: "api-pattern")
    }

    private static func promptToInstallUpdate(version: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        alert.informativeText = "RStudioHub \(version) 可用，是否现在更新？\n确认后将下载安装包并重启应用。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "以后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            ActivityLogger.shared.log("update.declined version=\(version)")
            return
        }
        downloadAndInstall(from: downloadURL, version: version)
    }

    private static func downloadAndInstall(from url: URL, version: String) {
        let controller = HubUpdateDownloadController()
        downloader = controller
        controller.onFinish = { result in
            downloader = nil
            switch result {
            case .failure(let error):
                ActivityLogger.shared.log("update.download failed error=\(error.localizedDescription)")
                showAlert(title: "下载失败", message: error.localizedDescription)
            case .success(let dmgURL):
                installUpdate(fromDMG: dmgURL, version: version)
            }
        }
        controller.start(url: url)
    }

    private static func installUpdate(fromDMG dmgURL: URL, version: String) {
        let destination = URL(fileURLWithPath: "/Applications/RStudioHub.app")
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RStudioHub-update-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail
        PID=\(pid)
        DMG=\(bashQuoted(dmgURL.path))
        DEST=\(bashQuoted(destination.path))
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        sleep 1
        /usr/bin/pkill -x RStudioHub >/dev/null 2>&1 || true
        sleep 0.5
        xattr -cr "$DMG" >/dev/null 2>&1 || true
        MOUNT="$(mktemp -d /tmp/RStudioHub-mnt-XXXXXX)"
        /usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
        APP="$MOUNT/RStudioHub.app"
        NEW="${DEST}.updating"
        OLD="${DEST}.old"
        rm -rf "$NEW" "$OLD"
        /usr/bin/ditto "$APP" "$NEW"
        if [[ -d "$DEST" ]]; then mv "$DEST" "$OLD"; fi
        mv "$NEW" "$DEST"
        xattr -cr "$DEST" >/dev/null 2>&1 || true
        /usr/bin/hdiutil detach "$MOUNT" -force -quiet || true
        rm -rf "$OLD" "$MOUNT"
        open "$DEST"
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            try process.run()
            ActivityLogger.shared.log("update.install scheduled version=\(version)")
            NSApp.terminate(nil)
        } catch {
            ActivityLogger.shared.log("update.install failed error=\(error.localizedDescription)")
            showAlert(title: "安装失败", message: error.localizedDescription)
        }
    }

    private static func compareVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func bashQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private final class HubUpdateDownloadController: NSObject, URLSessionDownloadDelegate {
    var onFinish: ((Result<URL, Error>) -> Void)?
    private var session: URLSession?
    private var copiedURL: URL?
    private var delivered = false

    func start(url: URL) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = [
            "User-Agent": "RStudioHub/\(HubUpdateService.currentVersion) (macOS)",
        ]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("RStudioHub-download-\(UUID().uuidString).dmg")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: location, to: dest)
            copiedURL = dest
        } catch {
            deliver(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            deliver(.failure(error))
            return
        }
        if let copiedURL {
            deliver(.success(copiedURL))
        } else {
            deliver(.failure(NSError(
                domain: "RStudioHub.Update",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "更新下载未完成"]
            )))
        }
    }

    private func deliver(_ result: Result<URL, Error>) {
        guard !delivered else { return }
        delivered = true
        onFinish?(result)
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
