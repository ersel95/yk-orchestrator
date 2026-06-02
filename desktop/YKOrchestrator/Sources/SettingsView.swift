import SwiftUI

/// Ayarlar — provider/rol/proje düzenleme. Wizard sonrasında buradan değiştir.
struct SettingsView: View {
    let client: APIClient

    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var sidecar: SidecarManager

    @State private var saveError: String?
    @State private var savedMessage: String?
    @State private var draft: AppConfig = ConfigStore.shared.config

    // Projeler artık DB'den (tek kaynak); config.json'dan değil.
    @State private var dbProjects: [APIClient.ProjectInfo] = []
    @State private var editingProject: APIClient.ProjectInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ayarlar").font(.title2.weight(.semibold))

                jiraSection
                bitbucketSection
                providersSection
                rolesSection
                projectsSection

                HStack {
                    if let err = saveError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else if let msg = savedMessage {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    Button {
                        save()
                    } label: { Label("Kaydet ve yeniden başlat", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .onAppear { draft = config.config }
        .task { await loadProjects() }
        .sheet(item: $editingProject) { proj in
            ProjectSettingsEditor(client: client, project: proj) {
                Task { await loadProjects() }
            }
        }
    }

    private func loadProjects() async {
        do { dbProjects = try await client.listProjects().projects }
        catch { if !error.isCancellation { saveError = "Projeler yüklenemedi: \(error.localizedDescription)" } }
    }

    private var jiraSection: some View {
        section("Jira") {
            field("Base URL", text: $draft.jira_base_url)
            field("E-posta (boş = Server PAT)", text: $draft.jira_email)
            field("Proje anahtarları (virgüllü)", text: $draft.jira_project_keys)
        }
    }

    private var bitbucketSection: some View {
        section("Bitbucket") {
            field("Base URL", text: $draft.bitbucket_base_url)
            field("Kullanıcı adı", text: $draft.bitbucket_username)
            field("Project Key", text: $draft.bitbucket_workspace)
            field("Varsayılan repo", text: $draft.bitbucket_default_repo)
        }
    }

    private var providersSection: some View {
        section("LLM Provider'lar") {
            if draft.providers.isEmpty {
                Text("Provider yok").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(draft.providers, id: \.id) { p in
                    HStack {
                        Text(p.id).font(.body.weight(.medium))
                        Text("·").foregroundStyle(.tertiary)
                        Text(p.kind).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        if !p.base_url.isEmpty {
                            Text(p.base_url).font(.caption.monospaced())
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
            }
            Text("Provider eklemek/kaldırmak için Wizard'ı tekrar açmak gerekir (ileride buraya inline editor eklenecek).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rolesSection: some View {
        section("Rol → Provider/Model") {
            ForEach(LLMRole.allCases) { role in
                HStack {
                    Text(role.title).font(.callout)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { draft.model_roles[role.rawValue]?.provider ?? "" },
                        set: { newP in
                            let model = draft.model_roles[role.rawValue]?.model ?? ""
                            draft.model_roles[role.rawValue] = RoleAssignmentEntry(provider: newP, model: model)
                        }
                    )) {
                        ForEach(draft.providers, id: \.id) { p in
                            Text(p.id).tag(p.id)
                        }
                    }
                    .frame(maxWidth: 180).labelsHidden()

                    TextField("model", text: Binding(
                        get: { draft.model_roles[role.rawValue]?.model ?? "" },
                        set: { newM in
                            let provider = draft.model_roles[role.rawValue]?.provider ?? draft.providers.first?.id ?? ""
                            draft.model_roles[role.rawValue] = RoleAssignmentEntry(provider: provider, model: newM)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    private var projectsSection: some View {
        section("Projeler") {
            if dbProjects.isEmpty {
                Text("Proje yok").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(dbProjects) { p in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.name).font(.callout.weight(.medium))
                                if testflightReady(p) {
                                    Label("TestFlight hazır", systemImage: "paperplane.fill")
                                        .font(.caption2).foregroundStyle(.green)
                                } else {
                                    Label("TestFlight yapılandırılmadı", systemImage: "paperplane")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text(p.local_repo_path.isEmpty ? "yol yok" : p.local_repo_path)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Düzenle") { editingProject = p }
                    }
                    .innerPanel(padding: 10)
                }
            }
        }
    }

    private func testflightReady(_ p: APIClient.ProjectInfo) -> Bool {
        !(p.xcode_scheme ?? "").isEmpty
            && !(p.xcode_environments ?? "").isEmpty
            && (!(p.xcode_container_path ?? "").isEmpty || !p.local_repo_path.isEmpty)
    }

    // MARK: - helpers

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .surfaceCard(padding: 16)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        do {
            try config.save(draft)
            sidecar.restart(config: config.snapshot)
            saveError = nil
            savedMessage = "Kaydedildi ve sidecar yeniden başlatıldı"
        } catch {
            saveError = error.localizedDescription
            savedMessage = nil
        }
    }
}
