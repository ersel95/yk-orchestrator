import SwiftUI

/// İlk açılış kurulum sihirbazı (v0.3.0+).
/// Adımlar: Welcome → Jira → Bitbucket → Provider'lar → Rol Ataması → Projeler → Tamamla
struct SetupWizardView: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var sidecar: SidecarManager

    @State private var step: Step = .welcome
    @State private var draft: AppConfig = ConfigStore.shared.config

    // Token alanları — commit'te Keychain'e yazılır, struct'a girmez
    @State private var jiraToken: String = ""
    @State private var bitbucketToken: String = ""
    @State private var providerKeys: [String: String] = [:]  // template.id → token

    // Provider seçimi UI state
    @State private var selectedProviders: Set<ProviderTemplate> = []
    @State private var providerBaseURLs: [String: String] = [:]   // template.id → base url override

    @State private var saveError: String?

    enum Step: Int, CaseIterable {
        case welcome, jira, bitbucket, providers, roles, projects, done
        var title: String {
            switch self {
            case .welcome:   return "Hoş geldin"
            case .jira:      return "Jira"
            case .bitbucket: return "Bitbucket"
            case .providers: return "LLM"
            case .roles:     return "Roller"
            case .projects:  return "Projeler"
            case .done:      return "Hazır"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { hydrateInitialState() }
    }

    // MARK: - Initial state

    /// Wizard ilk açıldığında: hâlihazırdaki AppConfig'ten seçili provider'ları
    /// çıkar (re-run senaryosu) veya boşsa default LM Studio'yu işaretle.
    private func hydrateInitialState() {
        if draft.providers.isEmpty {
            selectedProviders = [.lm_studio]
        } else {
            var set: Set<ProviderTemplate> = []
            for p in draft.providers {
                if let t = ProviderTemplate(rawValue: p.id) {
                    set.insert(t)
                    if !p.base_url.isEmpty {
                        providerBaseURLs[t.id] = p.base_url
                    }
                }
            }
            selectedProviders = set.isEmpty ? [.lm_studio] : set
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                stepBadge(s)
                if s != Step.allCases.last {
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func stepBadge(_ s: Step) -> some View {
        let isActive = s == step
        let isPast = s.rawValue < step.rawValue
        return HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.accentColor : (isPast ? .secondary : .secondary.opacity(0.3)))
                .frame(width: 10, height: 10)
            Text(s.title)
                .font(.callout)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:   welcomeStep
        case .jira:      jiraStep
        case .bitbucket: bitbucketStep
        case .providers: providersStep
        case .roles:     rolesStep
        case .projects:  projectsStep
        case .done:      doneStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("YK Orchestrator'a hoş geldin")
                .font(.title2.weight(.semibold))
            Text("Bu sihirbaz Jira, Bitbucket ve seçeceğin LLM provider'larını yapılandıracak. Token'lar macOS Keychain'e güvenli olarak yazılır.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                preCheck("VPN bağlı olmalı (Jira/Bitbucket için)")
                preCheck("En az bir LLM provider hazır olmalı (LM Studio çalışır halde veya bir cloud API key)")
                preCheck("Lokal repo path'leri (git klonu) hazır olmalı")
            }
            .padding(.top, 8)
        }
    }

    private func preCheck(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // ─── Jira ─────────────────────────────────────────────────────
    private var jiraStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Jira bağlantısı")
            HelpBox(
                title: "Personal Access Token (PAT) nereden alınır?",
                bullets: [
                    "Jira'da sağ üstte profil simgene tıkla → \"Profile\".",
                    "Sol menüden \"Personal Access Tokens\" sekmesine geç.",
                    "\"Create token\" → ad ver, expire seç (önerilen: 90 gün), oluştur.",
                    "Çıkan token'ı kopyala — bir daha gösterilmez."
                ],
                link: ("Yapı Kredi Jira'yı aç", "https://sdlc.yapikredi.com.tr/jira/secure/ViewProfile.jspa")
            )
            field("Base URL", placeholder: "https://sdlc.yapikredi.com.tr/jira",
                  text: $draft.jira_base_url)
            field("E-posta / kullanıcı", placeholder: "ersel@yapikredi.com.tr",
                  text: $draft.jira_email)
            VStack(alignment: .leading, spacing: 4) {
                Text("Personal Access Token").font(.callout).foregroundStyle(.secondary)
                SecureField("PAT (Bearer)", text: $jiraToken)
                    .textFieldStyle(.roundedBorder)
            }
            field("Proje anahtarları (virgüllü)", placeholder: "CAPYBARZ,MOLENARS",
                  text: $draft.jira_project_keys)
            Text("Token macOS Keychain'e yazılır, config dosyasına bırakılmaz.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // ─── Bitbucket ────────────────────────────────────────────────
    private var bitbucketStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Bitbucket Server bağlantısı")
            HelpBox(
                title: "HTTP Access Token nereden alınır?",
                bullets: [
                    "Bitbucket'ta sağ üstte avatar → \"Manage account\".",
                    "Sol menüden \"HTTP access tokens\" → \"Create token\".",
                    "İzinler: PROJECT_READ + REPO_READ + REPO_WRITE (PR açma ve yorum için).",
                    "Token'ı kopyala — bir daha gösterilmez."
                ],
                link: ("Yapı Kredi Bitbucket'ı aç", "https://sdlc.yapikredi.com.tr/bitbucket/account/settings/http-access-tokens")
            )
            field("Base URL", placeholder: "https://sdlc.yapikredi.com.tr/bitbucket",
                  text: $draft.bitbucket_base_url)
            field("Kullanıcı adı", placeholder: "U0T19961 (Bitbucket username)",
                  text: $draft.bitbucket_username)
            VStack(alignment: .leading, spacing: 4) {
                Text("HTTP Access Token").font(.callout).foregroundStyle(.secondary)
                SecureField("HTTP token", text: $bitbucketToken)
                    .textFieldStyle(.roundedBorder)
            }
            field("Workspace / proje key", placeholder: "COSADC",
                  text: $draft.bitbucket_workspace)
            field("Varsayılan repo", placeholder: "az-adc-ios",
                  text: $draft.bitbucket_default_repo)
        }
    }

    // ─── Provider'lar (çoklu seçim) ────────────────────────────────
    private var providersStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("LLM provider'ları seç")
            Text("Birden fazlasını seçebilirsin. Bir sonraki adımda her bir AI rolünü (daily, PR review, chat, vs.) hangi provider'a göndermek istediğini ayrı ayrı belirleyebilirsin.")
                .foregroundStyle(.secondary)
                .font(.callout)

            ForEach(ProviderTemplate.allCases) { template in
                ProviderCard(
                    template: template,
                    isSelected: selectedProviders.contains(template),
                    apiKey: Binding(
                        get: { providerKeys[template.id] ?? "" },
                        set: { providerKeys[template.id] = $0 }
                    ),
                    baseURL: Binding(
                        get: { providerBaseURLs[template.id] ?? template.defaultBaseURL },
                        set: { providerBaseURLs[template.id] = $0 }
                    ),
                    onToggle: {
                        if selectedProviders.contains(template) {
                            selectedProviders.remove(template)
                        } else {
                            selectedProviders.insert(template)
                        }
                    }
                )
            }

            if selectedProviders.isEmpty {
                Text("En az bir provider seçmelisin.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // ─── Rol ataması ──────────────────────────────────────────────
    private var rolesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("AI rollerini provider'lara ata")
            Text("Her rol bir (provider, model) çiftine bağlanır. Hızlı kurulum için 'Hepsini şuna ata' butonunu kullan, sonra istediğin rolü değiştir.")
                .foregroundStyle(.secondary)
                .font(.callout)

            if selectedProviders.count > 1 {
                HStack(spacing: 8) {
                    Text("Hepsini şuna ata:").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(selectedProviders).sorted(by: { $0.rawValue < $1.rawValue })) { tmpl in
                        Button(tmpl.displayName) {
                            applyAllRoles(to: tmpl)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            ForEach(LLMRole.allCases) { role in
                RoleAssignmentCard(
                    role: role,
                    availableProviders: Array(selectedProviders).sorted(by: { $0.rawValue < $1.rawValue }),
                    assignment: Binding(
                        get: { draft.model_roles[role.rawValue] ?? defaultAssignment(for: role) },
                        set: { draft.model_roles[role.rawValue] = $0 }
                    )
                )
            }
        }
    }

    private func defaultAssignment(for role: LLMRole) -> RoleAssignmentEntry {
        // Embed için ilk OpenAI-uyumlu provider'ı bul
        if role == .embed {
            if selectedProviders.contains(.lm_studio) {
                return RoleAssignmentEntry(provider: "lm_studio", model: "text-embedding-nomic-embed-text-v1.5")
            }
            if selectedProviders.contains(.openai) {
                return RoleAssignmentEntry(provider: "openai", model: "text-embedding-3-small")
            }
        }
        let first = selectedProviders.first ?? .lm_studio
        let firstModel = first.suggestedModels.first ?? ""
        return RoleAssignmentEntry(provider: first.id, model: firstModel)
    }

    private func applyAllRoles(to template: ProviderTemplate) {
        for role in LLMRole.allCases {
            // Embed Anthropic'i desteklemiyor — atlanır
            if role == .embed && template == .anthropic {
                draft.model_roles[role.rawValue] = defaultAssignment(for: .embed)
                continue
            }
            let suggested = template.suggestedModels.first ?? ""
            draft.model_roles[role.rawValue] = RoleAssignmentEntry(provider: template.id, model: suggested)
        }
    }

    // ─── Projeler (mevcut) ────────────────────────────────────────
    private var projectsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Projeler")
            Text("Birden fazla iOS projen varsa her biri için ayrı Jira anahtarı / repo / lokal yol tanımlayabilirsin.")
                .foregroundStyle(.secondary)
            ForEach($draft.projects) { $p in
                ProjectCard(project: $p, onDelete: {
                    draft.projects.removeAll { $0.id == p.id }
                })
            }
            Button {
                draft.projects.append(ProjectConfig(name: "Yeni Proje",
                                                   slug: "proje-\(draft.projects.count + 1)"))
            } label: {
                Label("Proje ekle", systemImage: "plus")
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Kurulum tamamlandı")
            Text("Backend başlayacak, dashboard birkaç saniye içinde gelecek.")
                .foregroundStyle(.secondary)
            if let err = saveError {
                Text(err).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Geri") {
                    withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
            }
            Spacer()
            Button(footerActionLabel) { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
        .padding(20)
    }

    private var footerActionLabel: String {
        switch step {
        case .done:     return "Başlat"
        case .projects: return "Bitir"
        default:        return "İleri"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .providers: return !selectedProviders.isEmpty
        default: return true
        }
    }

    private func advance() {
        if step == .done { return }
        if let next = Step(rawValue: step.rawValue + 1) {
            if next == .done {
                commit()
            } else {
                withAnimation { step = next }
            }
        }
    }

    private func commit() {
        do {
            // Token'lar Keychain'e
            if !jiraToken.isEmpty {
                try KeychainStore.shared.set(jiraToken, for: "jira_api_token")
            }
            if !bitbucketToken.isEmpty {
                try KeychainStore.shared.set(bitbucketToken, for: "bitbucket_app_password")
            }
            // Provider API key'leri Keychain'e (her seçili provider için)
            for template in selectedProviders {
                if let key = providerKeys[template.id], !key.isEmpty {
                    try KeychainStore.shared.set(key, for: template.keychainKey)
                }
            }

            // Seçili provider'ları AppConfig'e işle
            var providers: [ProviderEntry] = []
            for template in selectedProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
                providers.append(ProviderEntry(
                    id: template.id,
                    kind: template.kind,
                    base_url: providerBaseURLs[template.id] ?? template.defaultBaseURL,
                    api_key_env: template.apiKeyEnvName,
                    timeout_seconds: 300
                ))
            }

            var snap = draft
            snap.providers = providers
            // Hâlâ atanmamış roller için defaultAssignment kullan
            for role in LLMRole.allCases where snap.model_roles[role.rawValue] == nil {
                snap.model_roles[role.rawValue] = defaultAssignment(for: role)
            }
            snap.completedSetup = true

            try config.save(snap)
            saveError = nil
            withAnimation { step = .done }
            sidecar.restart(config: config.snapshot)
        } catch {
            saveError = "Kaydetme hatası: \(error.localizedDescription)"
        }
    }

    // MARK: - Building blocks

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title3.weight(.semibold))
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Yardımcı view'lar

/// Wizard'da inline yardım bloğu — "X nereden alınır?" tarzı talimatları gösterir.
private struct HelpBox: View {
    let title: String
    let bullets: [String]
    /// (label, url) — opsiyonel açılır link
    let link: (label: String, url: String)?

    @State private var expanded = false

    init(title: String, bullets: [String], link: (label: String, url: String)? = nil) {
        self.title = title
        self.bullets = bullets
        self.link = link
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bullets, id: \.self) { b in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(b).foregroundStyle(.secondary).font(.callout)
                    }
                }
                if let link {
                    Link(destination: URL(string: link.url)!) {
                        Label(link.label, systemImage: "safari")
                            .font(.callout)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                Text(title).font(.callout.weight(.medium))
            }
            .foregroundStyle(.blue)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(8)
    }
}

/// Provider seçim kartı — checkbox + (seçiliyse) API key ve base URL alanları.
private struct ProviderCard: View {
    let template: ProviderTemplate
    let isSelected: Bool
    @Binding var apiKey: String
    @Binding var baseURL: String
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .font(.title3)
                        Text(template.displayName).font(.body.weight(.medium))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            if isSelected {
                if template == .lm_studio {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL").font(.callout).foregroundStyle(.secondary)
                        TextField("http://127.0.0.1:1234/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("LM Studio'yu aç, modeli yükle, Local Server (port 1234) çalışır halde olmalı.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key").font(.callout).foregroundStyle(.secondary)
                        SecureField(apiKeyPlaceholder, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    HelpBox(
                        title: "API key nereden alınır?",
                        bullets: apiKeyHelpBullets,
                        link: apiKeyHelpLink
                    )
                }
            }
        }
        .padding(14)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    private var apiKeyPlaceholder: String {
        switch template {
        case .anthropic: return "sk-ant-..."
        case .openai:    return "sk-..."
        default:         return ""
        }
    }

    private var apiKeyHelpBullets: [String] {
        switch template {
        case .anthropic:
            return [
                "console.anthropic.com'a giriş yap.",
                "Sol menüden \"API Keys\" → \"Create Key\".",
                "Adı ver, oluştur, sk-ant-... ile başlayan token'ı kopyala."
            ]
        case .openai:
            return [
                "platform.openai.com/api-keys'e git.",
                "\"Create new secret key\" → adı ver, scope seç.",
                "sk-... ile başlayan token'ı hemen kopyala — kapatınca tekrar gösterilmez."
            ]
        default: return []
        }
    }

    private var apiKeyHelpLink: (label: String, url: String)? {
        switch template {
        case .anthropic: return ("Anthropic Console'u aç", "https://console.anthropic.com/settings/keys")
        case .openai:    return ("OpenAI dashboard'u aç", "https://platform.openai.com/api-keys")
        default:         return nil
        }
    }
}

/// Tek bir rolü provider+model'e bağlayan card.
private struct RoleAssignmentCard: View {
    let role: LLMRole
    let availableProviders: [ProviderTemplate]
    @Binding var assignment: RoleAssignmentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(role.title).font(.body.weight(.medium))
                Spacer()
            }
            if !role.hint.isEmpty {
                Text(role.hint).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                // Provider picker
                Picker("", selection: $assignment.provider) {
                    ForEach(providersForRole) { tmpl in
                        Text(tmpl.displayName).tag(tmpl.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                // Model textfield (suggested listesi placeholder olarak)
                TextField(suggestedModelPlaceholder, text: $assignment.model)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    /// Embed sadece OpenAI-uyumlu provider'larda destekli.
    private var providersForRole: [ProviderTemplate] {
        if role == .embed {
            return availableProviders.filter { $0 != .anthropic }
        }
        return availableProviders
    }

    private var suggestedModelPlaceholder: String {
        guard let tmpl = ProviderTemplate(rawValue: assignment.provider) else { return "" }
        return tmpl.suggestedModels.first ?? ""
    }
}

/// Proje kartı (mevcut yapı — değişmedi)
private struct ProjectCard: View {
    @Binding var project: ProjectConfig
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("İsim", text: $project.name)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
            }
            TextField("slug (az, nl, ...)", text: $project.slug).textFieldStyle(.roundedBorder)
            TextField("Jira anahtarları (CAPYBARZ)", text: $project.jira_project_keys)
                .textFieldStyle(.roundedBorder)
            TextField("Bitbucket workspace (COSADC)", text: $project.bitbucket_workspace)
                .textFieldStyle(.roundedBorder)
            TextField("Bitbucket repo (az-adc-ios)", text: $project.bitbucket_repo)
                .textFieldStyle(.roundedBorder)
            TextField("Lokal repo yolu (/Users/.../Yk/Az)", text: $project.local_repo_path)
                .textFieldStyle(.roundedBorder)
            TextField("Varsayılan branch", text: $project.git_default_branch)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}
