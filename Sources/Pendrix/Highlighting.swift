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
        let code = file.hunks.flatMap { $0.lines.filter { $0.kind != .meta } }
        guard !code.isEmpty else { return [:] }
        let joined = code.map(\.text).joined(separator: "\n")
        // TS/TSX/JS/JSX: tree-sitter (exact, JSX-aware). Everything else: highlight.js.
        let usingTreeSitter = TreeSitterHighlighter.supports(file.path)
        var lang: String? = nil
        var attr: NSAttributedString? = nil
        if usingTreeSitter {
            attr = TreeSitterHighlighter.highlight(joined, path: file.path, dark: isDark)
        }
        if attr == nil {
            guard let l = Self.language(for: file.path), let h = engine(dark: isDark) else { return [:] }
            lang = l; attr = h.highlight(joined, as: l)
        }
        guard let attr else { return [:] }
        let h = engine(dark: isDark)
        let m = NSMutableAttributedString(attributedString: attr)
        m.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: m.length))
        m.removeAttribute(.font, range: NSRange(location: 0, length: m.length))   // the view sets the (zoomable) font
        // Split back into lines; attribute runs never cross a newline in hljs output.
        var out: [Int: AttributedString] = [:]
        var start = 0
        let ns = m.string as NSString
        var i = 0
        while i < code.count {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            let end = r.location == NSNotFound ? ns.length : r.location
            var line = m.attributedSubstring(from: NSRange(location: start, length: end - start))
            // JSX/TSX: once hljs is inside a tag it treats embedded JS as text. Lines that came back
            // in a single colour get a second pass on their own, which recovers keywords/strings.
            if !usingTreeSitter, let lang, let h, Self.isMonochrome(line), !code[i].text.trimmingCharacters(in: .whitespaces).isEmpty,
               let solo = h.highlight(code[i].text, as: lang), !Self.isMonochrome(solo) {
                let mm = NSMutableAttributedString(attributedString: solo)
                mm.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mm.length))
                mm.removeAttribute(.font, range: NSRange(location: 0, length: mm.length))
                line = mm
            }
            out[code[i].id] = AttributedString(line)
            start = end + 1; i += 1
            if r.location == NSNotFound { break }
        }
        cache[key] = out
        return out
    }

    /// True when every run shares one foreground colour (i.e. hljs coloured nothing).
    private static func isMonochrome(_ a: NSAttributedString) -> Bool {
        var colors = Set<String>()
        a.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: a.length)) { v, range, stop in
            if a.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespaces).isEmpty { return }
            colors.insert((v as? NSColor)?.description ?? "none")
            if colors.count > 1 { stop.pointee = true }
        }
        return colors.count <= 1
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
