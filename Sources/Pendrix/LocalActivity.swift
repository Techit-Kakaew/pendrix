import Foundation

/// What you actually did on this Mac, independent of tickets: local git commits and Claude Code prompts.
enum LocalActivity {
    /// Commits authored by you in every clone under the configured roots, including unpushed branches.
    static func gitCommits(since: Date) -> [Activity] {
        let email = (try? AIReviewer.git(".", ["config", "--global", "user.email"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !email.isEmpty else { return [] }
        let iso = ISO8601DateFormatter().string(from: since)
        var out: [Activity] = []
        for repo in RepoLocator.allRepos() {
            let name = (repo as NSString).lastPathComponent
            guard let log = try? AIReviewer.git(repo, ["log", "--all", "--author=\(email)", "--since=\(iso)", "--no-merges", "--format=%s|%cI", "-n", "40"]) else { continue }
            var seen = Set<String>()
            for line in log.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, seen.insert(parts[0]).inserted else { continue }
                out.append(Activity(date: Dates.parse(parts[1]), text: "Committed: \(parts[0])", place: name))
            }
            if let st = try? AIReviewer.git(repo, ["status", "--porcelain"]) {
                let n = st.split(separator: "\n").count
                if n > 0 { out.append(Activity(date: Date(), text: "wip:\(n)", place: name)) }
            }
        }
        return out
    }

    /// Prompts you gave Claude Code, from ~/.claude/history.jsonl (one line per prompt: display, timestamp ms, project).
    static func claudePrompts(since: Date) -> [Activity] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/history.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        var byProject: [String: [(Date, String)]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ms = o["timestamp"] as? Double, let text = o["display"] as? String else { continue }
            let d = Date(timeIntervalSince1970: ms / 1000)
            guard d >= since else { continue }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // skip slash commands, pasted command output, and one-word acks
            if t.hasPrefix("/") || t.hasPrefix("<") || t.count < 12 { continue }
            let project = (((o["project"] as? String) ?? "") as NSString).lastPathComponent
            byProject[project, default: []].append((d, String(t.prefix(140)).replacingOccurrences(of: "\n", with: " ")))
        }
        var out: [Activity] = []
        for (project, prompts) in byProject {
            // first few prompts of the day describe the task; the rest is iteration
            for (d, p) in prompts.sorted(by: { $0.0 < $1.0 }).prefix(4) {
                out.append(Activity(date: d, text: "Asked Claude Code: \(p)", place: project))
            }
        }
        return out
    }
}
