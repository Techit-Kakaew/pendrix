import Foundation

/// One suggested comment from the AI pass. Nothing here is sent until the user posts it.
struct AIDraft: Identifiable, Hashable {
    enum Severity: String, Codable, CaseIterable { case blocker, suggestion, nit, question }
    let id = UUID()
    var path: String?
    var anchor: LineAnchor?
    var severity: Severity
    var title: String
    var body: String
    var posted = false
    var display: String { title.isEmpty ? body : "**\(title)**\n\n\(body)" }
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

    /// Feeds `prompt` on stdin; returns the model's final text. Tools disabled, nothing persisted.
    static func run(prompt: String, timeout: TimeInterval = 240) async throws -> String {
        guard let exe = locate() else { throw APIError(message: "claude CLI not found — install Claude Code and run `claude` once to log in") }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence"]
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

    static func review(_ d: ChangeDetail) async throws -> (summary: String, drafts: [AIDraft], skipped: [String]) {
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
        {"summary": string, "findings": [{"path": string, "line": integer, "side": "new"|"old", "severity": "blocker"|"suggestion"|"nit"|"question", "title": string, "body": string}]}

        Rules:
        - Report real problems: bugs, races, security, data loss, error handling, API misuse, missing tests for risky logic, misleading names. Skip style that a formatter handles.
        - At most 12 findings, most important first. If the change is fine, return an empty findings array and say so in summary.
        - "line" MUST be a number that appears in the diff below: use the number after "+" or " " for side "new", the number after "-" for side "old".
        - "body" is the comment as it should be posted: direct, specific, 1–4 sentences, with a concrete fix when possible. Use markdown sparingly; fenced code for code.
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
        let drafts = findings.map { f -> AIDraft in
            var anchor: LineAnchor? = nil
            if let file = d.files.first(where: { $0.path == f.path || $0.path.hasSuffix(f.path) }) {
                let lines = file.hunks.flatMap(\.lines)
                if f.side == "old", let l = lines.first(where: { $0.kind == .del && $0.oldNo == f.line }) {
                    anchor = LineAnchor(path: file.path, oldLine: l.oldNo, newLine: nil)
                } else if let l = lines.first(where: { $0.kind != .del && $0.newNo == f.line }) {
                    anchor = LineAnchor(path: file.path, oldLine: nil, newLine: l.newNo)
                } else if let l = lines.first(where: { $0.newNo == f.line || $0.oldNo == f.line }) {
                    anchor = LineAnchor(path: file.path, oldLine: l.kind == .del ? l.oldNo : nil, newLine: l.kind == .del ? nil : l.newNo)
                }
                return AIDraft(path: file.path, anchor: anchor, severity: AIDraft.Severity(rawValue: f.severity) ?? .suggestion, title: f.title, body: f.body)
            }
            return AIDraft(path: f.path, anchor: nil, severity: AIDraft.Severity(rawValue: f.severity) ?? .suggestion, title: f.title, body: f.body)
        }
        return (summary, drafts, skipped)
    }

    private struct Finding: Decodable { let path: String; let line: Int; let side: String?; let severity: String; let title: String; let body: String }
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
