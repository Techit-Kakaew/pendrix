import Foundation
import SwiftUI

/// One thing that needs attention. Jira issues, merge requests and GitLab todos all flatten to this.
struct WorkItem: Identifiable, Hashable {
    enum Source: String, Codable { case jira, gitlab }
    enum Kind: Hashable {
        case issue
        case reviewRequest
        case ownMergeRequest
        case todo
    }

    let id: String            // stable across polls: "jira:PROJ-1", "gl:mr:123", "gl:todo:9"
    let source: Source
    let kind: Kind
    let key: String           // PROJ-123 / group/repo!45
    let title: String
    let subtitle: String      // status name, author, action …
    let url: URL
    let updated: Date
    var status: String? = nil
    var statusTone: Tone = .neutral
    var priority: String? = nil
    var isDraft = false
    var hasConflicts = false
    var pipeline: String? = nil   // success / failed / running
    var approvals: Int = 0
    /// Set for MR/PR items: opens the in-app review window instead of the browser.
    var approvedByMe = false
    var change: ChangeRef? = nil
    var hostLabel: String = ""

    /// Semantic tint. Kept coarse so cards read calmly instead of turning into a rainbow.
    /// Brand accent for "something is waiting": the icon's amber dot.
    static let pendingColor = Color(red: 1.0, green: 0.84, blue: 0.42)

    enum Tone: Hashable {
        case neutral, active, done, warn, danger

        var color: Color {
            switch self {
            case .neutral: return Color.secondary
            case .active: return Color(red: 0.33, green: 0.56, blue: 1.00)
            case .done: return Color(red: 0.36, green: 0.78, blue: 0.55)
            case .warn: return Color(red: 0.98, green: 0.72, blue: 0.30)
            case .danger: return Color(red: 1.00, green: 0.45, blue: 0.42)
            }
        }
    }
}

extension Date {
    var relative: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 86400 * 14 { return "\(s / 86400)d" }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Jira "2026-09-19T10:11:12.345+0700" and GitLab "2026-09-19T03:11:12.345Z" both land here.
enum Dates {
    private static let jira: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"; return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        return jira.date(from: s) ?? isoFrac.date(from: s) ?? iso.date(from: s) ?? .distantPast
    }
}
