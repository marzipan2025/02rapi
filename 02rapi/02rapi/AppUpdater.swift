import AppKit
import Foundation

// MARK: - App Updater
//
// GitHub Release (marzipan2025/02rapi) 의 latest 태그를 현재 버전과 비교하고,
// 첨부된 dmg 를 내려받아 실행 중인 앱 번들을 교체한 뒤 재실행한다.
// 재실행된 새 앱은 updatedToVersion 키를 보고 "Updated" 연출을 재생한다.

struct AppRelease: Sendable {
    let version: String
    let dmgURL: URL
}

enum AppUpdater {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/marzipan2025/02rapi/releases/latest")!
    private static let updatedKey = "updatedToVersion"

    // 테스트용: RAPI_UPDATE_CURRENT_VERSION=1.0.0 으로 실행하면 현재 버전을 그 값으로 간주.
    static var currentVersion: String {
        ProcessInfo.processInfo.environment["RAPI_UPDATE_CURRENT_VERSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    // Debug 빌드(Xcode 실행)는 DerivedData 번들을 덮어쓰지 않도록 환경변수가 있을 때만 검사.
    static var isCheckEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["RAPI_UPDATE_CURRENT_VERSION"] != nil
        #else
        return true
        #endif
    }

    // MARK: Check

    static func checkForUpdate() async -> AppRelease? {
        guard isCheckEnabled else { return nil }
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isVersion(version, newerThan: currentVersion) else { return nil }

        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let urlString = dmg["browser_download_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        return AppRelease(version: version, dmgURL: url)
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    // dmg 다운로드 → 마운트 → 앱 번들 옆에 스테이징 → 번들 교체.
    // 성공하면 교체된 번들 경로와, 옛 번들이 옮겨진 스테이징 폴더를 반환.
    // 스테이징 폴더는 실행 중인 옛 번들이라 여기서 지우지 않고 relaunch 가 종료 후 지운다.
    static func downloadAndInstall(_ release: AppRelease) async throws -> (bundle: URL, leftover: URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("02rapi-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. 다운로드
        let (downloaded, response) = try await URLSession.shared.download(from: release.dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dmg = work.appendingPathComponent("02rapi.dmg")
        try fm.moveItem(at: downloaded, to: dmg)

        // 2. 마운트 (Finder 에 띄우지 않음)
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])

        // 3. 현재 번들 옆에 스테이징 (같은 볼륨이어야 replaceItemAt 이 원자적으로 동작)
        let target = Bundle.main.bundleURL
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".02rapi-update-\(UUID().uuidString)")
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        do {
            guard let appName = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try await run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, staged.path])
        } catch {
            await detach(mount)
            try? fm.removeItem(at: staging)
            throw error
        }
        await detach(mount)

        do {
            // 4. 다른 앱이 섞여 들어오지 않았는지 번들 ID 확인
            guard let newID = Bundle(url: staged)?.bundleIdentifier,
                  newID == Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }

            // 5. 교체 (옛 번들은 staged 자리로 옮겨짐)
            try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            _ = try fm.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return (target, staging)
    }

    // 현재 프로세스가 끝나기를 기다렸다가 옛 번들을 지우고 새 번들을 연다.
    @MainActor
    static func relaunch(bundle: URL, leftover: URL, version: String) {
        UserDefaults.standard.set(version, forKey: updatedKey)
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /bin/rm -rf \"$1\"; /usr/bin/open \"$0\"",
                          bundle.path, leftover.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // 업데이트 직후 첫 실행이면 true (한 번만).
    static func consumeJustUpdated() -> Bool {
        guard let v = UserDefaults.standard.string(forKey: updatedKey) else { return false }
        UserDefaults.standard.removeObject(forKey: updatedKey)
        return v == currentVersion
    }

    // 분리가 한 번에 안 되면 디스크 이미지가 계속 붙어 남으므로 몇 번 더 시도한다.
    private static func detach(_ mount: URL) async {
        for attempt in 0..<3 {
            if (try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])) != nil { return }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
        }
    }

    private static func run(_ path: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(domain: "AppUpdater", code: Int(proc.terminationStatus),
                                                  userInfo: [NSLocalizedDescriptionKey: "\(path) failed"]))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
