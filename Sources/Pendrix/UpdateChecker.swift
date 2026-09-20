import Foundation
import AppKit
import CryptoKit
import UserNotifications

/// Compares the running version with the latest GitHub release and installs it in place:
/// download .dmg → verify sha256 (the release's .dmg.sha256 asset) → mount → swap bundle → relaunch.
/// The new bundle keeps the signature it shipped with, so Keychain ACLs survive the update.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Phase: Equatable { case idle, downloading(Double), verifying, installing, relaunching, failed(String) }

    @Published var latest: String?
    @Published var latestURL: URL?
    @Published var dmgURL: URL?
    @Published var shaURL: URL?
    @Published var checking = false
    @Published var phase: Phase = .idle
    @Published var lastResult: String?

    nonisolated static let notificationId = "pendrix.update"
    var repo: String { Config.shared.updateRepo }
    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Silent check on launch and every 6 h; notifies once per new version.
    func autoCheck() {
        guard Config.shared.autoUpdate, Bundle.main.bundleIdentifier != nil else { return }
        let last = UserDefaults.standard.object(forKey: "update.lastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 6 * 3600 else { return }
        Task { if await check(manual: false), let v = latest { notifyIfNew(v) } }
    }

    private func notifyIfNew(_ v: String) {
        guard UserDefaults.standard.string(forKey: "update.notified") != v else { return }
        UserDefaults.standard.set(v, forKey: "update.notified")
        let c = UNMutableNotificationContent()
        c.title = "Pendrix \(v) is available"
        c.body = "Tap to install and relaunch."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationId, content: c, trigger: nil)) { _ in }
    }

    @discardableResult
    func check(manual: Bool, force: Bool = false) async -> Bool {
        checking = true; defer { checking = false }
        UserDefaults.standard.set(Date(), forKey: "update.lastCheck")
        guard !repo.isEmpty, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            lastResult = "No update repo configured"; return false
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else {
            lastResult = "Could not reach \(repo) releases"
            return false
        }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (j["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
        }
        if force || Self.isNewer(remote, than: current) {
            latest = remote; latestURL = (j["html_url"] as? String).flatMap(URL.init)
            dmgURL = asset(".dmg"); shaURL = asset(".dmg.sha256")
            lastResult = "\(remote) available"
            return true
        }
        latest = nil
        lastResult = "Up to date (\(current))"
        return false
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: install

    func installUpdate() async {
        guard let dmgURL else { openReleasePage(); return }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pendrix-update-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        do {
            phase = .downloading(0)
            let dmg = work.appendingPathComponent("Pendrix.dmg")
            try await download(dmgURL, to: dmg) { [weak self] p in Task { @MainActor in self?.phase = .downloading(p) } }

            phase = .verifying
            guard let shaURL else { throw Err("release has no .dmg.sha256 — refusing to install unverified image") }
            let (shaData, _) = try await URLSession.shared.data(from: shaURL)
            let expected = String(decoding: shaData, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else { throw Err("checksum mismatch") }

            phase = .installing
            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let newApp = mount.appendingPathComponent("Pendrix.app")
            guard fm.fileExists(atPath: newApp.path) else { throw Err("Pendrix.app not found in image") }

            let target = Bundle.main.bundleURL
            let dir = target.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: dir.path) else { throw Err("cannot write to \(dir.path)") }
            let staged = dir.appendingPathComponent(".Pendrix-\(latest ?? "new").app")
            let backup = dir.appendingPathComponent(".Pendrix-previous.app")
            try? fm.removeItem(at: staged); try? fm.removeItem(at: backup)
            try run("/bin/cp", ["-R", newApp.path, staged.path])
            try run("/usr/bin/xattr", ["-cr", staged.path])          // quarantine only; signature stays as shipped
            try fm.moveItem(at: target, to: backup)
            do { try fm.moveItem(at: staged, to: target) } catch { try? fm.moveItem(at: backup, to: target); throw error }
            try? fm.removeItem(at: backup)
            _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", target.path])

            phase = .relaunching
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
            try p.run()
            try? await Task.sleep(for: .milliseconds(300))
            NSApp?.terminate(nil); exit(0)
        } catch {
            phase = .failed((error as? Err)?.msg ?? error.localizedDescription)
        }
    }

    func openReleasePage() { if let u = latestURL { NSWorkspace.shared.open(u) } }

    struct Err: Error { let msg: String; init(_ m: String) { msg = m } }

    private func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Err("download failed") }
        let total = Double(resp.expectedContentLength)
        var data = Data(); data.reserveCapacity(Int(max(total, 0)))
        var lastReport = 0
        for try await b in bytes {
            data.append(b)
            if total > 0, data.count - lastReport > 200_000 { lastReport = data.count; progress(Double(data.count) / total) }
        }
        try data.write(to: dest); progress(1)
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Err("\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return o
    }
}
