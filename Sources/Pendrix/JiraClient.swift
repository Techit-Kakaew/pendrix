import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Jira Cloud REST v3. Auth: email + API token (Basic).
struct JiraClient {
    let base: URL
    let email: String
    let token: String

    private var auth: String {
        "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    func search(jql: String, max: Int = 50) async throws -> [WorkItem] {
        var comps = URLComponents(url: base.appendingPathComponent("rest/api/3/search/jql"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "jql", value: jql),
            .init(name: "maxResults", value: String(max)),
            .init(name: "fields", value: "summary,status,priority,issuetype,updated,project,parent"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Jira: no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Jira HTTP \(http.statusCode): \(Self.jiraMessage(data))")
        }
        let page = try JSONDecoder().decode(SearchPage.self, from: data)
        return page.issues.map { i in
            let f = i.fields
            let cat = f.status?.statusCategory?.key ?? ""
            let tone: WorkItem.Tone = switch cat {
            case "indeterminate": .active
            case "done": .done
            default: .neutral
            }
            var w = WorkItem(
                id: "jira:\(i.key)", source: .jira, kind: .issue,
                key: i.key, title: f.summary ?? "(no summary)",
                subtitle: f.issuetype?.name ?? "Issue",
                url: base.appendingPathComponent("browse/\(i.key)"),
                updated: Dates.parse(f.updated),
                status: f.status?.name, statusTone: tone,
                priority: f.priority?.name)
            w.parentKey = f.parent?.key; w.parentTitle = f.parent?.fields?.summary
            return w
        }
    }

    // MARK: activity

    /// Status changes and comments by me since `since`, from the changelog of recently touched issues.
    func activity(since: Date) async throws -> [Activity] {
        let me = try JSONDecoder().decode(Myself.self, from: try await request("GET", "rest/api/3/myself"))
        let days = max(1, Int(ceil(Date().timeIntervalSince(since) / 86400)))
        let jql = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) AND updated >= -\(days)d ORDER BY updated DESC"
        var comps = URLComponents(url: base.appendingPathComponent("rest/api/3/search/jql"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "jql", value: jql), .init(name: "maxResults", value: "30"),
                            .init(name: "fields", value: "summary,comment,project"), .init(name: "expand", value: "changelog")]
        var req = URLRequest(url: comps.url!)
        req.setValue(auth, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Jira activity: \(Self.jiraMessage(data))")
        }
        let page = try JSONDecoder().decode(ActivityPage.self, from: data)
        var out: [Activity] = []
        for i in page.issues {
            let label = "\(i.key) \(i.fields.summary ?? "")"
            let proj = i.fields.project?.key ?? ""
            for h in i.changelog?.histories ?? [] where h.author?.accountId == me.accountId {
                let d = Dates.parse(h.created); guard d >= since else { continue }
                for it in h.items where it.field == "status" {
                    out.append(Activity(date: d, text: "Moved \(label) → \(it.toString ?? "?")", place: proj))
                }
            }
            for c in i.fields.comment?.comments ?? [] where c.author?.accountId == me.accountId {
                let d = Dates.parse(c.created); guard d >= since else { continue }
                out.append(Activity(date: d, text: "Commented on \(label)", place: proj))
            }
        }
        return out
    }

    private struct ActivityPage: Decodable { let issues: [ActIssue] }
    private struct ActIssue: Decodable { let key: String; let fields: ActFields; let changelog: Changelog? }
    private struct ActFields: Decodable { let summary: String?; let comment: Comments?; let project: Proj? }
    private struct Proj: Decodable { let key: String }
    private struct Comments: Decodable { let comments: [JComment] }
    private struct JComment: Decodable { let author: Acct?; let created: String? }
    private struct Changelog: Decodable { let histories: [History] }
    private struct History: Decodable { let author: Acct?; let created: String?; let items: [ChangeItem] }
    private struct ChangeItem: Decodable { let field: String; let toString: String? }
    private struct Acct: Decodable { let accountId: String? }

    // MARK: ticket context for AI review

    /// Summary, type, status, parent and description (ADF flattened to text) — what the reviewer would read on the ticket.
    func issueText(_ key: String) async throws -> String {
        let d = try await request("GET", "rest/api/3/issue/\(key)?fields=summary,description,issuetype,status,parent,priority")
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let f = o["fields"] as? [String: Any] else { return "" }
        var out = "\(key): \((f["summary"] as? String) ?? "")"
        if let t = (f["issuetype"] as? [String: Any])?["name"] as? String { out += " [\(t)]" }
        if let s = (f["status"] as? [String: Any])?["name"] as? String { out += " — \(s)" }
        if let p = f["parent"] as? [String: Any], let pk = p["key"] as? String {
            out += "\nParent: \(pk) \(((p["fields"] as? [String: Any])?["summary"] as? String) ?? "")"
        }
        let desc = Self.flattenADF(f["description"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { out += "\n\(String(desc.prefix(4000)))" }
        return out
    }

    /// Atlassian Document Format → readable text (paragraphs, lists, headings, code).
    static func flattenADF(_ node: Any?) -> String {
        guard let n = node as? [String: Any] else { return "" }
        let type = n["type"] as? String ?? ""
        let children = (n["content"] as? [[String: Any]]) ?? []
        switch type {
        case "text": return (n["text"] as? String) ?? ""
        case "hardBreak": return "\n"
        case "mention": return "@" + (((n["attrs"] as? [String: Any])?["text"] as? String) ?? "")
        case "paragraph", "heading": return children.map { flattenADF($0) }.joined() + "\n"
        case "listItem": return "- " + children.map { flattenADF($0) }.joined()
        case "codeBlock": return "```\n" + children.map { flattenADF($0) }.joined() + "\n```\n"
        case "taskItem": return "- [\(((n["attrs"] as? [String: Any])?["state"] as? String) == "DONE" ? "x" : " ")] " + children.map { flattenADF($0) }.joined() + "\n"
        default: return children.map { flattenADF($0) }.joined()
        }
    }

    // MARK: actions

    struct Transition: Identifiable, Hashable { let id: String; let name: String; let toStatus: String }

    private func request(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Jira: no response") }
        guard (200..<300).contains(http.statusCode) else { throw APIError(message: "Jira HTTP \(http.statusCode): \(Self.jiraMessage(data))") }
        return data
    }

    func transitions(_ key: String) async throws -> [Transition] {
        let d = try await request("GET", "rest/api/3/issue/\(key)/transitions")
        let page = try JSONDecoder().decode(TransitionsPage.self, from: d)
        return page.transitions.map { Transition(id: $0.id, name: $0.name, toStatus: $0.to?.name ?? $0.name) }
    }

    func transition(_ key: String, to id: String) async throws {
        _ = try await request("POST", "rest/api/3/issue/\(key)/transitions", json: ["transition": ["id": id]])
    }

    func comment(_ key: String, _ body: String) async throws {
        let adf: [String: Any] = ["type": "doc", "version": 1,
                                  "content": [["type": "paragraph", "content": [["type": "text", "text": body]]]]]
        _ = try await request("POST", "rest/api/3/issue/\(key)/comment", json: ["body": adf])
    }

    func assignToMe(_ key: String) async throws {
        let me = try JSONDecoder().decode(Myself.self, from: try await request("GET", "rest/api/3/myself"))
        _ = try await request("PUT", "rest/api/3/issue/\(key)/assignee", json: ["accountId": me.accountId])
    }

    private struct TransitionsPage: Decodable { let transitions: [T] }
    private struct T: Decodable { let id: String; let name: String; let to: Named? }
    private struct Myself: Decodable { let accountId: String }

    private static func jiraMessage(_ d: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let m = o["errorMessages"] as? [String], !m.isEmpty { return m.joined(separator: "; ") }
            if let m = o["message"] as? String { return m }
        }
        return String(data: d.prefix(200), encoding: .utf8) ?? ""
    }

    private struct SearchPage: Decodable { let issues: [Issue] }
    private struct Issue: Decodable {
        let key: String
        let fields: Fields
    }
    private struct Fields: Decodable {
        let summary: String?
        let updated: String?
        let status: Status?
        let priority: Named?
        let issuetype: Named?
        let parent: Parent?
    }
    private struct Parent: Decodable { let key: String; let fields: ParentFields? }
    private struct ParentFields: Decodable { let summary: String? }
    private struct Status: Decodable { let name: String; let statusCategory: Category? }
    private struct Category: Decodable { let key: String }
    private struct Named: Decodable { let name: String }
}
