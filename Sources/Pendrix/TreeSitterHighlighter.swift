import Foundation
import AppKit
import SwiftTreeSitter
import TreeSitterTSX
import TreeSitterTypeScript

/// Exact TS/TSX/JS/JSX colouring via tree-sitter (highlight.js has no JSX grammar).
/// Predicates (#match?) are not evaluated by SwiftTreeSitter, so identifier casing is decided here.
enum TreeSitterHighlighter {
    static func supports(_ path: String) -> Bool { grammar(for: path) != nil }

    private enum Grammar { case tsx, ts }
    private static func grammar(for path: String) -> Grammar? {
        switch (path as NSString).pathExtension.lowercased() {
        case "tsx", "jsx": return .tsx
        case "ts", "js", "mjs", "cjs", "mts", "cts": return .ts
        default: return nil
        }
    }

    // Capture → priority (higher wins when ranges overlap) and colour role.
    private static let priority: [String: Int] = [
        "comment": 100, "string": 90, "string.regex": 90, "number": 85, "constant.builtin": 85,
        "keyword": 80, "tag": 75, "tag.attribute": 74, "function": 70, "function.method": 70,
        "property": 60, "type.builtin": 58, "type": 55, "constant": 54, "operator": 40,
        "punctuation.special": 35, "punctuation.bracket": 10, "punctuation.delimiter": 10, "variable": 5, "text": 1,
    ]

    struct Palette {
        let keyword, string, number, comment, function, type, property, tag, attribute, operatorC, constant, punctuation: NSColor
        static let dark = Palette(
            keyword: rgb(0xc678dd), string: rgb(0x98c379), number: rgb(0xd19a66), comment: rgb(0x7f848e),
            function: rgb(0x61afef), type: rgb(0xe5c07b), property: rgb(0xe06c75), tag: rgb(0xe06c75), attribute: rgb(0xd19a66),
            operatorC: rgb(0x56b6c2), constant: rgb(0xd19a66), punctuation: rgb(0xabb2bf))
        static let light = Palette(
            keyword: rgb(0xa626a4), string: rgb(0x50a14f), number: rgb(0x986801), comment: rgb(0xa0a1a7),
            function: rgb(0x4078f2), type: rgb(0xc18401), property: rgb(0xe45649), tag: rgb(0xe45649), attribute: rgb(0x986801),
            operatorC: rgb(0x0184bc), constant: rgb(0x986801), punctuation: rgb(0x383a42))
        static func rgb(_ v: Int) -> NSColor {
            NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }

    private static func color(_ name: String, text: String, _ p: Palette) -> NSColor? {
        switch name {
        case "comment": return p.comment
        case "string", "string.regex": return p.string
        case "number", "constant.builtin": return p.number
        case "keyword": return p.keyword
        case "tag": return p.tag
        case "tag.attribute": return p.attribute
        case "function", "function.method": return p.function
        case "property": return p.property
        case "type.builtin": return p.type
        case "operator": return p.operatorC
        case "punctuation.bracket", "punctuation.delimiter", "punctuation.special": return p.punctuation
        case "variable", "type", "constant":
            // casing heuristics stand in for the #match? predicates
            if text.range(of: "^[A-Z_][A-Z0-9_]{2,}$", options: .regularExpression) != nil { return p.constant }
            if text.first?.isUppercase == true { return p.type }
            return nil
        default: return nil
        }
    }

    private static let queryText = """
    (comment) @comment
    [(string) (template_string)] @string
    (template_substitution "${" @punctuation.special "}" @punctuation.special)
    (regex) @string.regex
    (number) @number
    [(true) (false) (null) (undefined)] @constant.builtin
    (type_identifier) @type
    (predefined_type) @type.builtin
    (identifier) @variable
    (call_expression function: (identifier) @function)
    (call_expression function: (member_expression property: (property_identifier) @function.method))
    (function_declaration name: (identifier) @function)
    (method_definition name: (property_identifier) @function.method)
    (pair key: (property_identifier) @property)
    (member_expression property: (property_identifier) @property)
    (shorthand_property_identifier) @property
    (jsx_opening_element name: (_) @tag)
    (jsx_closing_element name: (_) @tag)
    (jsx_self_closing_element name: (_) @tag)
    (jsx_attribute (property_identifier) @tag.attribute)
    (jsx_text) @text
    [ "abstract" "as" "async" "await" "break" "case" "catch" "class" "const" "continue" "debugger" "declare" "default"
      "delete" "do" "else" "enum" "export" "extends" "finally" "for" "from" "function" "get" "if" "implements" "import"
      "in" "instanceof" "interface" "is" "keyof" "let" "namespace" "new" "of" "override" "private" "protected" "public"
      "readonly" "return" "satisfies" "set" "static" "switch" "target" "throw" "try" "type" "typeof" "var" "void"
      "while" "with" "yield" ] @keyword
    [ "=" "=>" "+" "-" "*" "/" "%" "**" "==" "===" "!=" "!==" "<" ">" "<=" ">=" "&&" "||" "??" "!" "?" ":" "..." "+=" "-=" "*=" "/=" "|" "&" "??=" "||=" "&&=" ] @operator
    [ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
    [ ";" "," "." ] @punctuation.delimiter
    """

    private static var cache: [Grammar: (Language, Query)] = [:]
    private static func setup(_ g: Grammar) -> (Language, Query)? {
        if let c = cache[g] { return c }
        let lang = Language(language: g == .tsx ? tree_sitter_tsx() : tree_sitter_typescript())
        guard let q = try? Query(language: lang, data: Data(queryText.utf8)) else { return nil }
        cache[g] = (lang, q)
        return (lang, q)
    }

    /// Whole-file colouring. `text` is the diff's lines joined with "\n"; returns an attributed string of the same text.
    static func highlight(_ text: String, path: String, dark: Bool) -> NSAttributedString? {
        guard let g = grammar(for: path), let (lang, query) = setup(g) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(lang)) != nil, let tree = parser.parse(text) else { return nil }
        let ns = text as NSString
        let p = dark ? Palette.dark : Palette.light
        // best capture per start offset (ranges from one query pass overlap only when they start together)
        var best: [Int: (Int, NSRange, String)] = [:]
        for m in query.execute(in: tree) {
            for c in m.captures {
                guard let name = c.name else { continue }
                let r = c.range
                guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
                let pr = priority[name] ?? 0
                if let cur = best[r.location], cur.0 >= pr { continue }
                best[r.location] = (pr, r, name)
            }
        }
        let out = NSMutableAttributedString(string: text)
        for (_, entry) in best {
            let (_, r, name) = entry
            if let col = color(name, text: ns.substring(with: r), p) {
                out.addAttribute(.foregroundColor, value: col, range: r)
            }
        }
        return out
    }
}
