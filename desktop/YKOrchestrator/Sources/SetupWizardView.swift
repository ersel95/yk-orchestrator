import SwiftUI

/// İlk açılış kurulum sihirbazı.
/// Adımlar: Welcome → Jira → Bitbucket → LM Studio → Projeler → Tamamla
struct SetupWizardView: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var sidecar: SidecarManager

    @State private var step: Step = .welcome
    @State private var draft: AppConfig = ConfigStore.shared.config

    @State private var jiraToken: String = ""
    @State private var bitbucketToken: String = ""

    @State private var saveError: String?

    enum Step: Int, CaseIterable {
        case welcome, jira, bitbucket, llm, projects, done
        var title: String {
            switch self {
            case .welcome:   return "Hoş geldin"
            case .jira:      return "Jira"
            case .bitbucket: return "Bitbucket"
            case .llm:       return "LM Studio"
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
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                stepBadge(s)
                if s != Step.allCases.last { Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1) }
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
        case .llm:       llmStep
        case .projects:  projectsStep
        case .done:      doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("YK Orchestrator'a hoş geldin")
                .font(.title2.weight(.semibold))
            Text("Bu sihirbaz Jira, Bitbucket ve LM Studio bağlantılarını yapılandıracak. Token'lar macOS Keychain'e güvenli olarak yazılır.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                preCheck("VPN bağlı olmalı (Jira/Bitbucket için)")
                preCheck("LM Studio çalışıyor ve model yüklü olmalı")
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

    private var jiraStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Jira bağlantısı")
            field("Base URL", placeholder: "https://sdlc.yapikredi.com.tr/jira",
                  text: $draft.jira_base_url)
            field("E-posta / kullanıcı", placeholder: "ersel@yapikredi.com.tr",
                  text: $draft.jira_email)
            SecureField("Personal Access Token", text: $jiraToken)
                .textFieldStyle(.roundedBorder)
            field("Proje anahtarları (virgüllü)", placeholder: "CAPYBARZ,MOLENARS",
                  text: $draft.jira_project_keys)
            Text("Token'lar macOS Keychain'e yazılır, dosyaya bırakılmaz.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var bitbucketStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Bitbucket Server bağlantısı")
            field("Base URL", placeholder: "https://sdlc.yapikredi.com.tr/bitbucket",
                  text: $draft.bitbucket_base_url)
            field("Kullanıcı adı", placeholder: "U0T19961",
                  text: $draft.bitbucket_username)
            SecureField("HTTP Access Token", text: $bitbucketToken)
                .textFieldStyle(.roundedBorder)
            field("Workspace (proje)", placeholder: "COSADC",
                  text: $draft.bitbucket_workspace)
            field("Varsayılan repo", placeholder: "az-adc-ios",
                  text: $draft.bitbucket_default_repo)
        }
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("LM Studio")
            field("Base URL", placeholder: "http://127.0.0.1:1234/v1",
                  text: $draft.llm_base_url)
            field("Genel model", placeholder: "qwen/qwen3.6-35b-a3b",
                  text: $draft.llm_model_general)
            field("Kod modeli", placeholder: "qwen/qwen3.6-35b-a3b",
                  text: $draft.llm_model_code)
            Text("LM Studio açık ve modeli yüklü olmalı. Backend ilk istekte modeli JIT yükler.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

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
                draft.projects.append(ProjectConfig(name: "Yeni Proje", slug: "proje-\(draft.projects.count + 1)"))
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
                Button("Geri") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
            }
            Spacer()
            Button(step == .done ? "Başlat" : (step == .projects ? "Bitir" : "İleri")) {
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func advance() {
        if step == .done {
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

    private func commit() {
        do {
            if !jiraToken.isEmpty {
                try KeychainStore.shared.set(jiraToken, for: "jira_api_token")
            }
            if !bitbucketToken.isEmpty {
                try KeychainStore.shared.set(bitbucketToken, for: "bitbucket_app_password")
            }
            var snap = draft
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
