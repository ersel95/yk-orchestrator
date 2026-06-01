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
        let is_archived: Bool
        let sort_order: Int
    }
    struct ProjectListResponse: Decodable {
        let projects: [ProjectInfo]
        let active_id: Int?
    }
    func listProjects() async throws -> ProjectListResponse {
        try await get("api/projects")
    }
    func activateProject(id: Int) async throws {
        struct Empty: Encodable {}
        try await postVoid("api/projects/\(id)/activate", body: Empty())
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
        enum JSONValue: Decodable, Hashable {
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

// MARK: - Jira (sade)

extension APIClient {
    struct JiraIssue: Decodable, Identifiable, Hashable {
        let key: String
        let summary: String?
        let status: String?
        let assignee: String?
        let updated: String?
        var id: String { key }
    }
    func jiraIssues(projectId: Int?) async throws -> [JiraIssue] {
        try await get("api/jira/issues", query: ["project_id": projectId.map(String.init)])
    }
    func jiraRefresh(projectId: Int?) async throws {
        struct Body: Encodable { let project_id: Int? }
        struct Empty: Decodable {}
        let _: Empty = try await post("api/jira/refresh", body: Body(project_id: projectId))
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
