import Foundation
import AppKit
import Highlightr

/// Syntax colouring for diff lines. One Highlightr per scheme; runs off the main thread, results cached per file.
actor Highlighting {
    static let shared = Highlighting()
    private var dark: Highlightr?
    private var light: Highlightr?
    private var cache: [String: [Int: AttributedString]] = [:]

    private func engine(dark isDark: Bool) -> Highlightr? {
        if isDark, let d = dark { return d }
        if !isDark, let l = light { return l }
        guard let h = Highlightr() else { return nil }
        h.setTheme(to: isDark ? "atom-one-dark" : "atom-one-light")
        h.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))
        h.ignoreIllegals = true
        if isDark { dark = h } else { light = h }
        return h
    }

    /// Lines keyed by `DiffLine.id`. Empty when the language is unknown, so the view falls back to plain text.
    func lines(for file: FileDiff, dark isDark: Bool) -> [Int: AttributedString] {
        let key = "\(file.path)|\(file.hunks.count)|\(isDark)"
        if let c = cache[key] { return c }
        guard let lang = Self.language(for: file.path), let h = engine(dark: isDark) else { return [:] }
        let code = file.hunks.flatMap { $0.lines.filter { $0.kind != .meta } }
        guard !code.isEmpty, let attr = h.highlight(code.map(\.text).joined(separator: "\n"), as: lang) else { return [:] }
        let m = NSMutableAttributedString(attributedString: attr)
        m.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: m.length))
        // Split back into lines; attribute runs never cross a newline in hljs output.
        var out: [Int: AttributedString] = [:]
        var start = 0
        let ns = m.string as NSString
        var i = 0
        while i < code.count {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            let end = r.location == NSNotFound ? ns.length : r.location
            out[code[i].id] = AttributedString(m.attributedSubstring(from: NSRange(location: start, length: end - start)))
            start = end + 1; i += 1
            if r.location == NSNotFound { break }
        }
        cache[key] = out
        return out
    }

    static func language(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" { return "dockerfile" }
        if name == "makefile" { return "makefile" }
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "go": return "go"
        case "rs": return "rust"
        case "py": return "python"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "dart": return "dart"
        case "php": return "php"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "yml", "yaml": return "yaml"
        case "json": return "json"
        case "toml": return "ini"
        case "md", "markdown": return "markdown"
        case "sh", "zsh", "bash": return "bash"
        case "sql": return "sql"
        case "html", "htm", "xml", "vue", "svelte", "plist": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "proto": return "protobuf"
        case "graphql", "gql": return "graphql"
        case "tf": return "hcl"
        default: return nil
        }
    }
}
