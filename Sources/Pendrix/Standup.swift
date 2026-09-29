import Foundation

/// One thing you did: "approved !482 feat(refund)…" with where it happened.
struct Activity: Hashable {
    let date: Date
    let text: String
    let place: String     // repo path or Jira project
}

struct Standup {
    var since: Date
    var yesterday: [String] = []
    var today: [String] = []
    var blockers: [String] = []
    var generated = Date()
    /// Spoken version from the polisher, when one is configured.
    var polished: String? = nil
    var polishError: String? = nil

    var markdown: String {
        func block(_ title: String, _ items: [String]) -> String {
            "**\(title)**\n" + (items.isEmpty ? "- —" : items.map { "- \($0)" }.joined(separator: "\n"))
        }
        return [block(sinceLabel, yesterday), block("Today", today), block("Blockers", blockers)].joined(separator: "\n\n")
    }
    var plain: String { markdown.replacingOccurrences(of: "**", with: "") }

    var sinceLabel: String {
        let days = Calendar.current.dateComponents([.day], from: since, to: Calendar.current.startOfDay(for: Date())).day ?? 1
        return days > 1 ? "Since \(since.formatted(.dateTime.weekday(.wide)))" : "Yesterday"
    }

    /// Start of yesterday, or of Friday when today is Monday.
    static func defaultSince(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let back = cal.component(.weekday, from: today) == 2 ? 3 : 1
        return cal.date(byAdding: .day, value: -back, to: today)!
    }
}

/// Rule-based assembly. No model involved; the inputs are already structured.
enum StandupBuilder {
    static func build(since: Date, activity: [Activity], jira: [WorkItem], reviews: [WorkItem], own: [WorkItem]) -> Standup {
        var s = Standup(since: since)

        // Yesterday: collapse pushes per branch, keep the rest in time order, newest last.
        // one line per repo: "Pushed to feat/a, feat/b · repo" (main/master pushes are merges, usually already listed as Merged)
        var pushes: [String: [String]] = [:]
        var lines: [(Date, String)] = []
        // uncommitted files only count for repos you actually touched in the window; stale scratch repos stay quiet
        let activePlaces = Set(activity.filter { !$0.text.hasPrefix("wip:") }.map(\.place))
        var wip: [String] = []
        for a in activity.sorted(by: { $0.date < $1.date }) {
            if a.text.hasPrefix("wip:") { if activePlaces.contains(a.place) { wip.append("\(a.place) (\(a.text.dropFirst(4)) files)") }; continue }
            if a.text.hasPrefix("pushed:") {
                let branch = String(a.text.dropFirst("pushed:".count))
                if ["main", "master", "develop"].contains(branch) { continue }
                if !(pushes[a.place] ?? []).contains(branch) { pushes[a.place, default: []].append(branch) }
                continue
            }
            lines.append((a.date, a.place.isEmpty ? a.text : "\(a.text) · \(a.place)"))
        }
        for (place, branches) in pushes.sorted(by: { $0.key < $1.key }) {
            lines.append((.distantPast, "Pushed to \(branches.joined(separator: ", "))\(place.isEmpty ? "" : " · \(place)")"))
        }
        var seen = Set<String>()
        s.yesterday = lines.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
        if !wip.isEmpty { s.today.insert("Uncommitted work in \(wip.joined(separator: ", "))", at: 0) }

        // Today: what's in flight, what's waiting on me, what's wrong with mine.
        for j in jira where j.statusTone == .active {
            s.today.append("Continue \(j.key) \"\(j.title)\"")
        }
        for r in reviews where !r.isDraft {
            s.today.append("Review \(r.key) \"\(r.title)\" (\(r.subtitle))")
        }
        for m in own {
            if m.hasConflicts { s.today.append("Fix conflicts on \(m.key) \"\(m.title)\"") }
            else if m.status == "threads open" { s.today.append("Resolve threads on \(m.key) \"\(m.title)\"") }
            else if m.pipeline == "failed" { s.today.append("Fix pipeline on \(m.key) \"\(m.title)\"") }
        }
        if s.today.isEmpty, let next = jira.first(where: { $0.statusTone == .neutral }) {
            s.today.append("Start \(next.key) \"\(next.title)\"")
        }

        // Blockers.
        let dayAgo = Date().addingTimeInterval(-86400)
        for m in own where !m.isDraft && m.approvals == 0 && m.updated < dayAgo && !m.hasConflicts {
            s.blockers.append("\(m.key) waiting for review since \(m.updated.relative) ago")
        }
        for j in jira where (j.status ?? "").localizedCaseInsensitiveContains("block") {
            s.blockers.append("\(j.key) is \(j.status ?? "blocked"): \"\(j.title)\"")
        }
        return s
    }
}
