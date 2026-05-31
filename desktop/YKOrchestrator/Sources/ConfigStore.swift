import Foundation
import Combine

/// Kullanıcı yapılandırması.
/// Hassas olmayan değerleri ~/Library/Application Support/YK Orchestrator/config.json
/// dosyasına yazar. Token gibi sırlar KeychainStore tarafından tutulur.
@MainActor
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    @Published var config: AppConfig
    @Published private(set) var isConfigured: Bool

    private let url = AppSupportPaths.configJSON()

    init() {
        let loaded = Self.load(from: url) ?? AppConfig.empty
        self.config = loaded
        self.isConfigured = loaded.isComplete
    }

    var snapshot: ConfigSnapshot { ConfigSnapshot(config: config) }

    func save(_ updated: AppConfig) throws {
        try Self.write(updated, to: url)
        self.config = updated
        self.isConfigured = updated.isComplete
    }

    func markConfigured() {
        var c = config
        c.completedSetup = true
        try? save(c)
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> AppConfig? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(AppConfig.self, from: data)
    }

    private static func write(_ config: AppConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Models

struct AppConfig: Codable, Equatable {
    var jira_base_url: String = ""
    var jira_email: String = ""
    var jira_project_keys: String = ""

    var bitbucket_base_url: String = ""
    var bitbucket_username: String = ""
    var bitbucket_workspace: String = ""
    var bitbucket_default_repo: String = ""

    var llm_base_url: String = "http://127.0.0.1:1234/v1"
    var llm_model_general: String = "qwen/qwen3.6-35b-a3b"
    var llm_model_code: String = "qwen/qwen3.6-35b-a3b"

    var projects: [ProjectConfig] = []
    var completedSetup: Bool = false

    static let empty = AppConfig()

    var isComplete: Bool {
        completedSetup &&
        !jira_base_url.isEmpty &&
        !bitbucket_base_url.isEmpty &&
        !llm_base_url.isEmpty
    }
}

struct ProjectConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var slug: String = ""
    var jira_project_keys: String = ""
    var bitbucket_workspace: String = ""
    var bitbucket_repo: String = ""
    var local_repo_path: String = ""
    var git_default_branch: String = "develop"
}

/// SidecarManager.start(config:) için immutable kopyası.
struct ConfigSnapshot {
    let envOverrides: [String: String]

    init(config: AppConfig) {
        var env: [String: String] = [:]
        if !config.jira_base_url.isEmpty       { env["JIRA_BASE_URL"] = config.jira_base_url }
        if !config.jira_email.isEmpty          { env["JIRA_EMAIL"] = config.jira_email }
        if !config.jira_project_keys.isEmpty   { env["JIRA_PROJECT_KEYS"] = config.jira_project_keys }
        if !config.bitbucket_base_url.isEmpty  { env["BITBUCKET_BASE_URL"] = config.bitbucket_base_url }
        if !config.bitbucket_username.isEmpty  { env["BITBUCKET_USERNAME"] = config.bitbucket_username }
        if !config.bitbucket_workspace.isEmpty { env["BITBUCKET_WORKSPACE"] = config.bitbucket_workspace }
        if !config.bitbucket_default_repo.isEmpty { env["BITBUCKET_DEFAULT_REPO"] = config.bitbucket_default_repo }
        if !config.llm_base_url.isEmpty        { env["LLM_BASE_URL"] = config.llm_base_url }
        if !config.llm_model_general.isEmpty   { env["LLM_MODEL_GENERAL"] = config.llm_model_general }
        if !config.llm_model_code.isEmpty      { env["LLM_MODEL_CODE"] = config.llm_model_code }
        self.envOverrides = env
    }
}
