import Foundation

/// Model output is almost-JSON more often than JSON: raw newlines inside strings, trailing commas, ```json fences,
/// or a cut-off tail. Repair what can be repaired; salvage complete findings from a truncated array.
enum JSONRepair {
    static func object(from raw: String) -> [String: Any]? {
        var s = raw
        // strip fences / prose around the object
        if let a = s.firstIndex(of: "{") { s = String(s[a...]) }
        if let z = s.lastIndex(of: "}") { s = String(s[...z]) }
        if let o = parse(s) { return o }
        let fixed = escapeNewlinesInStrings(s)
        if let o = parse(fixed) { return o }
        let noTrailing = fixed.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        if let o = parse(noTrailing) { return o }
        if let o = parse(closeOpen(noTrailing)) { return o }
        return salvageFindings(noTrailing)
    }

    private static func parse(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// Inside a string literal, turn literal newlines/tabs into escapes and fix lone backslashes.
    static func escapeNewlinesInStrings(_ s: String) -> String {
        var out = ""; out.reserveCapacity(s.count)
        var inString = false, escaped = false
        for ch in s {
            if inString {
                if escaped { out.append(ch); escaped = false; continue }
                switch ch {
                case "\\": out.append(ch); escaped = true
                case "\"": out.append(ch); inString = false
                case "\n": out.append("\\n")
                case "\r": break
                case "\t": out.append("\\t")
                default: out.append(ch)
                }
            } else {
                if ch == "\"" { inString = true }
                out.append(ch)
            }
        }
        if inString { out.append("\"") }
        return out
    }

    /// Append the closers a truncated document is missing.
    static func closeOpen(_ s: String) -> String {
        var stack: [Character] = []
        var inString = false, escaped = false
        for ch in s {
            if inString { if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }; continue }
            switch ch {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]": if stack.last == ch { stack.removeLast() }
            default: break
            }
        }
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(",") { t.removeLast() }
        return t + String(stack.reversed())
    }

    /// Last resort: keep summary + every `{...}` inside "findings" that parses on its own.
    static func salvageFindings(_ s: String) -> [String: Any]? {
        var out: [String: Any] = [:]
        if let r = s.range(of: "\"summary\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", options: .regularExpression) {
            let m = String(s[r]); if let q = m.range(of: "\"", options: .backwards), let colon = m.firstIndex(of: ":") {
                let v = m[m.index(after: colon)...].trimmingCharacters(in: .whitespaces).dropFirst()
                out["summary"] = String(v[..<v.index(v.endIndex, offsetBy: -(m.distance(from: q.lowerBound, to: m.endIndex) - 1))])
            }
        }
        guard let fr = s.range(of: "\"findings\"\\s*:\\s*\\[", options: .regularExpression) else { return out.isEmpty ? nil : out }
        let body = String(s[fr.upperBound...])
        var items: [Any] = [], depth = 0, start: String.Index? = nil, inString = false, escaped = false
        for i in body.indices {
            let ch = body[i]
            if inString { if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }; continue }
            if ch == "\"" { inString = true; continue }
            if ch == "{" { if depth == 0 { start = i }; depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0, let st = start {
                let piece = String(body[st...i])
                if let o = parse(piece) { items.append(o) }
                start = nil
            } }
        }
        out["findings"] = items
        return out.isEmpty ? nil : out
    }
}
