import Foundation

/// Finds the local clone of a remote repo by scanning configured roots for .git/config remotes.
/// Results are cached; a miss rescans once per launch.
enum RepoLocator {
    private static var cacheKey = "repoLocator.cache"
    private static var scanned = false
    private static var index: [String: String] = [:]     // normalized remote → local path

    /// Read off the main actor once per call site; the scanner itself is nonisolated.
    nonisolated(unsafe) static var configuredRoots = "~/Desktop/works"

    static var roots: [String] {
        (configuredRoots.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            .map { NSString(string: $0).expandingTildeInPath }
    }

    /// "https://git.7.solutions/group/sub/repo/-/merge_requests/1" → "git.7.solutions/group/sub/repo"
    static func remoteKey(fromWebURL u: URL) -> String? {
        guard let host = u.host else { return nil }
        var path = u.path
        if let r = path.range(of: "/-/") { path = String(path[..<r.lowerBound]) }
        else if let r = path.range(of: "/pull/") { path = String(path[..<r.lowerBound]) }
        else if let r = path.range(of: "/merge_requests/") { path = String(path[..<r.lowerBound]) }
        return normalize(host + path)
    }

    /// Accepts https://host/a/b.git, git@host:a/b.git, ssh://git@host/a/b
    static func normalize(_ remote: String) -> String {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        s = s.replacingOccurrences(of: ":", with: "/")
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func locate(_ webURL: URL) -> String? {
        guard let key = remoteKey(fromWebURL: webURL) else { return nil }
        if let cached = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String])?[key],
           FileManager.default.fileExists(atPath: cached + "/.git") { return cached }
        if !scanned { scan(); scanned = true }
        if let hit = index[key] {
            var d = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
            d[key] = hit; UserDefaults.standard.set(d, forKey: cacheKey)
            return hit
        }
        return nil
    }

    /// Walks roots up to 4 levels, reads each .git/config for remote URLs.
    static func scan() {
        index = [:]
        let fm = FileManager.default
        func walk(_ dir: String, depth: Int) {
            guard depth <= 4, let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            if items.contains(".git") {
                for remote in remotes(of: dir) { index[normalize(remote)] = dir }
                return
            }
            for i in items where !i.hasPrefix(".") && !["node_modules", "vendor", ".build", "Pods", "dist"].contains(i) {
                let p = dir + "/" + i
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { walk(p, depth: depth + 1) }
            }
        }
        for r in roots { walk(r, depth: 0) }
    }

    private static func remotes(of repo: String) -> [String] {
        guard let cfg = try? String(contentsOfFile: repo + "/.git/config", encoding: .utf8) else { return [] }
        return cfg.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("url = ") else { return nil }
            return String(t.dropFirst("url = ".count))
        }
    }

    static var indexedCount: Int { if !scanned { scan(); scanned = true }; return index.count }
}
