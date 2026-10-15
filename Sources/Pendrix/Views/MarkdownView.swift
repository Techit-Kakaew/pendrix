import SwiftUI

/// Block-level Markdown for MR descriptions and comments: headings, lists, fenced code, quotes, simple tables,
/// horizontal rules, plus inline bold/italic/code/links via Foundation. GitLab-style :emoji: shortcodes too.
struct MarkdownView: View {
    let text: String
    var font: Font = Type.title

    private enum Block {
        case heading(Int, String), para([String]), bullet([(indent: Int, text: String, ordered: String?)])
        case code(String, String), quote([String]), rule, table([[String]])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, b in render(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(inline(t)).font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13.5, weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2).textSelection(.enabled)
        case .para(let lines):
            Text(inline(lines.joined(separator: " "))).font(font).lineSpacing(3).textSelection(.enabled)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let n = it.ordered { Text(n + ".").font(font).foregroundStyle(.secondary).monospacedDigit() }
                        else { Circle().fill(.secondary.opacity(0.6)).frame(width: 4, height: 4).offset(y: -3) }
                        Text(inline(it.text)).font(font).lineSpacing(2).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(it.indent) * 16)
                }
            }
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty { Text(lang).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 6) }
                Text(code).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
        case .quote(let lines):
            Text(inline(lines.joined(separator: " "))).font(font).foregroundStyle(.secondary).lineSpacing(2)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
        case .rule:
            Divider().padding(.vertical, 2)
        case .table(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(inline(c)).font(i == 0 ? font.weight(.semibold) : font).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(i == 0 ? Color.primary.opacity(0.06) : (i % 2 == 0 ? Color.primary.opacity(0.02) : .clear))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        let withEmoji = Self.emoji(s)
        return (try? AttributedString(markdown: withEmoji, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(withEmoji)
    }

    private static let shortcodes: [String: String] = [
        "pencil": "✏️", "hammer_pick": "⚒️", "hammer": "🔨", "rocket": "🚀", "bug": "🐛", "warning": "⚠️", "white_check_mark": "✅",
        "x": "❌", "eyes": "👀", "tada": "🎉", "sparkles": "✨", "fire": "🔥", "memo": "📝", "zap": "⚡️", "lock": "🔒", "mag": "🔍",
        "construction": "🚧", "heavy_check_mark": "✔️", "point_right": "👉", "bulb": "💡", "question": "❓", "thumbsup": "👍", "+1": "👍",
        "art": "🎨", "wrench": "🔧", "recycle": "♻️", "boom": "💥", "package": "📦", "chart_with_upwards_trend": "📈", "link": "🔗",
    ]
    static func emoji(_ s: String) -> String {
        guard s.contains(":") else { return s }
        var out = s
        let re = try! NSRegularExpression(pattern: ":([a-z0-9_+]+):")
        for m in re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).reversed() {
            let name = (s as NSString).substring(with: m.range(at: 1))
            if let e = shortcodes[name] { out = (out as NSString).replacingCharacters(in: m.range, with: e) }
        }
        return out
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        func flushPara() { if !para.isEmpty { blocks.append(.para(para)); para = [] } }
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushPara()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []; i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                blocks.append(.code(lang, code.joined(separator: "\n"))); i += 1; continue
            }
            if line.isEmpty { flushPara(); i += 1; continue }
            if let m = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushPara(); let level = line[m].filter { $0 == "#" }.count
                blocks.append(.heading(level, String(line[m.upperBound...]))); i += 1; continue
            }
            if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil { flushPara(); blocks.append(.rule); i += 1; continue }
            if line.hasPrefix(">") {
                flushPara(); var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(q)); continue
            }
            if line.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: "^\\|?\\s*:?-{2,}", options: .regularExpression) != nil {
                flushPara(); var rows: [[String]] = []
                func cells(_ l: String) -> [String] { l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                rows.append(cells(line)); i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                blocks.append(.table(rows)); continue
            }
            if let m = raw.range(of: "^(\\s*)([-*+]|\\d+[.)])\\s+", options: .regularExpression) {
                flushPara(); var items: [(Int, String, String?)] = []
                var j = i
                while j < lines.count, let mm = lines[j].range(of: "^(\\s*)([-*+]|\\d+[.)])\\s+", options: .regularExpression) {
                    let prefix = String(lines[j][mm])
                    let indent = prefix.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
                    let marker = prefix.trimmingCharacters(in: .whitespaces)
                    let ordered = marker.first?.isNumber == true ? String(marker.dropLast()) : nil
                    var body = String(lines[j][mm.upperBound...])
                    // continuation lines indented under the item
                    var k = j + 1
                    while k < lines.count, !lines[k].trimmingCharacters(in: .whitespaces).isEmpty,
                          lines[k].range(of: "^(\\s*)([-*+]|\\d+[.)])\\s+", options: .regularExpression) == nil,
                          lines[k].hasPrefix("  ") { body += " " + lines[k].trimmingCharacters(in: .whitespaces); k += 1 }
                    items.append((indent, body, ordered)); j = k
                }
                _ = m
                blocks.append(.bullet(items.map { (indent: $0.0, text: $0.1, ordered: $0.2) })); i = j; continue
            }
            para.append(line); i += 1
        }
        flushPara()
        lines.removeAll()
        return blocks
    }
}
