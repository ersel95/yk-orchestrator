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

    // Jira/Bitbucket connection validation state
    @State private var jiraValidation: ValidationState = .idle
    @State private var bitbucketValidation: ValidationState = .idle

    // ProjectsStep — backend'den auto-fetch edilen listeler
    @State private var availableJiraProjects: [JiraProjectItem] = []
    @State private var availableBitbucketRepos: [BitbucketRepoItem] = []
    @State private var projectsFetchError: String?
    @State private var projectsLoading: Bool = false
    @State private var projectsFetched: Bool = false   // sadece bir kez fetch et

    struct JiraProjectItem: Codable, Hashable, Identifiable {
        let key: String
        let name: String?
        var id: String { key }
    }
    struct BitbucketRepoItem: Codable, Hashable, Identifiable {
        let slug: String
        let name: String?
        let default_branch: String?
        var id: String { slug }
    }

    enum ValidationState: Equatable {
        case idle
        case validating
        case ok(String)
        case error(String)

        var isValidating: Bool { if case .validating = self { return true } else { return false } }
        var isOK: Bool { if case .ok = self { return true } else { return false } }
        var isError: Bool { if case .error = self { return true } else { return false } }
    }

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

    /// Roller adımı sadece >1 provider seçildiyse görünür; tek provider
    /// durumunda tüm roller otomatik o provider'a atanıp adım atlanır.
    private var visibleSteps: [Step] {
        Step.allCases.filter { s in
            if s == .roles && selectedProviders.count <= 1 { return false }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(visibleSteps, id: \.rawValue) { s in
                stepBadge(s)
                if s != visibleSteps.last {
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
    /// Jira/Bitbucket alanlarından biri değiştiğinde mevcut OK işaretini
    /// düşür — kullanıcı eski doğrulamayla yanlış değerlerle geçemesin.
    private func invalidateJiraValidation() { if jiraValidation != .idle { jiraValidation = .idle } }
    private func invalidateBitbucketValidation() { if bitbucketValidation != .idle { bitbucketValidation = .idle } }

    private var jiraStep: some View {
        jiraStepInner
            .onChange(of: draft.jira_base_url) { _ in invalidateJiraValidation() }
            .onChange(of: draft.jira_email)    { _ in invalidateJiraValidation() }
            .onChange(of: jiraToken)            { _ in invalidateJiraValidation() }
    }

    private var jiraStepInner: some View {
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("E-posta (opsiyonel)").font(.callout).foregroundStyle(.secondary)
                    Text("— sadece Atlassian Cloud için").font(.footnote).foregroundStyle(.tertiary)
                }
                TextField("Yapı Kredi Server/DC ise BOŞ BIRAK", text: $draft.jira_email)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Personal Access Token").font(.callout).foregroundStyle(.secondary)
                SecureField("PAT (Bearer)", text: $jiraToken)
                    .textFieldStyle(.roundedBorder)
            }
            field("Proje anahtarları (virgüllü)", placeholder: "CAPYBARZ,MOLENARS",
                  text: $draft.jira_project_keys)
            ValidationBanner(state: jiraValidation)
            Text("Token macOS Keychain'e yazılır, config dosyasına bırakılmaz.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // ─── Bitbucket ────────────────────────────────────────────────
    private var bitbucketStep: some View {
        bitbucketStepInner
            .onChange(of: draft.bitbucket_base_url) { _ in invalidateBitbucketValidation() }
            .onChange(of: draft.bitbucket_username) { _ in invalidateBitbucketValidation() }
            .onChange(of: bitbucketToken)            { _ in invalidateBitbucketValidation() }
            .onChange(of: draft.bitbucket_workspace) { _ in invalidateBitbucketValidation() }
            .onChange(of: draft.bitbucket_default_repo) { _ in invalidateBitbucketValidation() }
    }

    private var bitbucketStepInner: some View {
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
            field("Project Key", placeholder: "COSADC",
                  text: $draft.bitbucket_workspace)
            HelpBox(
                title: "Project Key nedir, nereden bulurum?",
                bullets: [
                    "Bitbucket Server'da her repo bir 'project' altında oturur — project key bu kapsayıcının kısa kodudur (büyük harfler).",
                    "Bulma: Bitbucket'ta repo'yu aç → URL'e bak: /projects/<KEY>/repos/<repo-adı>/browse",
                    "Yapı Kredi iOS repo'ları: COSADC (az-adc-ios, nl-adc-ios buradadır).",
                    "Birden çok proje varsa: en sık kullandığını yaz; her proje için ayrıntıyı sonraki adımda tanımlayacaksın."
                ],
                link: nil
            )
            field("Varsayılan repo", placeholder: "az-adc-ios",
                  text: $draft.bitbucket_default_repo)
            ValidationBanner(state: bitbucketValidation)
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

    // ─── Projeler (auto-discovery + dosya seçici) ─────────────────
    private var projectsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Projeler")
            Text("Bitbucket'taki Project Key'in altında erişebildiğin repo'lar listeleniyor. Çalışacağın repo'ları seç, her birine eşleşen Jira projesini ve yerel klasörü ata.")
                .foregroundStyle(.secondary)
                .font(.callout)

            if projectsLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Jira projeleri ve Bitbucket repo'ları çekiliyor...")
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            } else if let err = projectsFetchError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout)
                    Spacer()
                    Button("Tekrar dene") { Task { await fetchProjectLists() } }
                        .buttonStyle(.bordered)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
                .cornerRadius(8)
            } else {
                // Repo seçim listesi (Bitbucket workspace altındaki tüm repo'lar)
                if availableBitbucketRepos.isEmpty {
                    Text("'\(draft.bitbucket_workspace)' projesi altında repo bulunamadı.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    Text("Bitbucket repo'ları (\(draft.bitbucket_workspace))")
                        .font(.callout.weight(.medium))
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(availableBitbucketRepos) { repo in
                            BitbucketRepoToggle(
                                repo: repo,
                                isSelected: isProjectSelected(repoSlug: repo.slug),
                                onToggle: { toggleRepoSelection(repo) }
                            )
                        }
                    }
                }
            }

            // Seçilen projeler için detay kartları (Jira eşleştirme + local path)
            if !draft.projects.isEmpty {
                Divider().padding(.vertical, 8)
                Text("Seçilen projelerin ayarları").font(.callout.weight(.medium))
                ForEach($draft.projects) { $p in
                    ProjectDetailCard(
                        project: $p,
                        availableJiraProjects: availableJiraProjects,
                        onDelete: { draft.projects.removeAll { $0.id == p.id } }
                    )
                }
            }
        }
        .task {
            if !projectsFetched && step == .projects {
                projectsFetched = true
                await fetchProjectLists()
            }
        }
    }

    private func isProjectSelected(repoSlug: String) -> Bool {
        draft.projects.contains { $0.bitbucket_repo == repoSlug }
    }

    private func toggleRepoSelection(_ repo: BitbucketRepoItem) {
        if let idx = draft.projects.firstIndex(where: { $0.bitbucket_repo == repo.slug }) {
            draft.projects.remove(at: idx)
        } else {
            // Repo'dan otomatik doldur
            let p = ProjectConfig(
                name: repo.name ?? repo.slug,
                slug: repo.slug,
                jira_project_keys: "",  // kullanıcı seçecek
                bitbucket_workspace: draft.bitbucket_workspace,
                bitbucket_repo: repo.slug,
                local_repo_path: "",   // kullanıcı klasör seçecek
                git_default_branch: repo.default_branch?.isEmpty == false ? repo.default_branch! : "dev"
            )
            draft.projects.append(p)
        }
    }

    private func fetchProjectLists() async {
        guard let base = sidecar.apiBaseURL else {
            projectsFetchError = "Backend hazır değil"
            return
        }
        projectsLoading = true
        projectsFetchError = nil
        defer { projectsLoading = false }

        // Paralel iki istek
        async let jira = postJSON(
            base.appendingPathComponent("api/wizard/list-jira-projects"),
            body: [
                "base_url": draft.jira_base_url,
                "email": draft.jira_email,
                "token": jiraToken,
            ]
        )
        async let bitbucket = postJSON(
            base.appendingPathComponent("api/wizard/list-bitbucket-repos"),
            body: [
                "base_url": draft.bitbucket_base_url,
                "username": draft.bitbucket_username,
                "token": bitbucketToken,
                "workspace": draft.bitbucket_workspace,
            ]
        )
        let (jiraData, bbData) = await (jira, bitbucket)

        var errs: [String] = []
        if jiraData.ok {
            availableJiraProjects = (jiraData.payload?["projects"] as? [[String: Any]])?
                .compactMap { dict in
                    guard let k = dict["key"] as? String else { return nil }
                    return JiraProjectItem(key: k, name: dict["name"] as? String)
                } ?? []
        } else {
            errs.append("Jira: \(jiraData.message)")
        }
        if bbData.ok {
            availableBitbucketRepos = (bbData.payload?["repos"] as? [[String: Any]])?
                .compactMap { dict in
                    guard let s = dict["slug"] as? String else { return nil }
                    return BitbucketRepoItem(
                        slug: s,
                        name: dict["name"] as? String,
                        default_branch: dict["default_branch"] as? String
                    )
                } ?? []
        } else {
            errs.append("Bitbucket: \(bbData.message)")
        }
        if !errs.isEmpty {
            projectsFetchError = errs.joined(separator: "  ·  ")
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
                Button("Geri") { goBack() }
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
        case .jira where jiraValidation.isValidating: return "Doğrulanıyor..."
        case .bitbucket where bitbucketValidation.isValidating: return "Doğrulanıyor..."
        case .jira:     return jiraValidation.isOK ? "İleri" : "Bağlantıyı test et ve devam"
        case .bitbucket: return bitbucketValidation.isOK ? "İleri" : "Bağlantıyı test et ve devam"
        default:        return "İleri"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .providers: return !selectedProviders.isEmpty
        case .jira:      return !jiraValidation.isValidating
        case .bitbucket: return !bitbucketValidation.isValidating
        default: return true
        }
    }

    private func advance() {
        if step == .done { return }

        // Jira/Bitbucket: önce bağlantı doğrulaması, başarılıysa ilerle
        if step == .jira {
            if jiraValidation.isOK {
                withAnimation { step = .bitbucket }
            } else {
                Task { await validateJira() }
            }
            return
        }
        if step == .bitbucket {
            if bitbucketValidation.isOK {
                withAnimation { step = .providers }
            } else {
                Task { await validateBitbucket() }
            }
            return
        }

        // Tek provider seçildiyse Roller adımını atla:
        // tüm rolleri o provider'a auto-assign et, direkt Projeler'e geç.
        if step == .providers, selectedProviders.count == 1,
           let only = selectedProviders.first {
            applyAllRoles(to: only)
            withAnimation { step = .projects }
            return
        }

        if let next = Step(rawValue: step.rawValue + 1) {
            if next == .done {
                commit()
            } else {
                withAnimation { step = next }
            }
        }
    }

    // MARK: - Connection validation

    private func validateJira() async {
        guard let base = sidecar.apiBaseURL else {
            jiraValidation = .error("Backend henüz hazır değil")
            return
        }
        jiraValidation = .validating
        let r = await postJSON(
            base.appendingPathComponent("api/wizard/test-jira"),
            body: [
                "base_url": draft.jira_base_url,
                "email": draft.jira_email,
                "token": jiraToken,
                "project_keys": draft.jira_project_keys,
            ]
        )
        let state: ValidationState = r.ok ? .ok(r.message) : .error(r.message)
        await MainActor.run {
            self.jiraValidation = state
            if r.ok { withAnimation { self.step = .bitbucket } }
        }
    }

    private func validateBitbucket() async {
        guard let base = sidecar.apiBaseURL else {
            bitbucketValidation = .error("Backend henüz hazır değil")
            return
        }
        bitbucketValidation = .validating
        let r = await postJSON(
            base.appendingPathComponent("api/wizard/test-bitbucket"),
            body: [
                "base_url": draft.bitbucket_base_url,
                "username": draft.bitbucket_username,
                "token": bitbucketToken,
                "workspace": draft.bitbucket_workspace,
                "repo": draft.bitbucket_default_repo,
            ]
        )
        let state: ValidationState = r.ok ? .ok(r.message) : .error(r.message)
        await MainActor.run {
            self.bitbucketValidation = state
            if r.ok { withAnimation { self.step = .providers } }
        }
    }

    struct JSONResult {
        let ok: Bool
        let message: String
        let payload: [String: Any]?
    }

    private func postJSON(_ url: URL, body: [String: Any]) async -> JSONResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return JSONResult(ok: false, message: "Geçersiz yanıt", payload: nil)
            }
            if http.statusCode >= 500 {
                return JSONResult(ok: false,
                                  message: "Backend hatası HTTP \(http.statusCode)",
                                  payload: nil)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ok = (json["ok"] as? Bool) ?? false
                let message = (json["message"] as? String) ?? "?"
                return JSONResult(ok: ok, message: message, payload: json)
            }
            return JSONResult(ok: false, message: "Yanıt parse edilemedi", payload: nil)
        } catch {
            return JSONResult(ok: false,
                              message: "İstek başarısız: \(error.localizedDescription)",
                              payload: nil)
        }
    }

    /// Geri butonu — Roller atlandığında Projeler'den Providers'a doğrudan dön.
    private func goBack() {
        if step == .projects, selectedProviders.count <= 1 {
            withAnimation { step = .providers }
            return
        }
        withAnimation {
            step = Step(rawValue: step.rawValue - 1) ?? .welcome
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

                } else if template == .claude_code {
                    Text("API key gerekmez — terminalden `claude login` ile aboneliğinle (Pro/Max) giriş yapmış olman yeter. Maliyet Anthropic abonelik limitlerine sayılır.")
                        .font(.callout).foregroundStyle(.secondary)
                    HelpBox(
                        title: "Nasıl giriş yaparım?",
                        bullets: [
                            "Terminal aç: brew install --cask claude-code (yüklü değilse).",
                            "`claude login` çalıştır → tarayıcıda Claude.ai oturumunla onayla.",
                            "`claude --version` ve `claude -p 'merhaba'` ile test et."
                        ],
                        link: ("Claude Code docs", "https://docs.claude.com/en/docs/claude-code/overview")
                    )

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

/// Bitbucket repo seçim satırı — toggle ile draft.projects'e ekle/çıkar
private struct BitbucketRepoToggle: View {
    let repo: SetupWizardView.BitbucketRepoItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.slug).font(.body.weight(.medium))
                    if let n = repo.name, n != repo.slug {
                        Text(n).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let b = repo.default_branch, !b.isEmpty {
                    Text(b).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

/// Seçilen projenin ayrıntıları — Jira projesi multi-select + lokal klasör seçici.
private struct ProjectDetailCard: View {
    @Binding var project: ProjectConfig
    let availableJiraProjects: [SetupWizardView.JiraProjectItem]
    let onDelete: () -> Void

    /// jira_project_keys virgüllü string ↔ Set<String>
    private var selectedJiraKeys: Set<String> {
        Set(project.jira_project_keys
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    private func toggleJiraKey(_ key: String) {
        var keys = selectedJiraKeys
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        project.jira_project_keys = keys.sorted().joined(separator: ",")
    }

    private func pickLocalPath() {
        let panel = NSOpenPanel()
        panel.title = "Lokal repo klasörünü seç"
        panel.message = "\(project.slug) için klonladığın git klasörünü seç"
        panel.prompt = "Seç"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            project.local_repo_path = url.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(project.bitbucket_repo).font(.body.weight(.semibold))
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless)
            }

            // Görüntü ismi
            VStack(alignment: .leading, spacing: 4) {
                Text("Görünen isim").font(.caption).foregroundStyle(.secondary)
                TextField("örn Azerbaycan", text: $project.name)
                    .textFieldStyle(.roundedBorder)
            }

            // Jira projeleri (multi-select chip'ler)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bu repo'ya bağlı Jira projeleri").font(.caption).foregroundStyle(.secondary)
                if availableJiraProjects.isEmpty {
                    Text("Jira'dan proje listesi alınamadı — bu alanı virgüllü olarak elle gir:")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("CAPYBARZ,MOLENARS", text: $project.jira_project_keys)
                        .textFieldStyle(.roundedBorder)
                } else {
                    let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(availableJiraProjects) { jp in
                            JiraKeyChip(
                                key: jp.key,
                                name: jp.name,
                                isSelected: selectedJiraKeys.contains(jp.key),
                                onToggle: { toggleJiraKey(jp.key) }
                            )
                        }
                    }
                }
            }

            // Lokal repo yolu — sadece file picker, yazı kabul yok
            VStack(alignment: .leading, spacing: 4) {
                Text("Lokal repo klasörü").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: project.local_repo_path.isEmpty
                          ? "questionmark.folder" : "folder.fill.badge.gearshape")
                        .foregroundStyle(project.local_repo_path.isEmpty ? .orange : .green)
                    Text(project.local_repo_path.isEmpty
                         ? "Henüz seçilmedi"
                         : project.local_repo_path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Klasör Seç...", action: pickLocalPath)
                        .buttonStyle(.bordered)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }

            // Branch
            VStack(alignment: .leading, spacing: 4) {
                Text("Varsayılan branch").font(.caption).foregroundStyle(.secondary)
                TextField("dev", text: $project.git_default_branch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }
}

private struct JiraKeyChip: View {
    let key: String
    let name: String?
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                Text(key).font(.callout.monospaced())
                if let n = name, !n.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(n).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

/// Jira/Bitbucket bağlantı doğrulama mesajını gösteren inline banner.
private struct ValidationBanner: View {
    let state: SetupWizardView.ValidationState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Bağlantı doğrulanıyor...").font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        case .ok(let msg):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body)
                Text(msg).font(.callout).foregroundStyle(.primary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.10))
            .cornerRadius(8)
        case .error(let msg):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.body)
                Text(msg).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .cornerRadius(8)
        }
    }
}
