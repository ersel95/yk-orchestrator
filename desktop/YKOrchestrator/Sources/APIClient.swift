import Foundation

/// Sidecar (Python FastAPI) ile native HTTP istemcisi.
/// Tüm endpoint'ler typed methodlar halinde. SSE stream desteği var.
///
/// Kullanım:
///   let client = APIClient(baseURL: sidecar.apiBaseURL!)
///   let prs = try await client.listForReview(projectId: 1)
@MainActor
final class APIClient {

    let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600   // PR diff vs. uzun olabilir
        self.session = URLSession(configuration: cfg)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        self.decoder = d
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
    }

    // MARK: - Core HTTP

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        let url = makeURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        try Self.checkResponse(resp, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let url = makeURL(path: path, query: [:])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, resp) = try await session.data(for: req)
        try Self.checkResponse(resp, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func postVoid<Body: Encodable>(_ path: String, body: Body) async throws {
        let url = makeURL(path: path, query: [:])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, resp) = try await session.data(for: req)
        try Self.checkResponse(resp, data: data)
    }

    func patch<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let url = makeURL(path: path, query: [:])
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, resp) = try await session.data(for: req)
        try Self.checkResponse(resp, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func delete(_ path: String, query: [String: String?] = [:]) async throws {
        let url = makeURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (data, resp) = try await session.data(for: req)
        try Self.checkResponse(resp, data: data)
    }

    // MARK: - SSE stream

    /// SSE event'lerini AsyncThrowingStream olarak verir. Her event'in `event` ve `data`'sı.
    func sseStream(path: String, query: [String: String?] = [:]) -> AsyncThrowingStream<SSEEvent, Error> {
        let url = makeURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 600

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    try Self.checkResponse(resp, data: Data())
                    var currentEvent = "message"
                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Event boundary
                            if !dataBuffer.isEmpty {
                                continuation.yield(SSEEvent(event: currentEvent, data: dataBuffer))
                            }
                            currentEvent = "message"
                            dataBuffer = ""
                            continue
                        }
                        if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst(6))
                                .trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = String(line.dropFirst(5))
                                .trimmingCharacters(in: .whitespaces)
                            if !dataBuffer.isEmpty { dataBuffer.append("\n") }
                            dataBuffer.append(chunk)
                        }
                    }
                    if !dataBuffer.isEmpty {
                        continuation.yield(SSEEvent(event: currentEvent, data: dataBuffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct SSEEvent: Sendable {
        let event: String
        let data: String
    }

    // MARK: - URL helpers

    private func makeURL(path: String, query: [String: String?]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        let items = query.compactMap { k, v -> URLQueryItem? in
            guard let v else { return nil }
            return URLQueryItem(name: k, value: v)
        }
        if !items.isEmpty { comps.queryItems = items }
        return comps.url!
    }

    private static func checkResponse(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: http.statusCode, body: body)
        }
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case httpError(status: Int, body: String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Geçersiz yanıt"
            case .httpError(let s, let b): return "HTTP \(s) — \(b.prefix(200))"
            }
        }
    }
}

// MARK: - Health

extension APIClient {
    struct Health: Decodable {
        let ok: Bool
        let llm: Bool
        let jira: Bool
        let bitbucket: Bool
    }
    func health() async throws -> Health { try await get("health") }
}

// MARK: - Projects

extension APIClient {
    struct ProjectInfo: Codable, Identifiable, Hashable {
        let id: Int
        let name: String
        let slug: String
        let color: String?
        let jira_project_keys: String
        let bitbucket_workspace: String
        let bitbucket_repo: String
        let local_repo_path: String
        let git_default_branch: String
        let fastlane_project_dir: String
        let fastlane_lane: String
        // Xcode / TestFlight (geriye-uyumlu: eski backend döndürmezse nil)
        let xcode_container_path: String?
        let xcode_scheme: String?
        let xcode_configuration: String?
        let xcode_bundle_id: String?
        let xcode_team_id: String?
        let xcode_environments: String?
        let is_archived: Bool
        let sort_order: Int
    }
    struct ProjectListResponse: Decodable {
        let projects: [ProjectInfo]
        let active_id: Int?
    }

    /// PATCH body — yalnızca dolu (non-nil) alanlar JSON'a girer (Codable encodeIfPresent),
    /// backend `model_dump(exclude_unset=True)` ile uyumlu.
    struct ProjectPatchBody: Encodable {
        var name: String?
        var slug: String?
        var jira_project_keys: String?
        var bitbucket_workspace: String?
        var bitbucket_repo: String?
        var local_repo_path: String?
        var git_default_branch: String?
        var fastlane_project_dir: String?
        var fastlane_lane: String?
        var xcode_container_path: String?
        var xcode_scheme: String?
        var xcode_configuration: String?
        var xcode_bundle_id: String?
        var xcode_team_id: String?
        var xcode_environments: String?
    }

    func listProjects() async throws -> ProjectListResponse {
        try await get("api/projects")
    }
    func activateProject(id: Int) async throws {
        struct Empty: Encodable {}
        try await postVoid("api/projects/\(id)/activate", body: Empty())
    }
    @discardableResult
    func patchProject(id: Int, _ body: ProjectPatchBody) async throws -> ProjectInfo {
        try await patch("api/projects/\(id)", body: body)
    }
    func createProject(name: String, slug: String) async throws -> ProjectInfo {
        struct Body: Encodable { let name: String; let slug: String }
        return try await post("api/projects", body: Body(name: name, slug: slug))
    }
}

// MARK: - Pull Requests

extension APIClient {

    struct PullRequest: Decodable, Identifiable, Hashable {
        let pr_id: String
        let repo: String
        let number: Int
        let title: String
        let description: String?
        let author: String
        let source_branch: String
        let target_branch: String
        let state: String                 // OPEN | MERGED | DECLINED
        let is_mine: Bool
        let needs_my_review: Bool
        let has_my_unread_comment: Bool
        let url: String
        let diff_summary: String?
        let status: String?               // APPROVED | NEEDS_WORK | UNAPPROVED (aggregate)
        let my_status: String?
        let reviewers: [Reviewer]?
        var id: String { pr_id }

        struct Reviewer: Decodable, Hashable {
            let username: String?
            let display_name: String?
            let status: String?
        }
    }

    func listForReview(projectId: Int?) async throws -> [PullRequest] {
        try await get("api/pr/review", query: ["project_id": projectId.map(String.init)])
    }
    func cachedPRs(projectId: Int?) async throws -> [PullRequest] {
        try await get("api/pr/cache", query: ["project_id": projectId.map(String.init)])
    }

    // Summary stream (SSE)
    func prSummaryStream(repo: String, number: Int, projectId: Int?)
        -> AsyncThrowingStream<SSEEvent, Error>
    {
        sseStream(
            path: "api/pr/review/\(repo)/\(number)/summary/stream",
            query: ["project_id": projectId.map(String.init)]
        )
    }

    // Diff dosya listesi
    struct ChangedFile: Decodable, Identifiable, Hashable {
        let path: String
        let type: String?           // ADD | MODIFY | DELETE | RENAME
        let additions: Int?
        let deletions: Int?
        var id: String { path }
    }
    func prChangedFiles(repo: String, number: Int, projectId: Int?) async throws -> [ChangedFile] {
        try await get("api/pr/review/\(repo)/\(number)/changes",
                      query: ["project_id": projectId.map(String.init)])
    }

    struct FileDiff: Decodable {
        let path: String
        let diff: String
    }
    func prFileDiff(repo: String, number: Int, path: String, projectId: Int?, contextLines: Int = 10) async throws -> FileDiff {
        try await get(
            "api/pr/review/\(repo)/\(number)/file-diff",
            query: [
                "path": path,
                "project_id": projectId.map(String.init),
                "context_lines": String(contextLines),
            ]
        )
    }

    struct PRComment: Decodable, Identifiable, Hashable {
        let id: Int
        let version: Int?
        let text: String
        let author: String?
        let created_at: String?
        let anchor: PRAnchor?
        let mine: Bool?
        struct PRAnchor: Decodable, Hashable {
            let path: String?
            let line: Int?
            let lineType: String?
        }
    }
    func prFileComments(repo: String, number: Int, path: String, projectId: Int?) async throws -> [PRComment] {
        try await get(
            "api/pr/review/\(repo)/\(number)/file-comments",
            query: ["path": path, "project_id": projectId.map(String.init)]
        )
    }
    func prAddComment(repo: String, number: Int, text: String, anchor: [String: String]?, projectId: Int?) async throws {
        struct Body: Encodable {
            let text: String
            let project_id: Int?
            let anchor: [String: String]?
        }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            "api/pr/review/\(repo)/\(number)/comment",
            body: Body(text: text, project_id: projectId, anchor: anchor)
        )
    }
    func prUpdateComment(repo: String, number: Int, commentId: Int, text: String, version: Int, projectId: Int?) async throws {
        struct Body: Encodable {
            let text: String
            let version: Int
            let project_id: Int?
        }
        struct Empty: Decodable {}
        let _: Empty = try await patch(
            "api/pr/review/\(repo)/\(number)/comment/\(commentId)",
            body: Body(text: text, version: version, project_id: projectId)
        )
    }
    func prDeleteComment(repo: String, number: Int, commentId: Int, version: Int, projectId: Int?) async throws {
        try await delete(
            "api/pr/review/\(repo)/\(number)/comment/\(commentId)",
            query: ["version": String(version), "project_id": projectId.map(String.init)]
        )
    }

    // PR status set
    enum PRReviewStatus: String, Codable {
        case approved = "APPROVED"
        case needsWork = "NEEDS_WORK"
        case unapproved = "UNAPPROVED"
    }
    func prSetStatus(repo: String, number: Int, status: PRReviewStatus, projectId: Int?) async throws {
        struct Body: Encodable {
            let status: String
            let project_id: Int?
        }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            "api/pr/review/\(repo)/\(number)/status",
            body: Body(status: status.rawValue, project_id: projectId)
        )
    }

    // AI inline yorum önerileri
    struct AISuggestion: Codable, Identifiable, Hashable {
        let id: String?
        let path: String?
        let line: Int?
        let category: String?
        let severity: String?
        let comment: String
        var sid: String { id ?? "\(path ?? "")_\(line ?? 0)_\(comment.prefix(20))" }
        var swiftID: String { sid }
    }
    struct AISuggestionsResponse: Decodable {
        let suggestions: [AISuggestion]
    }
    func prAISuggestions(repo: String, number: Int, projectId: Int?) async throws -> AISuggestionsResponse {
        struct Empty: Encodable { let project_id: Int? }
        return try await post(
            "api/pr/review/\(repo)/\(number)/ai-suggestions",
            body: Empty(project_id: projectId)
        )
    }
    func prPostSuggestions(repo: String, number: Int, suggestions: [AISuggestion], projectId: Int?) async throws {
        struct Body: Encodable {
            let suggestions: [AISuggestion]
            let project_id: Int?
        }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            "api/pr/review/\(repo)/\(number)/ai-suggestions/post",
            body: Body(suggestions: suggestions, project_id: projectId)
        )
    }
}

// MARK: - Chat

extension APIClient {
    struct ChatRequest: Encodable {
        let q: String
        let thread_id: Int?
        let project_id: Int?
    }
    struct ChatResponse: Decodable {
        let answer: String
        let thread_id: Int?
    }
    func chatAsk(question: String, threadId: Int? = nil, projectId: Int?) async throws -> ChatResponse {
        try await post("api/chat/ask", body: ChatRequest(q: question, thread_id: threadId, project_id: projectId))
    }
    func chatStream(question: String, threadId: Int? = nil, projectId: Int?) -> AsyncThrowingStream<SSEEvent, Error> {
        sseStream(
            path: "api/chat/stream",
            query: [
                "q": question,
                "thread_id": threadId.map(String.init),
                "project_id": projectId.map(String.init),
            ]
        )
    }
}

// MARK: - TestFlight

extension APIClient {
    struct TestFlightStatus: Decodable {
        let latest_build: String?
        let last_upload_at: String?
        let last_status: String?
    }
    func testFlightStatus(projectId: Int?) async throws -> TestFlightStatus {
        try await get("api/testflight/status", query: ["project_id": projectId.map(String.init)])
    }
    struct UploadResponse: Decodable {
        let ok: Bool
        let job_id: String?
        let error: String?
    }
    func testFlightUpload(projectId: Int?) async throws -> UploadResponse {
        struct Body: Encodable { let project_id: Int? }
        return try await post("api/testflight/upload", body: Body(project_id: projectId))
    }
    /// SSE stream — fastlane çıktısı satır satır
    func streamChannel(_ channel: String) -> AsyncThrowingStream<SSEEvent, Error> {
        sseStream(path: "api/stream/\(channel)")
    }
}

// MARK: - Action log (v1.0)

extension APIClient {
    struct ActionEntry: Decodable, Identifiable, Hashable {
        let id: Int
        let project_id: Int?
        let created_at: String
        let actor: String
        let action_type: String
        let target_kind: String?
        let target_id: String?
        let outcome: String
        let error: String?
        let duration_ms: Int?
        let user_note: String?
        let payload: [String: JSONValue]?

        /// JSON ortamında bilinmeyen tip içerebilir; primitive sarmalayıcı
        enum JSONValue: Codable, Hashable {
            case string(String), int(Int), double(Double), bool(Bool)
            case array([JSONValue]), object([String: JSONValue]), null
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if c.decodeNil() { self = .null; return }
                if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
                if let v = try? c.decode(Int.self)    { self = .int(v); return }
                if let v = try? c.decode(Double.self) { self = .double(v); return }
                if let v = try? c.decode(String.self) { self = .string(v); return }
                if let v = try? c.decode([JSONValue].self)        { self = .array(v); return }
                if let v = try? c.decode([String: JSONValue].self){ self = .object(v); return }
                self = .null
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .null:           try c.encodeNil()
                case .string(let v):  try c.encode(v)
                case .int(let v):     try c.encode(v)
                case .double(let v):  try c.encode(v)
                case .bool(let v):    try c.encode(v)
                case .array(let v):   try c.encode(v)
                case .object(let v):  try c.encode(v)
                }
            }
            var stringValue: String? {
                if case .string(let s) = self { return s }
                if case .int(let i) = self { return String(i) }
                if case .bool(let b) = self { return String(b) }
                return nil
            }
        }
    }

    func listActions(
        projectId: Int?,
        actionType: String? = nil,
        targetKind: String? = nil,
        targetId: String? = nil,
        actor: String? = nil,
        sinceHours: Int? = nil,
        onlyFailures: Bool = false,
        limit: Int = 200
    ) async throws -> [ActionEntry] {
        var q: [String: String?] = [
            "project_id": projectId.map(String.init),
            "limit": String(limit),
        ]
        if let a = actionType { q["action_type"] = a }
        if let k = targetKind { q["target_kind"] = k }
        if let t = targetId   { q["target_id"]   = t }
        if let a = actor      { q["actor"] = a }
        if let h = sinceHours { q["since_hours"] = String(h) }
        if onlyFailures       { q["only_failures"] = "true" }
        return try await get("api/actions", query: q)
    }

    func actionsForTarget(kind: String, id: String) async throws -> [ActionEntry] {
        try await get("api/actions/by-target", query: ["target_kind": kind, "target_id": id])
    }

    struct ActionStats: Decodable {
        let total: Int
        let failures: Int
        let by_type: [String: Int]
        let since_hours: Int
    }
    func actionStats(projectId: Int?, sinceHours: Int = 24) async throws -> ActionStats {
        try await get("api/actions/stats",
                      query: ["project_id": projectId.map(String.init),
                              "since_hours": String(sinceHours)])
    }
}

// MARK: - Claude agent (v1.5)

extension APIClient {
    struct AgentPlanResult: Decodable {
        let ok: Bool
        let plan: String
        let cost_usd: Double?
        let duration_ms: Int?
        let repo: String?
        let jira_summary: String?
    }
    func agentPlan(jiraKey: String, projectId: Int?) async throws -> AgentPlanResult {
        struct B: Encodable { let jira_key: String; let project_id: Int? }
        return try await post("api/agent/plan", body: B(jira_key: jiraKey, project_id: projectId))
    }

    struct AgentPrepareResult: Decodable {
        let ok: Bool
        let branch: String?
        let repo_path: String?
    }
    func agentPrepare(jiraKey: String, branchName: String, sourceBranch: String = "develop", projectId: Int?) async throws -> AgentPrepareResult {
        struct B: Encodable {
            let jira_key: String
            let branch_name: String
            let source_branch: String
            let project_id: Int?
        }
        return try await post("api/agent/prepare",
                              body: B(jira_key: jiraKey, branch_name: branchName,
                                      source_branch: sourceBranch, project_id: projectId))
    }

    struct AgentCodeResult: Decodable {
        let ok: Bool
        let report: String
        let cost_usd: Double?
    }
    func agentCode(jiraKey: String, plan: String, projectId: Int?) async throws -> AgentCodeResult {
        struct B: Encodable { let jira_key: String; let plan: String; let project_id: Int? }
        return try await post("api/agent/code",
                              body: B(jira_key: jiraKey, plan: plan, project_id: projectId))
    }

    struct AgentDiffResult: Decodable {
        let ok: Bool
        let status: String
        let diff: String
        let diff_truncated: Bool?
    }
    func agentDiff(projectId: Int?) async throws -> AgentDiffResult {
        try await get("api/agent/diff", query: ["project_id": projectId.map(String.init)])
    }

    struct AgentCommitResult: Decodable {
        let ok: Bool
        let pushed: Bool
    }
    func agentCommit(message: String, push: Bool = true, projectId: Int?) async throws -> AgentCommitResult {
        struct B: Encodable { let message: String; let push: Bool; let project_id: Int? }
        return try await post("api/agent/commit",
                              body: B(message: message, push: push, project_id: projectId))
    }
}

// MARK: - Bitbucket (v1.2 — branch/commit/tag)

extension APIClient {

    struct BBBranch: Decodable, Identifiable, Hashable {
        let id: String           // refs/heads/foo
        let displayId: String    // foo
        let `default`: Bool?
        let latestCommit: String?
        let metadata: BBBranchMetadata?

        struct BBBranchMetadata: Decodable, Hashable {
            let aheadBehind: AheadBehind?
            let latestCommit: LatestCommitMeta?

            struct AheadBehind: Decodable, Hashable {
                let ahead: Int?
                let behind: Int?
            }
            struct LatestCommitMeta: Decodable, Hashable {
                let displayId: String?
                let authorTimestamp: Int?
                let message: String?
                let author: Author?
                struct Author: Decodable, Hashable { let name: String?; let displayName: String? }
            }
            private enum CodingKeys: String, CodingKey {
                case aheadBehind = "com.atlassian.bitbucket.server.bitbucket-branch:ahead-behind-metadata-provider"
                case latestCommit = "com.atlassian.bitbucket.server.bitbucket-branch:latest-commit-metadata"
            }
        }
    }

    struct BBCommit: Decodable, Identifiable, Hashable {
        let id: String
        let displayId: String
        let author: BBAuthor?
        let authorTimestamp: Int?
        let message: String?
        let committer: BBAuthor?
        let committerTimestamp: Int?

        struct BBAuthor: Decodable, Hashable {
            let name: String?
            let displayName: String?
            let emailAddress: String?
        }
    }

    struct BBTag: Decodable, Identifiable, Hashable {
        let id: String
        let displayId: String
        let latestCommit: String?
    }

    func bbBranches(projectId: Int?, filter: String = "", limit: Int = 200) async throws -> [BBBranch] {
        try await get("api/bitbucket/branches",
                      query: ["project_id": projectId.map(String.init),
                              "filter": filter,
                              "limit": String(limit)])
    }
    func bbCommits(projectId: Int?, branch: String? = nil, path: String? = nil, limit: Int = 200) async throws -> [BBCommit] {
        try await get("api/bitbucket/commits",
                      query: ["project_id": projectId.map(String.init),
                              "branch": branch, "path": path, "limit": String(limit)])
    }
    func bbTags(projectId: Int?, limit: Int = 200) async throws -> [BBTag] {
        try await get("api/bitbucket/tags",
                      query: ["project_id": projectId.map(String.init), "limit": String(limit)])
    }
}

// MARK: - Jira (v1.1)

extension APIClient {

    /// Normalize edilmiş Jira task — `jira_client.JiraClient.normalize()` formatı.
    struct JiraTask: Decodable, Identifiable, Hashable {
        let issue_key: String
        let summary: String
        let status: String
        let priority: String?
        let issue_type: String?
        let assignee: String?
        let sprint: String?
        let description: String?
        let url: String
        let updated: String?
        var id: String { issue_key }
    }

    /// Cache'lenmiş task — JiraIssueCache modeli ile aynı
    struct JiraCachedIssue: Decodable, Identifiable, Hashable {
        let issue_key: String
        let summary: String?
        let status: String?
        let priority: String?
        let issue_type: String?
        let assignee: String?
        let sprint: String?
        let url: String?
        var id: String { issue_key }
    }

    /// Detay endpoint'ten dönen raw issue (Jira REST format) — selektif alanlar
    struct JiraIssueDetail: Decodable {
        let key: String
        let fields: JiraFields?
        let transitions: [JiraTransition]?
        let renderedFields: RenderedFields?   // HTML (expand=renderedFields)
        let changelog: Changelog?             // history (expand=changelog)

        struct JiraFields: Decodable {
            let summary: String?
            let description: String?
            let labels: [String]?
            let status: NamedRef?
            let priority: NamedRef?
            let issuetype: NamedRef?
            let assignee: JiraUser?
            let reporter: JiraUser?
            let fixVersions: [NamedRef]?
            let comment: CommentField?
            let attachment: [JiraAttachment]?
            let created: String?
            let updated: String?
        }
        struct NamedRef: Decodable, Hashable { let name: String?; let id: String? }
        struct JiraUser: Decodable, Hashable {
            let name: String?
            let displayName: String?
            let emailAddress: String?
            let accountId: String?
        }

        // Yorumlar
        struct CommentField: Decodable { let comments: [JiraComment]?; let total: Int? }
        struct JiraComment: Decodable, Identifiable, Hashable {
            let id: String
            let author: JiraUser?
            let body: String?       // wiki/raw
            let created: String?
            let updated: String?
        }
        // Ekler
        struct JiraAttachment: Decodable, Identifiable, Hashable {
            let id: String
            let filename: String?
            let size: Int?
            let created: String?
            let mimeType: String?
            let content: String?    // indirme URL'i (VPN+auth gerektirir)
        }
        // Rendered (HTML) alanlar
        struct RenderedFields: Decodable {
            let description: String?
            let comment: RenderedComment?
            struct RenderedComment: Decodable { let comments: [RenderedBody]? }
            struct RenderedBody: Decodable, Hashable { let id: String?; let body: String? }
        }
        // Değişiklik geçmişi
        struct Changelog: Decodable {
            let histories: [History]?
            struct History: Decodable, Identifiable, Hashable {
                let id: String
                let author: JiraUser?
                let created: String?
                let items: [Item]?
                struct Item: Decodable, Hashable {
                    let field: String?
                    let fromString: String?
                    let toString: String?
                }
            }
        }
    }
    struct JiraTransition: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let to: JiraTransitionTo?
        struct JiraTransitionTo: Decodable, Hashable {
            let name: String?
            let id: String?
            let statusCategory: StatusCategoryRef?
            struct StatusCategoryRef: Decodable, Hashable { let key: String?; let name: String? }
        }
    }

    struct JiraUserDetail: Decodable, Hashable, Identifiable {
        let name: String?
        let displayName: String?
        let emailAddress: String?
        let accountId: String?
        var id: String { name ?? accountId ?? displayName ?? UUID().uuidString }
    }

    struct JiraPriority: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    struct JiraVersion: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
        let released: Bool?
        let archived: Bool?
    }

    struct JiraSprint: Decodable, Hashable, Identifiable {
        let id: Int
        let name: String
        let state: String?  // active | future | closed
    }

    // ── Reads ─────────────────────────────────────────────────────────

    func listJiraTasks(
        projectId: Int?,
        jql: String? = nil,
        assignee: String? = nil,
        statusCategory: String? = nil,
        status: String? = nil,
        text: String? = nil,
        label: String? = nil,
        issueType: String? = nil,
        maxResults: Int = 100
    ) async throws -> [JiraTask] {
        var q: [String: String?] = [
            "project_id": projectId.map(String.init),
            "max_results": String(maxResults),
        ]
        if let v = jql { q["jql"] = v }
        if let v = assignee { q["assignee"] = v }
        if let v = statusCategory { q["status_category"] = v }
        if let v = status { q["status"] = v }
        if let v = text { q["text"] = v }
        if let v = label { q["label"] = v }
        if let v = issueType { q["issue_type"] = v }
        return try await get("api/jira/tasks", query: q)
    }

    func getJiraTask(_ key: String) async throws -> JiraIssueDetail {
        try await get("api/jira/task/\(key)")
    }

    func getJiraTransitions(_ key: String) async throws -> [JiraTransition] {
        try await get("api/jira/task/\(key)/transitions")
    }

    func assignableJiraUsers(project: String?, issueKey: String?, query: String = "") async throws -> [JiraUserDetail] {
        var q: [String: String?] = ["q": query]
        if let p = project { q["project"] = p }
        if let k = issueKey { q["issue_key"] = k }
        return try await get("api/jira/assignable", query: q)
    }

    /// Global priority şeması.
    func listJiraPriorities() async throws -> [JiraPriority] {
        try await get("api/jira/priorities")
    }

    /// Issue'nun projesindeki fix version'lar.
    func listJiraVersions(issueKey: String) async throws -> [JiraVersion] {
        try await get("api/jira/versions", query: ["issue_key": issueKey])
    }

    /// Issue'nun board'larındaki active+future sprint'ler.
    func listJiraSprints(issueKey: String) async throws -> [JiraSprint] {
        try await get("api/jira/sprints", query: ["issue_key": issueKey])
    }

    /// Mevcut etiketler arasında autocomplete önerileri.
    func listJiraLabels(query: String) async throws -> [String] {
        try await get("api/jira/labels", query: ["q": query])
    }

    // ── Mutations ────────────────────────────────────────────────────

    struct JiraTransitionResult: Decodable {
        let ok: Bool
        let from: String?
        let to: String?
    }
    func transitionJira(_ key: String, transitionId: String, comment: String? = nil, projectId: Int?) async throws -> JiraTransitionResult {
        struct Body: Encodable {
            let transition_id: String
            let comment: String?
            let project_id: Int?
        }
        return try await post("api/jira/task/\(key)/transition",
                              body: Body(transition_id: transitionId, comment: comment, project_id: projectId))
    }

    /// Generic field update. fields direkt Jira REST format'ında.
    /// Örn: ["summary": .string("yeni özet"), "assignee": .object(["name": .string("U0T..."]))]
    func updateJiraTask(_ key: String, fields: [String: ActionEntry.JSONValue], projectId: Int?) async throws {
        struct Empty: Decodable { let ok: Bool? }
        struct Body: Encodable {
            let fields: [String: ActionEntry.JSONValue]
            let project_id: Int?
        }
        let _: Empty = try await patch("api/jira/task/\(key)",
                                       body: Body(fields: fields, project_id: projectId))
    }

    /// Tip-güvenli kısa-yol — assignee ataması.
    func setJiraAssignee(_ key: String, username: String?, projectId: Int?) async throws {
        let value: ActionEntry.JSONValue
        if let u = username {
            value = .object(["name": .string(u)])
        } else {
            value = .object(["name": .null])  // assignee'yi temizle
        }
        try await updateJiraTask(key, fields: ["assignee": value], projectId: projectId)
    }

    /// Summary edit
    func setJiraSummary(_ key: String, summary: String, projectId: Int?) async throws {
        try await updateJiraTask(key, fields: ["summary": .string(summary)], projectId: projectId)
    }

    /// Description edit
    func setJiraDescription(_ key: String, description: String, projectId: Int?) async throws {
        try await updateJiraTask(key, fields: ["description": .string(description)], projectId: projectId)
    }

    /// Labels — tam liste (Jira PUT field semantics)
    func setJiraLabels(_ key: String, labels: [String], projectId: Int?) async throws {
        try await updateJiraTask(
            key,
            fields: ["labels": .array(labels.map { ActionEntry.JSONValue.string($0) })],
            projectId: projectId
        )
    }

    /// Priority — name ile
    func setJiraPriority(_ key: String, priorityName: String, projectId: Int?) async throws {
        try await updateJiraTask(
            key,
            fields: ["priority": .object(["name": .string(priorityName)])],
            projectId: projectId
        )
    }

    /// Fix versions — id listesi (tam liste, PUT field semantics; boş array = temizle)
    func setJiraFixVersions(_ key: String, versionIds: [String], projectId: Int?) async throws {
        let value = ActionEntry.JSONValue.array(
            versionIds.map { .object(["id": .string($0)]) }
        )
        try await updateJiraTask(key, fields: ["fixVersions": value], projectId: projectId)
    }

    /// Sprint atama — sprintId nil ise issue backlog'a alınır (Agile API).
    func setJiraSprint(_ key: String, sprintId: Int?, projectId: Int?) async throws {
        struct Body: Encodable {
            let sprint_id: Int?
            let project_id: Int?
        }
        struct Empty: Decodable { let ok: Bool? }
        let _: Empty = try await post("api/jira/task/\(key)/sprint",
                                      body: Body(sprint_id: sprintId, project_id: projectId))
    }

    func addJiraComment(_ key: String, body: String, projectId: Int?) async throws {
        struct Body: Encodable {
            let body: String
            let project_id: Int?
        }
        struct Empty: Decodable { let ok: Bool? }
        let _: Empty = try await post("api/jira/task/\(key)/comment",
                                      body: Body(body: body, project_id: projectId))
    }

    struct BranchResult: Decodable {
        let ok: Bool
        let branch: String?
        let repo: String?
        let workspace: String?
        let source_branch: String?
    }
    /// sourceBranch nil ise backend projenin git_default_branch'ini kullanır.
    func createBranchFromJira(_ key: String, sourceBranch: String? = nil, projectId: Int?) async throws -> BranchResult {
        struct Body: Encodable {
            let source_branch: String?
            let branch_prefix: String
            let project_id: Int?
        }
        return try await post("api/jira/task/\(key)/branch",
                              body: Body(source_branch: sourceBranch, branch_prefix: "feature", project_id: projectId))
    }

    // ── Legacy (cached liste — eski cache mantığı) ────────────────────

    func jiraIssues(projectId: Int?) async throws -> [JiraCachedIssue] {
        try await get("api/jira/issues", query: ["project_id": projectId.map(String.init)])
    }
    func jiraRefresh(projectId: Int?) async throws {
        struct Body: Encodable { let project_id: Int? }
        struct Empty: Decodable {}
        let _: Empty = try await post("api/jira/refresh", body: Body(project_id: projectId))
    }
}

// MARK: - İptal tespiti

extension Error {
    /// Task iptali veya URLSession cancel — gerçek bir hata değil, yutulmalı.
    /// (Ör. `.task(id:)` yeniden tetiklenince önceki istek iptal edilir.)
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlErr = self as? URLError, urlErr.code == .cancelled { return true }
        return false
    }
}

// MARK: - ISO8601 with fractional seconds (Python datetime.utcnow default)

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractional: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatters: [ISO8601DateFormatter] = [
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }(),
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    return f
                }(),
            ]
            for f in formatters {
                if let d = f.date(from: raw) { return d }
            }
            // Fallback — parse manuel
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            if let d = df.date(from: raw) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Tarih parse edilemedi: \(raw)"))
        }
    }
}
