import Foundation
import SwiftUI

/// conventionalcomments.org: `<label> [decorations]: <subject>\n\n[discussion]`
enum ConventionalComment {
    static let labels = ["praise", "nitpick", "suggestion", "issue", "todo", "question", "thought", "chore", "note", "typo", "polish", "quibble"]
    static let decorations = ["blocking", "non-blocking", "if-minor"]

    struct Parsed { let label: String; let decorations: [String]; let subject: String; let discussion: String }

    private static let regex = try! NSRegularExpression(
        pattern: "^\\s*(praise|nitpick|suggestion|issue|todo|question|thought|chore|note|typo|polish|quibble)\\s*(?:\\(([^)]*)\\))?\\s*:\\s*",
        options: [.caseInsensitive])

    static func parse(_ body: String) -> Parsed? {
        let ns = body as NSString
        guard let m = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let label = ns.substring(with: m.range(at: 1)).lowercased()
        let decos = m.range(at: 2).location == NSNotFound ? [] :
            ns.substring(with: m.range(at: 2)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let rest = ns.substring(from: m.range.location + m.range.length)
        let parts = rest.components(separatedBy: "\n\n")
        return Parsed(label: label, decorations: decos, subject: parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                      discussion: parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func format(label: String, decorations: [String], subject: String, discussion: String) -> String {
        var head = label
        if !decorations.isEmpty { head += " (\(decorations.joined(separator: ", ")))" }
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = discussion.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? "\(head): \(s)" : "\(head): \(s)\n\n\(d)"
    }

    /// Row colour: blocking things red, requests blue, soft things neutral, praise green.
    static func tone(label: String, decorations: [String]) -> WorkItem.Tone {
        if decorations.contains("blocking") { return .danger }
        switch label {
        case "issue", "todo", "chore", "typo": return decorations.contains("non-blocking") ? .warn : .danger
        case "suggestion", "polish": return .active
        case "question", "thought": return .warn
        case "praise": return .done
        default: return .neutral
        }
    }

    static func severity(label: String, decorations: [String]) -> AIDraft.Severity {
        if decorations.contains("blocking") { return .blocker }
        switch label {
        case "issue", "todo", "chore", "typo": return decorations.contains("non-blocking") ? .suggestion : .blocker
        case "nitpick", "quibble", "note", "praise": return .nit
        case "question", "thought": return .question
        default: return .suggestion
        }
    }
}

/// `issue (blocking)` pill for any comment that follows the convention.
struct ConventionalPill: View {
    let label: String
    let decorations: [String]
    var body: some View {
        HStack(spacing: 4) {
            StatusPill(text: label, tone: ConventionalComment.tone(label: label, decorations: decorations))
            ForEach(decorations, id: \.self) { d in
                Text(d).font(.system(size: 10)).foregroundStyle(d == "blocking" ? WorkItem.Tone.danger.color : .secondary)
            }
        }
    }
}

/// Label + decoration chooser above a compose box. Produces the prefix for the comment.
struct ConventionalPicker: View {
    @Binding var label: String
    @Binding var decorations: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(ConventionalComment.labels, id: \.self) { l in
                    Button(l) { label = label == l ? "" : l }
                        .buttonStyle(.plain).font(.system(size: 10, weight: label == l ? .semibold : .regular))
                        .foregroundStyle(label == l ? AnyShapeStyle(ConventionalComment.tone(label: l, decorations: Array(decorations)).color) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.primary.opacity(label == l ? 0.12 : 0.04)))
                }
            }
            if !label.isEmpty {
                HStack(spacing: 4) {
                    ForEach(ConventionalComment.decorations, id: \.self) { d in
                        let on = decorations.contains(d)
                        Button("(\(d))") { if on { decorations.remove(d) } else { decorations.remove(d == "blocking" ? "non-blocking" : d == "non-blocking" ? "blocking" : ""); decorations.insert(d) } }
                            .buttonStyle(.plain).font(.system(size: 10, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                }
            }
        }
    }
}
