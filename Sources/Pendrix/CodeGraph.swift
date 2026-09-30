import Foundation

/// colbymchenry/codegraph: a per-repo SQLite symbol graph exposed to claude as an MCP server,
/// so "who calls this" is one tool call instead of a grep/read loop.
enum CodeGraph {
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/codegraph", "/opt/homebrew/bin/codegraph", "/usr/local/bin/codegraph"]
        // nvm installs: pick the newest node version that has it
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            candidates += versions.sorted().reversed().map { "\(home)/.nvm/versions/node/\($0)/bin/codegraph" }
        }
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v codegraph"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    static var isInstalled: Bool { locate() != nil }
    static let installCommand = "npm i -g @colbymchenry/codegraph"

    /// Build the index on first use, then incremental sync. Returns false when codegraph is missing or failed.
    static func ensureIndex(at dir: String) -> Bool {
        guard let exe = locate() else { return false }
        let hasDB = FileManager.default.fileExists(atPath: dir + "/.codegraph/codegraph.db")
        let args = hasDB ? ["sync", "-q", dir] : ["init", "-y", dir]
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["CODEGRAPH_TELEMETRY"] = "0"
        env["PATH"] = ((exe as NSString).deletingLastPathComponent) + ":" + (env["PATH"] ?? "")
        p.environment = env
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: dir + "/.codegraph/codegraph.db")
    }

    /// MCP config file pointing claude at the graph of `dir`. Watcher off: the worktree only changes between runs.
    static func mcpConfig(for dir: String) -> String? {
        guard let exe = locate() else { return nil }
        let json: [String: Any] = ["mcpServers": ["codegraph": ["type": "stdio", "command": exe, "args": ["serve", "--mcp", "--no-watch", "--path", dir],
                                                                 "env": ["CODEGRAPH_TELEMETRY": "0"]]]]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pendrix-mcp-\(UUID().uuidString.prefix(6)).json")
        guard let data = try? JSONSerialization.data(withJSONObject: json), (try? data.write(to: url)) != nil else { return nil }
        return url.path
    }
}
