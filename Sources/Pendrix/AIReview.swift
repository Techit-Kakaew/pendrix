import Foundation

/// One suggested comment from the AI pass. Nothing here is sent until the user posts it.
struct AIDraft: Identifiable, Hashable, Codable {
    enum Severity: String, Codable, CaseIterable { case blocker, suggestion, nit, question }
    var id = UUID()
    var path: String?
    var anchor: LineAnchor?
    var severity: Severity
    var title: String
    var body: String
    var posted = false
    var label: String = ""
    var decorations: [String] = []
    /// Posted text: conventional comment when a label is set, else the old bold-title form.
    var display: String {
        if !label.isEmpty { return ConventionalComment.format(label: label, decorations: decorations, subject: title, discussion: body) }
        return title.isEmpty ? body : "**\(title)**\n\n\(body)"
    }
}

/// Runs the Claude Code CLI in print mode with the user's existing login. No API key involved.
enum ClaudeCLI {
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // last resort: the login shell's PATH
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v claude"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Metadata from the last run, for the "where did the time go" line.
    struct Stats { var durationMs = 0; var turns = 0; var tokens = 0; var costUSD = 0.0
        var line: String {
            var p: [String] = []
            if durationMs > 0 { p.append(durationMs >= 60_000 ? "\(durationMs / 60_000)m \((durationMs % 60_000) / 1000)s" : "\(durationMs / 1000)s") }
            if turns > 0 { p.append("\(turns) turns") }
            if tokens > 0 { p.append(tokens >= 1000 ? "\(tokens / 1000)k tok" : "\(tokens) tok") }
            return p.joined(separator: " · ")
        }
    }
    nonisolated(unsafe) static var lastStats = Stats()

    /// `{"mcpServers":{}}` on disk, written once.
    static let emptyMCPConfig: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pendrix-mcp-empty.json")
        try? Data("{\"mcpServers\":{}}".utf8).write(to: url)
        return url.path
    }()

    /// Per-run speed knobs from Settings: model alias ("" = your Claude Code default), effort, and whether user hooks load.
    @MainActor static func speedArgs() -> [String] {
        let c = Config.shared
        var a: [String] = []
        if !c.aiModel.isEmpty { a += ["--model", c.aiModel] }
        if !c.aiEffort.isEmpty { a += ["--effort", c.aiEffort] }
        if c.aiSkipUserHooks { a += ["--setting-sources", "project,local"] }   // user hooks (rtk, caveman…) spawn a process per tool call
        return a
    }

    /// Feeds `prompt` on stdin; returns the model's final text. Tools disabled, nothing persisted.
    static func run(prompt: String, cwd: String? = nil, tools: [String] = [], allowed: [String] = [], mcpConfig: String? = nil, timeout: TimeInterval = 240) async throws -> String {
        let speed = await speedArgs()
        return try await run(prompt: prompt, cwd: cwd, tools: tools, allowed: allowed, mcpConfig: mcpConfig, extra: speed, timeout: timeout)
    }

    static func run(prompt: String, cwd: String?, tools: [String], allowed: [String], mcpConfig: String?, extra: [String], timeout: TimeInterval) async throws -> String {
        guard let exe = locate() else { throw APIError(message: "claude CLI not found — install Claude Code and run `claude` once to log in") }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            var args = ["-p", "--output-format", "json", "--no-session-persistence", "--tools", tools.isEmpty ? "" : tools.joined(separator: ",")]
            if !allowed.isEmpty { args += ["--allowedTools", allowed.joined(separator: ",")] }
            // Our own MCP set only: the user's global servers would otherwise load on every run (slower boot, unrelated tools).
            // Always strict: without it claude boots every MCP server configured on this Mac (Atlassian, Figma, browsers…) per run.
            args += ["--mcp-config", mcpConfig ?? emptyMCPConfig, "--strict-mcp-config"]
            args += extra
            p.arguments = args
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
            p.environment = env
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            var outData = Data(), errData = Data()
            outPipe.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            p.terminationHandler = { proc in
                timer.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                if let j = try? JSONSerialization.jsonObject(with: outData) as? [String: Any], let r = j["result"] as? String, !(j["is_error"] as? Bool ?? false) {
                    var st = Stats()
                    st.durationMs = (j["duration_ms"] as? Int) ?? 0
                    st.turns = (j["num_turns"] as? Int) ?? 0
                    st.costUSD = (j["total_cost_usd"] as? Double) ?? 0
                    if let u = j["usage"] as? [String: Any] {
                        st.tokens = ((u["input_tokens"] as? Int) ?? 0) + ((u["output_tokens"] as? Int) ?? 0)
                            + ((u["cache_read_input_tokens"] as? Int) ?? 0) + ((u["cache_creation_input_tokens"] as? Int) ?? 0)
                    }
                    lastStats = st
                    cont.resume(returning: r); return
                }
                let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let out = String(decoding: outData.prefix(400), as: UTF8.self)
                cont.resume(throwing: APIError(message: proc.terminationStatus == 15 ? "claude timed out" : "claude failed: \(err.isEmpty ? out : err)"))
            }
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(Data(prompt.utf8))
                try? inPipe.fileHandleForWriting.close()
            } catch { timer.cancel(); cont.resume(throwing: error) }
        }
    }
}

/// Builds the review prompt from a change and turns the model's JSON back into drafts.
enum AIReviewer {
    static let maxDiffBytes = 180_000

    enum Mode: Equatable, Codable { case diffOnly, deep(repo: String) }

    /// What survives leaving the screen: drafts, summary, mode, and the head commit they were made for.
    struct Saved: Codable {
        var headSHA: String
        var summary: String
        var drafts: [AIDraft]
        var skipped: [String]
        var mode: Mode
    }
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pendrix/ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ ref: ChangeRef) -> URL {
        dir.appendingPathComponent("\(ref.hostID.uuidString)-\(ref.project.replacingOccurrences(of: "/", with: "_"))-\(ref.number).json")
    }
    static func save(_ s: Saved, for ref: ChangeRef) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: file(ref), options: .atomic) }
    }
    static func load(for ref: ChangeRef) -> Saved? {
        guard let data = try? Data(contentsOf: file(ref)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Deep when a local clone exists and the setting is on: a detached worktree at the MR head, claude with read-only tools.
    static func review(_ d: ChangeDetail) async throws -> (summary: String, drafts: [AIDraft], skipped: [String], mode: Mode) {
        let (deep, roots) = await MainActor.run { (Config.shared.deepReview, Config.shared.repoRoots) }
        RepoLocator.configuredRoots = roots
        if deep, let repo = RepoLocator.locate(d.url) {
            let r = try await deepReview(d, repo: repo)
            return (r.summary, r.drafts, r.skipped, .deep(repo: repo))
        }
        let r = try await diffReview(d)
        return (r.summary, r.drafts, r.skipped, .diffOnly)
    }

    static func diffReview(_ d: ChangeDetail) async throws -> (summary: String, drafts: [AIDraft], skipped: [String]) {
        var skipped: [String] = []
        var diffText = ""
        for f in d.files {
            if f.binary || isGenerated(f.path) || f.hunks.flatMap(\.lines).count > 3000 { skipped.append(f.path); continue }
            var s = "### \(f.path)\(f.status == .renamed ? " (renamed from \(f.oldPath))" : "")\n"
            for h in f.hunks {
                s += h.header + "\n"
                for l in h.lines {
                    switch l.kind {
                    case .add: s += "+\(l.newNo ?? 0)| \(l.text)\n"
                    case .del: s += "-\(l.oldNo ?? 0)| \(l.text)\n"
                    case .context: s += " \(l.newNo ?? 0)| \(l.text)\n"
                    case .meta: break
                    }
                }
            }
            if diffText.utf8.count + s.utf8.count > maxDiffBytes { skipped.append(f.path); continue }
            diffText += s + "\n"
        }
        let existing = d.threads.flatMap(\.comments).map(\.body).joined(separator: "\n---\n")
        let prompt = """
        You are a senior engineer reviewing a merge request. Do not use tools. Output ONLY a JSON object, no prose, no markdown fences:
        {"summary": string, "findings": [{"path": string, "line": integer, "side": "new"|"old", "label": string, "decorations": [string], "subject": string, "discussion": string}]}

        Comments follow conventionalcomments.org. "label" is one of: praise, nitpick, suggestion, issue, todo, question, thought, chore, note, typo, polish, quibble.
        "decorations" is a subset of ["blocking", "non-blocking", "if-minor"] — use "blocking" only for issues that must be fixed before merge; nitpick/thought/note/praise are non-blocking by definition (leave decorations empty for them).
        "subject" is one short sentence stating the point; "discussion" is the reasoning and the concrete fix (may be empty for praise/typo). Both are posted verbatim as "<label> (<decorations>): <subject>\\n\\n<discussion>".
        Include at most one praise, only if something is genuinely well done.

        Rules:
        - Report real problems: bugs, races, security, data loss, error handling, API misuse, missing tests for risky logic, misleading names. Skip style that a formatter handles.
        - At most 8 findings, most important first. If the change is fine, return an empty findings array and say so in summary.
        - Be terse: "summary" ≤ 2 sentences; "discussion" ≤ 2 sentences (plus a code block only when it changes the outcome). Total output well under 400 words.
        - "path" MUST be the full repo-relative path exactly as written after "###" below (never just the file name — many files share one).
        - "line" MUST be a number that appears in the diff below: use the number after "+" or " " for side "new", the number after "-" for side "old".
        - "discussion" is direct and specific, 1–4 sentences, with a concrete fix when possible. Use markdown sparingly; fenced code for code.
        - Write in Thai if the MR title/description or existing comments are mostly Thai, otherwise in English. Keep identifiers, paths and code in their original form.
        - Do not repeat points already raised in existing comments.

        MR: \(d.title)
        Branch: \(d.sourceBranch) → \(d.targetBranch)
        Description:
        \(d.description.isEmpty ? "(none)" : d.description)

        Existing comments:
        \(existing.isEmpty ? "(none)" : existing)

        Diff (format: <sign><line number>| <code>):
        \(diffText)
        """
        let raw = try await ClaudeCLI.run(prompt: prompt)
        let (summary, findings) = try parse(raw)
        lastTiming = "claude \(ClaudeCLI.lastStats.line)"
        return (summary, map(findings, to: d), skipped)
    }

    // MARK: ask about one line

    /// A focused question at a line: the hunk around it plus the MR context. Returns a single draft anchored there.
    static func ask(_ question: String, at anchor: LineAnchor, line: DiffLine, file: FileDiff, detail d: ChangeDetail) async throws -> AIDraft {
        let all = file.hunks.flatMap(\.lines)
        let idx = all.firstIndex { $0.id == line.id } ?? 0
        let window = all[max(0, idx - 40)...min(all.count - 1, idx + 40)]
        var ctx = ""
        for l in window where l.kind != .meta {
            let mark = l.id == line.id ? ">>" : "  "
            switch l.kind {
            case .add: ctx += "\(mark)+\(l.newNo ?? 0)| \(l.text)\n"
            case .del: ctx += "\(mark)-\(l.oldNo ?? 0)| \(l.text)\n"
            default: ctx += "\(mark) \(l.newNo ?? 0)| \(l.text)\n"
            }
        }
        let q = question.trimmingCharacters(in: .whitespaces)
        let prompt = """
        You are pair-reviewing a merge request with a human. They point at ONE line (marked ">>") and ask a question. Do not use tools.
        Answer as a review comment they could post, following conventionalcomments.org: pick a label (praise, nitpick, suggestion, issue, todo, question, thought, chore, note, typo, polish, quibble), decorations ⊆ ["blocking","non-blocking","if-minor"], a one-sentence subject, and a discussion of 1–5 sentences with a concrete fix or reassurance (fenced code if useful).
        If the concern is unfounded, use label "note" and say plainly why. Answer in the language of the question.
        Output ONLY JSON: {"label": string, "decorations": [string], "subject": string, "discussion": string}

        MR: \(d.title)
        File: \(file.path)
        Question: \(q.isEmpty ? "Is there anything wrong with this line? Anything the change misses here?" : q)

        Context (format: <marker><sign><line>| code):
        \(ctx)
        """
        let raw = try await ClaudeCLI.run(prompt: prompt, timeout: 180)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { throw APIError(message: "AI returned no JSON") }
        struct A: Decodable { let label: String?; let decorations: [String]?; let subject: String?; let discussion: String?; let body: String? }
        let a = try JSONDecoder().decode(A.self, from: Data(String(raw[start...end]).utf8))
        let label = ConventionalComment.labels.contains((a.label ?? "").lowercased()) ? (a.label ?? "").lowercased() : "note"
        let decos = (a.decorations ?? []).map { $0.lowercased() }.filter { ConventionalComment.decorations.contains($0) }
        return AIDraft(path: file.path, anchor: anchor, severity: ConventionalComment.severity(label: label, decorations: decos),
                       title: a.subject ?? "", body: a.discussion ?? a.body ?? "", label: label, decorations: decos)
    }

    // MARK: deep review inside the local clone

    static func deepReview(_ d: ChangeDetail, repo: String) async throws -> (summary: String, drafts: [AIDraft], skipped: [String]) {
        // One persistent review worktree per repo: checkout moves to the MR head each run, so the codegraph index
        // (untracked .codegraph/) survives and only syncs the delta. Serialized per repo.
        let lock = reviewLock(for: repo); lock.lock(); defer { lock.unlock() }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pendrix/review", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tag = String(repo.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) } & 0xffffff, radix: 16)
        let wt = cache.appendingPathComponent("\((repo as NSString).lastPathComponent)-\(tag)").path
        try git(repo, ["fetch", "--quiet", "origin", d.sourceBranch, d.targetBranch])
        let head = d.headSHA.isEmpty ? "origin/\(d.sourceBranch)" : d.headSHA
        if FileManager.default.fileExists(atPath: wt + "/.git") {
            try git(wt, ["checkout", "--detach", "--quiet", "--force", head])
        } else {
            _ = try? git(repo, ["worktree", "prune"])
            try git(repo, ["worktree", "add", "--detach", "--quiet", wt, head])
        }
        let t0 = Date()
        let useGraph = await MainActor.run { Config.shared.useCodeGraph }
        let graphReady = useGraph && CodeGraph.ensureIndex(at: wt)
        let prepMs = Int(Date().timeIntervalSince(t0) * 1000)
        let mcp = graphReady ? CodeGraph.mcpConfig(for: wt) : nil
        defer { if let mcp { try? FileManager.default.removeItem(atPath: mcp) } }

        let base = d.baseSHA.isEmpty ? "origin/\(d.targetBranch)" : d.baseSHA
        let existing = d.threads.flatMap(\.comments).map(\.body).joined(separator: "\n---\n")
        let prompt = """
        You are reviewing a merge request inside a checkout of the repository at its head commit. Work the way the /code-review skill does at high effort:
        1. Run `git diff \(base) HEAD --stat` then `git diff \(base) HEAD` to see the change.
        \(graphReady ? "2. A pre-built code graph is available as the `codegraph_explore` tool (and codegraph_callers / codegraph_node). Use it FIRST for every changed or newly called symbol: it returns callers, callees, call paths and blast radius in one call. Fall back to Grep/Read only when the graph has no answer." : "2. For anything that looks wrong, READ the surrounding code (whole file, callers via Grep, existing tests) before deciding.")
        Report only findings you verified in the code; drop suspicions that the context resolves.
        Speed matters: issue independent tool calls together in ONE turn (several Read/Grep/codegraph calls at once), never one at a time. Budget: about 12 tool calls in total; stop exploring once the changed code and its direct callers/tests are covered.
        3. Look for: bugs, races, error handling, security, data loss, API/contract misuse, behaviour changes without tests, misleading names. Skip style a formatter handles.
        Do not modify files. Do not run the project's build or tests.

        Output ONLY a JSON object at the end, no prose around it, no markdown fences:
        {"summary": string, "findings": [{"path": string, "line": integer, "side": "new"|"old", "label": string, "decorations": [string], "subject": string, "discussion": string}]}
        Comments follow conventionalcomments.org. "label" ∈ praise, nitpick, suggestion, issue, todo, question, thought, chore, note, typo, polish, quibble. "decorations" ⊆ ["blocking", "non-blocking", "if-minor"]; "blocking" only for must-fix-before-merge. "subject" = one short sentence; "discussion" = reasoning + concrete fix (empty allowed). Posted verbatim as "<label> (<decorations>): <subject>\\n\\n<discussion>". At most one praise, only if earned.
        - "path" is the FULL repo-relative path exactly as `git diff` prints it (never just the file name — many files share one). "line" for side "new" is the line number in the HEAD version of the file; for side "old" it is the line number in the base version. Only reference lines that are part of the diff hunks.
        - At most 8 findings, most important first. Empty findings if the change is fine; say so in summary.
        - Be terse: "summary" ≤ 2 sentences; "discussion" ≤ 2 sentences, a fenced code block only when it changes the outcome. Total output well under 400 words.
        - Write in Thai if the MR title/description or existing comments are mostly Thai, otherwise English. Keep identifiers, paths and code verbatim.
        - Do not repeat points already in existing comments.

        MR: \(d.title)
        Branch: \(d.sourceBranch) → \(d.targetBranch)   base: \(base)   head: HEAD
        Description:
        \(d.description.isEmpty ? "(none)" : d.description)

        Existing comments:
        \(existing.isEmpty ? "(none)" : existing)
        """
        let raw = try await ClaudeCLI.run(prompt: prompt, cwd: wt,
                                          tools: ["Read", "Grep", "Glob", "Bash"],
                                          allowed: ["Read", "Grep", "Glob", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git blame:*)", "Bash(git status:*)", "Bash(ls:*)", "Bash(wc:*)", "mcp__codegraph__*"],
                                          mcpConfig: mcp, timeout: 600)
        let (summary, findings) = try parse(raw)
        lastTiming = "\(graphReady ? "codegraph" : "grep") · prep \(prepMs / 1000)s · claude \(ClaudeCLI.lastStats.line)"
        return (summary, map(findings, to: d), [])
    }
    nonisolated(unsafe) static var lastTiming = ""

    static let gitPath: String = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]
    private static let locksGuard = NSLock()
    private static func reviewLock(for repo: String) -> NSLock {
        locksGuard.lock(); defer { locksGuard.unlock() }
        if let l = locks[repo] { return l }
        let l = NSLock(); locks[repo] = l; return l
    }

    @discardableResult
    static func git(_ repo: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: gitPath); p.arguments = ["-C", repo] + args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw APIError(message: "git \(args.first ?? "") failed: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return o
    }

    private static func draft(from f: Finding, path: String, anchor: LineAnchor?) -> AIDraft {
        let label = (f.label ?? "").lowercased()
        let decos = (f.decorations ?? []).map { $0.lowercased() }.filter { ConventionalComment.decorations.contains($0) }
        if ConventionalComment.labels.contains(label) {
            return AIDraft(path: path, anchor: anchor, severity: ConventionalComment.severity(label: label, decorations: decos),
                           title: f.subject ?? f.title ?? "", body: f.discussion ?? f.body ?? "", label: label, decorations: decos)
        }
        return AIDraft(path: path, anchor: anchor, severity: AIDraft.Severity(rawValue: f.severity ?? "") ?? .suggestion,
                       title: f.subject ?? f.title ?? "", body: f.discussion ?? f.body ?? "")
    }

    /// Exact path first. Otherwise, among files sharing the suffix/basename (many `index.tsx`), prefer the one that
    /// actually has that line and mentions an identifier from the comment.
    private static func resolveFile(_ f: Finding, in d: ChangeDetail) -> FileDiff? {
        if let exact = d.files.first(where: { $0.path == f.path }) { return exact }
        let want = (f.path as NSString).lastPathComponent
        let candidates = d.files.filter { $0.path.hasSuffix("/" + f.path) || $0.path.hasSuffix(f.path) || ($0.path as NSString).lastPathComponent == want }
        if candidates.count <= 1 { return candidates.first }
        let text = ((f.subject ?? f.title ?? "") + " " + (f.discussion ?? f.body ?? ""))
        let idents = Set(text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { $0.count >= 4 && $0.rangeOfCharacter(from: .letters) != nil })
        func score(_ file: FileDiff) -> Int {
            let lines = file.hunks.flatMap(\.lines)
            var s = 0
            if lines.contains(where: { $0.newNo == f.line || $0.oldNo == f.line }) { s += 2 }
            let around = lines.filter { abs(($0.newNo ?? -99) - f.line) <= 8 }.map(\.text).joined(separator: "\n")
            if idents.contains(where: { around.contains($0) }) { s += 4 }
            else if idents.contains(where: { ident in lines.contains { $0.text.contains(ident) } }) { s += 1 }
            return s
        }
        return candidates.max { score($0) < score($1) }
    }

    /// Context lines need both numbers (GitLab line_code), additions only new, deletions only old.
    static func anchor(for l: DiffLine, path: String) -> LineAnchor {
        switch l.kind {
        case .add: return LineAnchor(path: path, oldLine: nil, newLine: l.newNo)
        case .del: return LineAnchor(path: path, oldLine: l.oldNo, newLine: nil)
        default: return LineAnchor(path: path, oldLine: l.oldNo, newLine: l.newNo)
        }
    }

    private static func map(_ findings: [Finding], to d: ChangeDetail) -> [AIDraft] {
        findings.map { f -> AIDraft in
            var anchor: LineAnchor? = nil
            if let file = resolveFile(f, in: d) {
                let lines = file.hunks.flatMap(\.lines)
                if f.side == "old", let l = lines.first(where: { $0.kind == .del && $0.oldNo == f.line }) {
                    anchor = LineAnchor(path: file.path, oldLine: l.oldNo, newLine: nil)
                } else if let l = lines.first(where: { $0.kind != .del && $0.newNo == f.line }) {
                    anchor = Self.anchor(for: l, path: file.path)
                } else if let l = lines.first(where: { $0.newNo == f.line || $0.oldNo == f.line }) {
                    anchor = Self.anchor(for: l, path: file.path)
                } else if let l = lines.filter({ $0.kind != .meta && $0.newNo != nil }).min(by: { abs(($0.newNo ?? 0) - f.line) < abs(($1.newNo ?? 0) - f.line) }),
                          abs((l.newNo ?? 0) - f.line) <= 6 {
                    // the model pointed just outside the hunk: snap to the nearest visible line rather than losing the anchor
                    anchor = Self.anchor(for: l, path: file.path)
                }
                return draft(from: f, path: file.path, anchor: anchor)
            }
            return draft(from: f, path: f.path, anchor: nil)
        }
    }

    private struct Finding: Decodable {
        let path: String; let line: Int; let side: String?
        let label: String?; let decorations: [String]?; let subject: String?; let discussion: String?
        // legacy shape, still accepted
        let severity: String?; let title: String?; let body: String?
    }
    private struct Payload: Decodable { let summary: String?; let findings: [Finding]? }

    /// Tolerates fences or stray prose around the object.
    private static func parse(_ raw: String) throws -> (String, [Finding]) {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { throw APIError(message: "AI returned no JSON: \(raw.prefix(200))") }
        let json = String(raw[start...end])
        let p = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        return (p.summary ?? "", p.findings ?? [])
    }

    static func isGenerated(_ path: String) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        if ["go.sum", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "poetry.lock", "gemfile.lock", "podfile.lock", "composer.lock"].contains(n) { return true }
        if n.hasSuffix(".min.js") || n.hasSuffix(".min.css") || n.hasSuffix(".pb.go") || n.hasSuffix(".generated.ts") || n.hasSuffix(".g.dart") || n.hasSuffix(".snap") { return true }
        return path.contains("/mocks/") || path.contains("/__snapshots__/") || path.contains("/vendor/") || path.contains("/node_modules/")
    }
}
