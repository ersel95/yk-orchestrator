import SwiftUI
import AppKit

/// Genel proje editörü — DOĞRUDAN DB'ye (`PATCH /api/projects/{id}`) yazar.
/// Hem proje alanlarını (ad/repo/branch/jira) hem TestFlight (Xcode) yapılandırmasını
/// tek yerden yönetir. TestFlight artık ayrı klasör sormaz — `local_repo_path` kullanılır.
@MainActor
struct ProjectSettingsEditor: View {
    let client: APIClient
    let project: APIClient.ProjectInfo
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Genel alanlar
    @State private var name: String
    @State private var jiraKeys: String
    @State private var bbWorkspace: String
    @State private var bbRepo: String
    @State private var localPath: String
    @State private var branch: String

    // TestFlight / Xcode
    @State private var containerPath: String
    @State private var scheme: String
    @State private var teamId: String
    @State private var availableSchemes: [String] = []
    @State private var environments: [AppEnvironment] = []

    @State private var inspecting = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var saving = false

    init(client: APIClient, project: APIClient.ProjectInfo, onSaved: @escaping () -> Void) {
        self.client = client
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _jiraKeys = State(initialValue: project.jira_project_keys)
        _bbWorkspace = State(initialValue: project.bitbucket_workspace)
        _bbRepo = State(initialValue: project.bitbucket_repo)
        _localPath = State(initialValue: project.local_repo_path)
        _branch = State(initialValue: project.git_default_branch)
        _containerPath = State(initialValue: project.xcode_container_path ?? "")
        _scheme = State(initialValue: project.xcode_scheme ?? "")
        _teamId = State(initialValue: project.xcode_team_id ?? "")
        if let json = project.xcode_environments, let data = json.data(using: .utf8),
           let envs = try? JSONDecoder().decode([AppEnvironment].self, from: data) {
            _environments = State(initialValue: envs)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Proje: \(project.name)").font(.headline)
                Spacer()
                Button("Kapat") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                    Divider()
                    testflightSection
                    if let msg = statusMessage {
                        Label(msg, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                Button {
                    Task { await save() }
                } label: { Label("Kaydet", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    // MARK: - Genel

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Genel").font(.subheadline.weight(.semibold))
            labeled("Ad") { TextField("Ad", text: $name).textFieldStyle(.roundedBorder) }
            labeled("Jira anahtarları (virgüllü)") { TextField("MOLENARS", text: $jiraKeys).textFieldStyle(.roundedBorder) }
            labeled("Bitbucket project key") { TextField("COSADC", text: $bbWorkspace).textFieldStyle(.roundedBorder) }
            labeled("Bitbucket repo") { TextField("nl-adc-ios", text: $bbRepo).textFieldStyle(.roundedBorder) }
            labeled("Default branch") { TextField("dev", text: $branch).textFieldStyle(.roundedBorder) }
            labeled("Lokal repo yolu") {
                HStack {
                    TextField("/Users/…", text: $localPath).textFieldStyle(.roundedBorder)
                    Button("Seç…") { pickFolder() }
                }
            }
        }
    }

    // MARK: - TestFlight

    private var testflightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TestFlight / Xcode").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await configureTestFlight() }
                } label: {
                    if inspecting { ProgressView().controlSize(.small) }
                    else { Label("TestFlight yapılandır", systemImage: "wand.and.stars") }
                }
                .disabled(inspecting || localPath.isEmpty)
            }

            labeled("Xcode container") {
                HStack {
                    Text(containerPath.isEmpty ? "(otomatik bulunacak)" : (containerPath as NSString).lastPathComponent)
                        .font(.callout.monospaced()).foregroundStyle(containerPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Seç…") { pickContainer() }
                }
            }

            if !availableSchemes.isEmpty {
                labeled("Scheme") {
                    Picker("", selection: $scheme) {
                        ForEach(availableSchemes, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 260)
                }
            } else if !scheme.isEmpty {
                labeled("Scheme") { Text(scheme).font(.callout) }
            }

            if !teamId.isEmpty {
                labeled("Team ID") { Text(teamId).font(.callout.monospaced()) }
            }

            if !environments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment'lar").font(.caption).foregroundStyle(.secondary)
                    ForEach(environments) { env in
                        HStack(spacing: 6) {
                            Text(env.name).font(.caption.weight(.medium))
                            Text(env.bundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Henüz yapılandırılmadı. \"TestFlight yapılandır\" ile otomatik keşfet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func configureTestFlight() async {
        inspecting = true; statusMessage = nil; isError = false
        defer { inspecting = false }

        // Container belirle: alan dolu → onu; değil → repo altında ara
        var container = containerPath
        if container.isEmpty { container = ProjectBridge.findContainer(inDirectory: localPath) ?? "" }
        guard !container.isEmpty else {
            statusMessage = "Repo klasöründe .xcworkspace/.xcodeproj bulunamadı — \"Seç…\" ile elle göster."
            isError = true
            return
        }
        containerPath = container

        do {
            let result = try await ProjectInspector.inspect(containerURL: URL(fileURLWithPath: container))
            availableSchemes = result.schemes
            scheme = result.suggestedScheme
            teamId = result.teamId
            environments = result.environments
            statusMessage = "Keşfedildi: \(result.schemes.count) scheme, \(result.environments.count) environment. Kaydet'e bas."
        } catch {
            statusMessage = "Keşif başarısız: \(error.localizedDescription)"
            isError = true
        }
    }

    private func save() async {
        saving = true; statusMessage = nil; isError = false
        defer { saving = false }
        let firstEnv = environments.first
        let body = APIClient.ProjectPatchBody(
            name: name,
            jira_project_keys: jiraKeys,
            bitbucket_workspace: bbWorkspace,
            bitbucket_repo: bbRepo,
            local_repo_path: localPath,
            git_default_branch: branch,
            xcode_container_path: containerPath,
            xcode_scheme: scheme,
            xcode_configuration: firstEnv?.configuration ?? "",
            xcode_bundle_id: firstEnv?.bundleIdentifier ?? "",
            xcode_team_id: teamId,
            xcode_environments: ProjectBridge.encodeEnvironments(environments)
        )
        do {
            try await client.patchProject(id: project.id, body)
            onSaved()
            dismiss()
        } catch {
            statusMessage = "Kaydedilemedi: \(error.localizedDescription)"
            isError = true
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { localPath = url.path }
    }

    private func pickContainer() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true   // .xcworkspace/.xcodeproj birer paket (klasör)
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !localPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: localPath) }
        if panel.runModal() == .OK, let url = panel.url { containerPath = url.path }
    }

    @ViewBuilder
    private func labeled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
