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

    // Multi-provider mimarisi (v0.3.0+)
    // Backend bunu JSON olarak okur ve aktif provider'a göre LLM router'ı kurar.
    var providers: [ProviderEntry] = []
    var model_roles: [String: RoleAssignmentEntry] = [:]

    // Legacy alanlar (backward compat — providers boşsa backend bunlardan
    // tek-provider config üretir; yeni wizard her zaman providers doldurur)
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
        !providers.isEmpty
    }
}

struct ProviderEntry: Codable, Equatable, Identifiable {
    var id: String                    // "lm_studio" | "anthropic" | "openai"
    var kind: String                  // "openai_compatible" | "anthropic"
    var base_url: String = ""         // openai_compatible için
    var api_key_env: String = ""      // Keychain ENV ismi (örn "ANTHROPIC_API_KEY")
    var timeout_seconds: Int = 300
}

struct RoleAssignmentEntry: Codable, Equatable, Hashable {
    var provider: String
    var model: String
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

/// Sidecar'a env olarak inject edilecek key→value haritası.
/// Token'lar Keychain'den ayrıca eklenir.
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

        // Eski tek-provider için ENV (backward compat — backend ilk providers
        // boşsa bu alanları kullanır)
        if !config.llm_base_url.isEmpty        { env["LLM_BASE_URL"] = config.llm_base_url }
        if !config.llm_model_general.isEmpty   { env["LLM_MODEL_GENERAL"] = config.llm_model_general }
        if !config.llm_model_code.isEmpty      { env["LLM_MODEL_CODE"] = config.llm_model_code }
        self.envOverrides = env
    }
}

// MARK: - Sabitler

/// Wizard ve Settings sayfasında gösterilen role katalogu.
enum LLMRole: String, CaseIterable, Identifiable {
    case daily_writer
    case pr_summarizer
    case pr_commenter
    case code_reviewer
    case transcript
    case chat
    case embed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily_writer:  return "Daily metin (Bugün / Dün)"
        case .pr_summarizer: return "PR diff özeti"
        case .pr_commenter:  return "PR inline yorum önerileri"
        case .code_reviewer: return "Derin kod review"
        case .transcript:    return "Toplantı transkript özeti"
        case .chat:          return "Chat / RAG soru-cevap"
        case .embed:         return "Embedding (vektör arama)"
        }
    }

    var hint: String {
        switch self {
        case .embed: return "Sadece OpenAI-uyumlu provider (LM Studio / OpenAI) destekler."
        case .pr_summarizer, .pr_commenter, .code_reviewer:
            return "Banka kod tabanına temas eder — cloud provider seçersen veri sorumluluğu sende."
        default: return ""
        }
    }
}

/// Wizard'ın sunduğu provider şablonları. Kullanıcı seçtikten sonra
/// AppConfig.providers içine eklenir.
enum ProviderTemplate: String, CaseIterable, Identifiable {
    case lm_studio
    case claude_code     // Claude — subscription OAuth via `claude` CLI (API key gerekmez)
    case anthropic       // Claude — direkt API key ile (ücretli, console.anthropic.com)
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lm_studio:   return "LM Studio (lokal)"
        case .claude_code: return "Claude (abonelik — Claude Code CLI)"
        case .anthropic:   return "Anthropic Claude (API key)"
        case .openai:      return "OpenAI"
        }
    }

    var kind: String {
        switch self {
        case .lm_studio, .openai: return "openai_compatible"
        case .anthropic:          return "anthropic"
        case .claude_code:        return "claude_code"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .lm_studio:   return "http://127.0.0.1:1234/v1"
        case .openai:      return "https://api.openai.com/v1"
        case .anthropic:   return ""
        case .claude_code: return ""    // PATH'ten `claude` aranır
        }
    }

    /// API key gerektirir mi? (claude_code OAuth ile, lm_studio'da gerek yok)
    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openai: return true
        case .lm_studio, .claude_code: return false
        }
    }

    var apiKeyEnvName: String {
        switch self {
        case .lm_studio:   return "LLM_API_KEY"
        case .anthropic:   return "ANTHROPIC_API_KEY"
        case .openai:      return "OPENAI_API_KEY"
        case .claude_code: return ""
        }
    }

    /// Keychain'de saklanacak key adı (KeychainStore.knownKeys ile uyumlu)
    var keychainKey: String {
        switch self {
        case .lm_studio:   return "llm_api_key"
        case .anthropic:   return "anthropic_api_key"
        case .openai:      return "openai_api_key"
        case .claude_code: return ""
        }
    }

    /// Bu provider için önerilen model listesi (wizard dropdown'unda gösterilir;
    /// kullanıcı istediği başka modeli de yazabilir).
    var suggestedModels: [String] {
        switch self {
        case .lm_studio:
            return [
                "qwen/qwen3.6-35b-a3b",
                "qwen2.5-coder-32b-instruct",
                "text-embedding-nomic-embed-text-v1.5",
            ]
        case .claude_code, .anthropic:
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
            ]
        case .openai:
            return [
                "gpt-4o",
                "gpt-4o-mini",
                "o1",
                "text-embedding-3-small",
            ]
        }
    }
}
