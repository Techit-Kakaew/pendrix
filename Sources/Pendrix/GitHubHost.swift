import Foundation

/// GitHub REST + a little GraphQL (review threads / resolve have no REST surface).
/// Token: classic `repo` or fine-grained with Pull requests: read & write.
struct GitHubHost: CodeHost {
    let config: HostConfig
    let base: URL          // https://github.com or GHES root
    let token: String

    private var api: URL {
        base.host == "github.com" ? URL(string: "https://api.github.com")! : base.appendingPathComponent("api/v3")
    }
    private var graphql: URL {
        base.host == "github.com" ? URL(string: "https://api.github.com/graphql")! : base.appendingPathComponent("api/graphql")
    }
    private var http: HTTP {
        HTTP(headers: ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"])
    }
    private func repo(_ ref: ChangeRef, _ tail: String) -> URL { url(api, "repos/\(ref.project)\(tail)") }

    // MARK: inbox

    func inbox() async throws -> Inbox {
        async let r: Search = http.get(url(api, "search/issues", ["q": "is:pr is:open review-requested:@me archived:false", "per_page": "50", "sort": "updated"]))
        async let ap: Search = http.get(url(api, "search/issues", ["q": "is:pr is:open reviewed-by:@me -author:@me -review-requested:@me archived:false", "per_page": "50", "sort": "updated"]))
        async let o: Search = config.showOwn ? http.get(url(api, "search/issues", ["q": "is:pr is:open author:@me archived:false", "per_page": "50", "sort": "updated"])) : Search(items: [])
        async let t: Search = config.showTodos ? http.get(url(api, "search/issues", ["q": "is:open mentions:@me -author:@me -review-requested:@me archived:false", "per_page": "30", "sort": "updated"])) : Search(items: [])
        var inbox = Inbox()
        inbox.reviews = try await r.items.map { item($0, kind: .reviewRequest) }
        inbox.approved = try await ap.items.map { i in var w = item(i, kind: .reviewRequest); w.approvedByMe = true; w.status = "reviewed"; w.statusTone = .done; return w }
        inbox.own = try await o.items.map { item($0, kind: .ownMergeRequest) }
        inbox.todos = try await t.items.map { item($0, kind: .todo) }
        return inbox
    }

    private func item(_ i: Issue, kind: WorkItem.Kind) -> WorkItem {
        let repoPath = i.repository_url.split(separator: "/").suffix(2).joined(separator: "/")
        let isPR = i.pull_request != nil
        return WorkItem(
            id: "gh:\(config.id):\(i.id)", source: .gitlab, kind: kind,
            key: "\(repoPath)#\(i.number)", title: i.title,
            subtitle: kind == .todo ? "\(i.user?.login ?? "") · mentioned you" : (i.user?.login ?? ""),
            url: URL(string: i.html_url) ?? base, updated: Dates.parse(i.updated_at),
            status: i.draft == true ? "draft" : (kind == .todo ? "mentioned you" : "open"),
            statusTone: kind == .todo ? .warn : (i.draft == true ? .neutral : .active),
            isDraft: i.draft ?? false,
            change: isPR ? ChangeRef(hostID: config.id, project: repoPath, number: i.number) : nil,
            hostLabel: config.host)
    }

    // MARK: activity

    func activity(since: Date) async throws -> [Activity] {
        let me: GHUser = try await http.get(url(api, "user"))
        let events: [GHEvent] = try await http.get(url(api, "users/\(me.login)/events", ["per_page": "100"]))
        var out: [Activity] = []
        for e in events {
            let d = Dates.parse(e.created_at)
            guard d >= since else { continue }
            let repo = e.repo?.name ?? ""
            let p = e.payload
            let pr = p?.pull_request
            let title = pr.map { "#\($0.number) \($0.title)" } ?? ""
            let text: String
            switch e.type {
            case "PushEvent": text = "pushed:\((p?.ref ?? "").replacingOccurrences(of: "refs/heads/", with: ""))"
            case "PullRequestEvent":
                switch p?.action {
                case "opened": text = "Opened PR \(title)"
                case "closed": text = (pr?.merged == true ? "Merged " : "Closed PR ") + title
                case "reopened": text = "Reopened PR \(title)"
                default: continue
                }
            case "PullRequestReviewEvent":
                text = (p?.review?.state == "approved" ? "Approved " : "Reviewed ") + title
            case "PullRequestReviewCommentEvent": text = "Reviewed \(title)"
            case "IssueCommentEvent": text = "Commented on #\(p?.issue?.number ?? 0) \(p?.issue?.title ?? "")"
            case "IssuesEvent" where p?.action == "closed": text = "Closed issue #\(p?.issue?.number ?? 0) \(p?.issue?.title ?? "")"
            default: continue
            }
            out.append(Activity(date: d, text: text, place: repo))
        }
        return out
    }

    private struct GHEvent: Decodable { let type: String; let created_at: String?; let repo: GHRepoRef?; let payload: GHPayload? }
    private struct GHRepoRef: Decodable { let name: String }
    private struct GHPayload: Decodable {
        let action: String?; let ref: String?; let pull_request: GHPRRef?; let review: GHReviewRef?; let issue: GHIssueRef?
    }
    private struct GHPRRef: Decodable { let number: Int; let title: String; let merged: Bool? }
    private struct GHReviewRef: Decodable { let state: String? }
    private struct GHIssueRef: Decodable { let number: Int; let title: String }

    // MARK: detail

    func detail(_ ref: ChangeRef) async throws -> ChangeDetail {
        let (owner, name) = split(ref.project)
        async let pr: PR = http.get(repo(ref, "/pulls/\(ref.number)"))
        async let files: [PRFile] = http.get(url(api, "repos/\(ref.project)/pulls/\(ref.number)/files", ["per_page": "100"]))
        async let reviews: [Review] = http.get(url(api, "repos/\(ref.project)/pulls/\(ref.number)/reviews", ["per_page": "100"]))
        async let issueComments: [IssueComment] = http.get(url(api, "repos/\(ref.project)/issues/\(ref.number)/comments", ["per_page": "100"]))
        async let me: GHUser = http.get(url(api, "user"))
        async let gql: GQLResponse = threads(owner: owner, name: name, number: ref.number)
        async let cms: [GHCommit] = http.get(url(api, "repos/\(ref.project)/pulls/\(ref.number)/commits", ["per_page": "100"]))
        let (p, fv, rv, ic, mev, g, cmv) = try await (pr, files, reviews, issueComments, me, gql, cms)
        let commits = cmv.map { c in
            CommitInfo(id: c.sha, short: String(c.sha.prefix(8)),
                       title: c.commit.message.split(separator: "\n").first.map(String.init) ?? c.commit.message,
                       author: c.author?.login ?? c.commit.author?.name ?? "", date: Dates.parse(c.commit.author?.date),
                       url: URL(string: c.html_url))
        }

        let fileDiffs = fv.map(Self.fileDiff)
        var threads: [ReviewThread] = g.data.repository.pullRequest.reviewThreads.nodes.compactMap { t in
            let cs = t.comments.nodes
            guard let first = cs.first else { return nil }
            let anchor = LineAnchor(path: t.path, oldLine: t.diffSide == "LEFT" ? t.line : nil, newLine: t.diffSide == "LEFT" ? nil : t.line)
            return ReviewThread(id: t.id, anchor: anchor, resolved: t.isResolved, resolvable: true,
                                comments: cs.map { Comment(id: $0.id, author: $0.author?.login ?? "", body: $0.body, created: Dates.parse($0.createdAt)) },
                                replyHandle: first.databaseId.map(String.init))
        }
        // Conversation-tab comments become unanchored threads (not resolvable).
        threads += ic.map { c in
            ReviewThread(id: "issue:\(c.id)", anchor: nil, resolved: false, resolvable: false,
                         comments: [Comment(id: String(c.id), author: c.user?.login ?? "", body: c.body, created: Dates.parse(c.created_at))])
        }
        // Latest review state per user decides approval.
        var latest: [String: String] = [:]
        for r in rv.sorted(by: { ($0.submitted_at ?? "") < ($1.submitted_at ?? "") }) where r.state != "COMMENTED" {
            latest[r.user?.login ?? "?"] = r.state
        }
        let approvers = latest.filter { $0.value == "APPROVED" }.map(\.key).sorted()
        return ChangeDetail(
            ref: ref, title: p.title, description: p.body ?? "", author: p.user?.login ?? "",
            sourceBranch: p.head.ref, targetBranch: p.base.ref, url: URL(string: p.html_url) ?? base,
            state: p.mergeable_state ?? p.state, draft: p.draft ?? false,
            approvedByMe: latest[mev.login] == "APPROVED", approvals: approvers,
            mergeable: p.mergeable == true && p.mergeable_state == "clean",
            pipeline: nil, files: fileDiffs, threads: threads, commits: commits,
            baseSHA: p.base.sha, startSHA: p.base.sha, headSHA: p.head.sha)
    }

    func commitDiff(_ ref: ChangeRef, sha: String) async throws -> [FileDiff] {
        let c: GHCommitDetail = try await http.get(repo(ref, "/commits/\(sha)"))
        return (c.files ?? []).map(Self.fileDiff)
    }

    fileprivate static func fileDiff(_ f: PRFile) -> FileDiff {
        let hunks = DiffParser.parse(f.patch ?? "")
        let st: FileDiff.Status = switch f.status { case "added": .added; case "removed": .deleted; case "renamed": .renamed; default: .modified }
        return FileDiff(oldPath: f.previous_filename ?? f.filename, newPath: f.filename, status: st, hunks: hunks,
                        additions: f.additions, deletions: f.deletions, binary: f.patch == nil)
    }

    private func threads(owner: String, name: String, number: Int) async throws -> GQLResponse {
        let q = """
        query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){ pullRequest(number:$num){
          reviewThreads(first:100){ nodes{ id isResolved path line diffSide
            comments(first:50){ nodes{ id databaseId body createdAt author{login} } } } } } } }
        """
        let data = try await http.send("POST", graphql, json: ["query": q, "variables": ["o": owner, "n": name, "num": number]])
        return try JSONDecoder().decode(GQLResponse.self, from: data)
    }

    // MARK: actions

    func comment(_ ref: ChangeRef, at anchor: LineAnchor?, body: String, detail: ChangeDetail) async throws {
        if let a = anchor {
            var j: [String: Any] = ["body": body, "commit_id": detail.headSHA, "path": a.path]
            if let n = a.newLine { j["line"] = n; j["side"] = "RIGHT" } else if let o = a.oldLine { j["line"] = o; j["side"] = "LEFT" }
            _ = try await http.send("POST", repo(ref, "/pulls/\(ref.number)/comments"), json: j)
        } else {
            _ = try await http.send("POST", repo(ref, "/issues/\(ref.number)/comments"), json: ["body": body])
        }
    }

    func reply(_ ref: ChangeRef, thread: ReviewThread, body: String) async throws {
        if let h = thread.replyHandle {
            _ = try await http.send("POST", repo(ref, "/pulls/\(ref.number)/comments/\(h)/replies"), json: ["body": body])
        } else {
            _ = try await http.send("POST", repo(ref, "/issues/\(ref.number)/comments"), json: ["body": body])
        }
    }

    func resolve(_ ref: ChangeRef, thread: ReviewThread, resolved: Bool) async throws {
        let m = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let q = "mutation($id:ID!){ \(m)(input:{threadId:$id}){ thread{ id } } }"
        _ = try await http.send("POST", graphql, json: ["query": q, "variables": ["id": thread.id]])
    }

    func approve(_ ref: ChangeRef, approve: Bool) async throws {
        guard approve else { throw APIError(message: "GitHub has no un-approve; dismiss the review on the web") }
        _ = try await http.send("POST", repo(ref, "/pulls/\(ref.number)/reviews"), json: ["event": "APPROVE"])
    }

    func merge(_ ref: ChangeRef) async throws {
        _ = try await http.send("PUT", repo(ref, "/pulls/\(ref.number)/merge"), json: [:] as [String: String])
    }

    private func split(_ p: String) -> (String, String) {
        let parts = p.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    // MARK: wire types

    private struct Search: Decodable { let items: [Issue] }
    private struct Issue: Decodable {
        let id: Int; let number: Int; let title: String; let html_url: String; let repository_url: String
        let updated_at: String?; let draft: Bool?; let user: GHUser?; let pull_request: PRLink?
    }
    private struct PRLink: Decodable {}
    private struct GHUser: Decodable { let login: String }
    private struct PR: Decodable {
        let title: String; let body: String?; let state: String; let html_url: String; let draft: Bool?
        let mergeable: Bool?; let mergeable_state: String?; let user: GHUser?; let head: Ref; let base: Ref
    }
    private struct Ref: Decodable { let ref: String; let sha: String }
    private struct GHCommit: Decodable { let sha: String; let html_url: String; let commit: GHCommitBody; let author: GHUser? }
    private struct GHCommitBody: Decodable { let message: String; let author: GHCommitAuthor? }
    private struct GHCommitAuthor: Decodable { let name: String?; let date: String? }
    private struct GHCommitDetail: Decodable { let files: [PRFile]? }
    fileprivate struct PRFile: Decodable {
        let filename: String; let status: String; let additions: Int; let deletions: Int
        let patch: String?; let previous_filename: String?
    }
    private struct Review: Decodable { let state: String; let user: GHUser?; let submitted_at: String? }
    private struct IssueComment: Decodable { let id: Int; let body: String; let user: GHUser?; let created_at: String? }
    private struct GQLResponse: Decodable { let data: GData }
    private struct GData: Decodable { let repository: GRepo }
    private struct GRepo: Decodable { let pullRequest: GPR }
    private struct GPR: Decodable { let reviewThreads: GNodes<GThread> }
    private struct GNodes<T: Decodable>: Decodable { let nodes: [T] }
    private struct GThread: Decodable {
        let id: String; let isResolved: Bool; let path: String; let line: Int?; let diffSide: String?
        let comments: GNodes<GComment>
    }
    private struct GComment: Decodable { let id: String; let databaseId: Int?; let body: String; let createdAt: String?; let author: GHUser? }
}
