import Foundation

/// GitLab REST v4. Token needs `api` for review actions, `read_api` is enough for the inbox.
struct GitLabHost: CodeHost {
    let config: HostConfig
    let base: URL
    let token: String
    private var http: HTTP { HTTP(headers: ["PRIVATE-TOKEN": token]) }
    private func api(_ path: String, _ q: [String: String] = [:]) -> URL { url(base, "api/v4/\(path)", q) }
    private func mr(_ ref: ChangeRef, _ tail: String = "", _ q: [String: String] = [:]) -> URL {
        api("projects/\(ref.project)/merge_requests/\(ref.number)\(tail)", q)
    }

    // MARK: inbox

    func inbox() async throws -> Inbox {
        let me: User = try await http.get(api("user"))
        async let r: [MR] = http.get(api("merge_requests", ["scope": "all", "state": "opened", "reviewer_id": String(me.id), "per_page": "50"]))
        async let ap: [MR] = http.get(api("merge_requests", ["scope": "all", "state": "opened", "reviewer_id": String(me.id), "approved_by_ids[]": String(me.id), "per_page": "50"]))
        async let o: [MR] = config.showOwn ? http.get(api("merge_requests", ["scope": "all", "state": "opened", "author_id": String(me.id), "per_page": "50"])) : []
        async let t: [Todo] = config.showTodos ? http.get(api("todos", ["state": "pending", "per_page": "50"])) : []
        var inbox = Inbox()
        let approvedIDs = Set(try await ap.map(\.id))
        let all = try await r
        inbox.reviews = all.filter { !approvedIDs.contains($0.id) }.map { item($0, kind: .reviewRequest) }
        inbox.approved = all.filter { approvedIDs.contains($0.id) }.map { m in
            var i = item(m, kind: .reviewRequest); i.approvedByMe = true
            if m.detailed_merge_status != "mergeable" { i.status = "approved · " + (i.status ?? ""); i.statusTone = .done }
            return i
        }
        inbox.own = try await o.map { item($0, kind: .ownMergeRequest) }
        let reviewURLs = Set(inbox.reviews.map(\.url))
        inbox.todos = try await t.filter { $0.author?.id != me.id }.compactMap(todoItem).filter { !reviewURLs.contains($0.url) }
        return inbox
    }

    private func item(_ m: MR, kind: WorkItem.Kind) -> WorkItem {
        var tone: WorkItem.Tone = .active
        var status = m.detailed_merge_status ?? "open"
        switch m.detailed_merge_status {
        case "mergeable": tone = .done
        case "ci_still_running": status = "ci running"
        case "not_approved": status = "needs approval"
        case "discussions_not_resolved": status = "threads open"; tone = .warn
        default: break
        }
        if m.draft == true { tone = .neutral; status = "draft" }
        if m.has_conflicts == true { tone = .danger; status = "conflicts" }
        return WorkItem(
            id: "gl:\(config.id):mr:\(m.id)", source: .gitlab, kind: kind,
            key: m.references?.full ?? "!\(m.iid)", title: m.title,
            subtitle: kind == .reviewRequest ? (m.author?.name ?? "") : m.source_branch,
            url: URL(string: m.web_url) ?? base, updated: Dates.parse(m.updated_at),
            status: status, statusTone: tone,
            isDraft: m.draft ?? false, hasConflicts: m.has_conflicts ?? false,
            pipeline: m.head_pipeline?.status, approvals: m.upvotes ?? 0,
            change: ChangeRef(hostID: config.id, project: String(m.project_id), number: m.iid),
            hostLabel: config.host)
    }

    private func todoItem(_ t: Todo) -> WorkItem? {
        guard let u = URL(string: t.target_url) else { return nil }
        var change: ChangeRef? = nil
        if t.target_type == "MergeRequest", let iid = t.target?.iid, let pid = t.project?.id {
            change = ChangeRef(hostID: config.id, project: String(pid), number: iid)
        }
        return WorkItem(
            id: "gl:\(config.id):todo:\(t.id)", source: .gitlab, kind: .todo,
            key: t.target?.references?.short ?? t.project?.path_with_namespace ?? "",
            title: t.target?.title ?? t.body ?? t.target_type,
            subtitle: "\(t.author?.name ?? "someone") · \(Self.verb(t.action_name))",
            url: u, updated: Dates.parse(t.created_at),
            status: Self.verb(t.action_name), statusTone: .warn, change: change, hostLabel: config.host)
    }

    private static func verb(_ a: String) -> String {
        switch a {
        case "mentioned", "directly_addressed": return "mentioned you"
        case "review_requested": return "review requested"
        case "approval_required": return "approval needed"
        case "build_failed": return "pipeline failed"
        default: return a.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: activity

    func activity(since: Date) async throws -> [Activity] {
        let me: User = try await http.get(api("user"))
        let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
        let after = day.string(from: since.addingTimeInterval(-86400))   // API `after` is exclusive by day
        let events: [Event] = try await http.get(api("users/\(me.id)/events", ["after": after, "per_page": "100"]))
        var names: [Int: String] = [:]
        func place(_ pid: Int?) async -> String {
            guard let pid else { return "" }
            if let n = names[pid] { return n }
            let p: ProjSimple? = try? await http.get(api("projects/\(pid)", ["simple": "true"]))
            let n = p?.path_with_namespace ?? ""
            names[pid] = n; return n
        }
        var out: [Activity] = []
        for e in events {
            let d = Dates.parse(e.created_at)
            guard d >= since else { continue }
            let where_ = await place(e.project_id)
            let title = e.target_title ?? ""
            let text: String
            switch (e.action_name, e.target_type ?? "") {
            case ("pushed to", _), ("pushed new", _):
                text = "pushed:\(e.push_data?.ref ?? "branch")"
            case ("opened", "MergeRequest"): text = "Opened MR \(title)"
            case ("approved", "MergeRequest"): text = "Approved \(title)"
            case ("accepted", "MergeRequest"), ("merged", "MergeRequest"): text = "Merged \(title)"
            case ("closed", "MergeRequest"): text = "Closed MR \(title)"
            case ("commented on", _): text = "Reviewed \(title)"
            case ("opened", "Issue"): text = "Opened issue \(title)"
            case ("closed", "Issue"): text = "Closed issue \(title)"
            default: continue
            }
            out.append(Activity(date: d, text: text, place: where_))
        }
        return out
    }

    private struct Event: Decodable {
        let action_name: String; let target_type: String?; let target_title: String?
        let project_id: Int?; let created_at: String?; let push_data: PushData?
    }
    private struct PushData: Decodable { let ref: String?; let commit_count: Int? }
    private struct ProjSimple: Decodable { let path_with_namespace: String }

    // MARK: detail

    func detail(_ ref: ChangeRef) async throws -> ChangeDetail {
        async let m: MRFull = http.get(mr(ref))
        async let diffs: [Diff] = http.get(mr(ref, "/diffs", ["per_page": "200"]))
        async let disc: [Discussion] = http.get(mr(ref, "/discussions", ["per_page": "100"]))
        async let appr: Approvals = http.get(mr(ref, "/approvals"))
        async let me: User = http.get(api("user"))
        async let cms: [GLCommit] = http.get(mr(ref, "/commits", ["per_page": "100"]))
        let (mrv, dv, discv, ap, mev, cmv) = try await (m, diffs, disc, appr, me, cms)
        let commits = cmv.map { CommitInfo(id: $0.id, short: $0.short_id, title: $0.title, author: $0.author_name ?? "",
                                           date: Dates.parse($0.created_at), url: $0.web_url.flatMap(URL.init)) }

        let files = dv.map(Self.fileDiff)
        let threads = discv.compactMap { d -> ReviewThread? in
            let notes = d.notes.filter { !$0.system }
            guard let first = notes.first else { return nil }
            var anchor: LineAnchor? = nil
            if let p = first.position, p.position_type == "text" {
                anchor = LineAnchor(path: p.new_path ?? p.old_path ?? "", oldLine: p.old_line, newLine: p.new_line)
            }
            return ReviewThread(id: d.id, anchor: anchor,
                                resolved: notes.first?.resolved ?? false, resolvable: notes.first?.resolvable ?? false,
                                comments: notes.map { Comment(id: String($0.id), author: $0.author.name, body: $0.body, created: Dates.parse($0.created_at)) })
        }
        let approvers = ap.approved_by?.map { $0.user.name } ?? []
        return ChangeDetail(
            ref: ref, title: mrv.title, description: mrv.description ?? "", author: mrv.author?.name ?? "",
            sourceBranch: mrv.source_branch, targetBranch: mrv.target_branch,
            url: URL(string: mrv.web_url) ?? base, state: mrv.state == "opened" ? (mrv.detailed_merge_status ?? mrv.state) : mrv.state,
            isOpen: mrv.state == "opened",
            draft: mrv.draft ?? false,
            approvedByMe: ap.approved_by?.contains { $0.user.id == mev.id } ?? false,
            approvals: approvers, mergeable: mrv.detailed_merge_status == "mergeable",
            pipeline: mrv.head_pipeline?.status, files: files, threads: threads, commits: commits,
            baseSHA: mrv.diff_refs?.base_sha ?? "", startSHA: mrv.diff_refs?.start_sha ?? "", headSHA: mrv.diff_refs?.head_sha ?? "")
    }

    func commitDiff(_ ref: ChangeRef, sha: String) async throws -> [FileDiff] {
        let dv: [Diff] = try await http.get(api("projects/\(ref.project)/repository/commits/\(sha)/diff", ["per_page": "200"]))
        return dv.map(Self.fileDiff)
    }

    fileprivate static func fileDiff(_ d: Diff) -> FileDiff {
        let hunks = DiffParser.parse(d.diff)
        let (a, del) = DiffParser.counts(hunks)
        let st: FileDiff.Status = d.new_file ? .added : d.deleted_file ? .deleted : d.renamed_file ? .renamed : .modified
        return FileDiff(oldPath: d.old_path, newPath: d.new_path, status: st, hunks: hunks, additions: a, deletions: del,
                        binary: d.diff.isEmpty && !d.new_file && !d.deleted_file)
    }

    // MARK: actions

    func comment(_ ref: ChangeRef, at anchor: LineAnchor?, body: String, detail: ChangeDetail) async throws {
        var form: [String: String] = ["body": body]
        if let a = anchor {
            form["position[position_type]"] = "text"
            form["position[base_sha]"] = detail.baseSHA
            form["position[start_sha]"] = detail.startSHA
            form["position[head_sha]"] = detail.headSHA
            let f = detail.files.first { $0.newPath == a.path }
            form["position[new_path]"] = a.path
            form["position[old_path]"] = f?.oldPath ?? a.path
            if let n = a.newLine { form["position[new_line]"] = String(n) }
            if let o = a.oldLine { form["position[old_line]"] = String(o) }
        }
        _ = try await http.send("POST", mr(ref, "/discussions"), form: form)
    }

    func reply(_ ref: ChangeRef, thread: ReviewThread, body: String) async throws {
        _ = try await http.send("POST", mr(ref, "/discussions/\(thread.id)/notes"), form: ["body": body])
    }

    func resolve(_ ref: ChangeRef, thread: ReviewThread, resolved: Bool) async throws {
        _ = try await http.send("PUT", mr(ref, "/discussions/\(thread.id)"), form: ["resolved": resolved ? "true" : "false"])
    }

    func approve(_ ref: ChangeRef, approve: Bool) async throws {
        do { _ = try await http.send("POST", mr(ref, approve ? "/approve" : "/unapprove")) }
        catch let e as APIError where e.message.contains("HTTP 401") {
            // GitLab answers 401 for "can't approve": already merged/closed, own MR, or approvals disabled.
            let m: MRFull? = try? await http.get(mr(ref))
            if let st = m?.state, st != "opened" { throw APIError(message: "MR is already \(st)") }
            throw APIError(message: "GitLab refused the approval (own MR, approvals disabled, or token lacks `api` scope)")
        }
    }

    func merge(_ ref: ChangeRef) async throws {
        _ = try await http.send("PUT", mr(ref, "/merge"))
    }

    // MARK: wire types

    private struct User: Decodable { let id: Int; let name: String? }
    private struct MR: Decodable {
        let id: Int; let iid: Int; let project_id: Int; let title: String; let web_url: String
        let updated_at: String?; let source_branch: String
        let draft: Bool?; let has_conflicts: Bool?; let detailed_merge_status: String?; let upvotes: Int?
        let author: Person?; let references: Refs?; let head_pipeline: Pipeline?
    }
    private struct MRFull: Decodable {
        let title: String; let description: String?; let state: String; let web_url: String
        let source_branch: String; let target_branch: String; let draft: Bool?
        let detailed_merge_status: String?; let author: Person?; let head_pipeline: Pipeline?; let diff_refs: DiffRefs?
    }
    private struct DiffRefs: Decodable { let base_sha: String?; let head_sha: String?; let start_sha: String? }
    private struct Person: Decodable { let id: Int?; let name: String }
    private struct Refs: Decodable { let short: String?; let full: String? }
    private struct Pipeline: Decodable { let status: String }
    private struct GLCommit: Decodable {
        let id: String; let short_id: String; let title: String; let author_name: String?; let created_at: String?; let web_url: String?
    }
    fileprivate struct Diff: Decodable {
        let old_path: String; let new_path: String; let diff: String
        let new_file: Bool; let renamed_file: Bool; let deleted_file: Bool
    }
    private struct Discussion: Decodable { let id: String; let notes: [Note] }
    private struct Note: Decodable {
        let id: Int; let body: String; let author: Person; let created_at: String?
        let system: Bool; let resolvable: Bool?; let resolved: Bool?; let position: Position?
    }
    private struct Position: Decodable { let position_type: String?; let new_path: String?; let old_path: String?; let new_line: Int?; let old_line: Int? }
    private struct Approvals: Decodable { let approved_by: [ApprovedBy]? }
    private struct ApprovedBy: Decodable { let user: Person }
    private struct Todo: Decodable {
        let id: Int; let action_name: String; let target_type: String; let target_url: String
        let body: String?; let created_at: String?
        let author: Person?; let project: Proj?; let target: Target?
    }
    private struct Proj: Decodable { let id: Int; let path_with_namespace: String }
    private struct Target: Decodable { let iid: Int?; let title: String?; let references: Refs? }
}
