import SwiftUI

/// Bir Jira task'ın detay ekranı — tüm alanlar editlenebilir.
struct JiraDetailView: View {
    let client: APIClient
    let task: APIClient.JiraTask
    let projectId: Int?
    let onChanged: () -> Void

    @State private var detail: APIClient.JiraIssueDetail?
    @State private var transitions: [APIClient.JiraTransition] = []
    @State private var assignableUsers: [APIClient.JiraUserDetail] = []
    @State private var loading: Bool = false
    @State private var error: String?

    // Inline edit state
    @State private var editingSummary: Bool = false
    @State private var summaryDraft: String = ""
    @State private var editingDescription: Bool = false
    @State private var descriptionDraft: String = ""
    @State private var editingAssignee: Bool = false
    @State private var assigneeQuery: String = ""

    @State private var labelsDraft: String = ""
    @State private var labelsEditing: Bool = false

    @State private var commentDraft: String = ""
    @State private var commentInflight: Bool = false

    @State private var actionInFlight: Bool = false
    @State private var actionMessage: String?
    @State private var showAgentSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading && detail == nil {
                    ProgressView("Detay yükleniyor...").padding()
                } else if let err = error {
                    EmptyState("Erişilemiyor", systemImage: "wifi.exclamationmark", description: err)
                    Button("Tekrar dene") { Task { await load() } }
                } else if let d = detail, let f = d.fields {
                    headerSection(d, f)
                    Divider()
                    statusBar(f)
                    summarySection(f)
                    descriptionSection(f)
                    sidebarFields(f)
                    Divider()
                    commentSection
                    if let msg = actionMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .task(id: task.id) { await load() }
        .navigationTitle("\(task.issue_key) — \(task.summary)")
        .sheet(isPresented: $showAgentSheet) {
            AgentSheet(
                client: client,
                jiraKey: task.issue_key,
                jiraSummary: task.summary,
                projectId: projectId,
                isPresented: $showAgentSheet
            )
        }
    }

    // MARK: - Sections

    private func headerSection(_ d: APIClient.JiraIssueDetail, _ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(d.key).font(.title3.monospaced().weight(.semibold))
                if let t = f.issuetype?.name {
                    Text(t).font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(4)
                }
                if let p = f.priority?.name {
                    Label(p, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("Jira'da aç", destination: URL(string: task.url)!)
                    .font(.caption)
            }
            HStack(spacing: 14) {
                Button {
                    Task { await createBranch() }
                } label: { Label("Branch oluştur", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(.bordered)
                    .disabled(actionInFlight)

                Button {
                    showAgentSheet = true
                } label: { Label("Claude Agent", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(actionInFlight)
            }
        }
    }

    private func statusBar(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Durum").font(.caption).foregroundStyle(.secondary)
                Text(f.status?.name ?? "—").font(.callout.weight(.medium))
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(transitions) { tr in
                    Button {
                        Task { await doTransition(tr) }
                    } label: {
                        Text(tr.name).font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(actionInFlight)
                }
            }
        }
    }

    private func summarySection(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Özet").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editingSummary {
                    Button("Kaydet") { Task { await saveSummary() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(actionInFlight)
                    Button("İptal") { editingSummary = false }
                } else {
                    Button {
                        summaryDraft = f.summary ?? ""
                        editingSummary = true
                    } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                }
            }
            if editingSummary {
                TextField("Özet", text: $summaryDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(f.summary ?? "")
                    .font(.title3.weight(.medium))
                    .textSelection(.enabled)
            }
        }
    }

    private func descriptionSection(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Açıklama").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editingDescription {
                    Button("Kaydet") { Task { await saveDescription() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(actionInFlight)
                    Button("İptal") { editingDescription = false }
                } else {
                    Button {
                        descriptionDraft = f.description ?? ""
                        editingDescription = true
                    } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                }
            }
            if editingDescription {
                TextEditor(text: $descriptionDraft)
                    .font(.callout.monospaced())
                    .frame(minHeight: 120, maxHeight: 280)
                    .border(Color.secondary.opacity(0.3))
            } else {
                Text(f.description ?? "(boş)")
                    .font(.callout)
                    .foregroundStyle(f.description?.isEmpty == false ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sidebarFields(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Assignee
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Atanan").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if editingAssignee {
                        Button("Kapat") { editingAssignee = false }
                    } else {
                        Button {
                            editingAssignee = true
                            Task { await fetchAssignableUsers() }
                        } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                    }
                }
                if editingAssignee {
                    TextField("Kullanıcı ara", text: $assigneeQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await fetchAssignableUsers() } }
                    if assignableUsers.isEmpty {
                        Text("Yazıp Enter'a bas").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(assignableUsers.prefix(8)) { u in
                        Button {
                            Task { await setAssignee(username: u.name) }
                        } label: {
                            HStack {
                                Image(systemName: "person.fill").foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(u.displayName ?? u.name ?? "?").font(.callout)
                                    if let n = u.name { Text(n).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                    Button("Atamayı kaldır") { Task { await setAssignee(username: nil) } }
                        .font(.caption)
                } else {
                    Text(f.assignee?.displayName ?? f.assignee?.name ?? "Atanmamış")
                        .font(.callout)
                        .foregroundStyle(f.assignee == nil ? .orange : .primary)
                }
            }

            // Labels
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Etiketler").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if labelsEditing {
                        Button("Kaydet") { Task { await saveLabels() } }
                            .buttonStyle(.borderedProminent).disabled(actionInFlight)
                        Button("İptal") { labelsEditing = false }
                    } else {
                        Button {
                            labelsDraft = (f.labels ?? []).joined(separator: ", ")
                            labelsEditing = true
                        } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                    }
                }
                if labelsEditing {
                    TextField("virgüllü etiketler", text: $labelsDraft)
                        .textFieldStyle(.roundedBorder)
                } else if let ls = f.labels, !ls.isEmpty {
                    HStack {
                        ForEach(ls, id: \.self) { l in
                            Text(l).font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                } else {
                    Text("(yok)").font(.callout).foregroundStyle(.secondary)
                }
            }

            // Reporter (read-only)
            if let r = f.reporter {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Raporlayan").font(.caption).foregroundStyle(.secondary)
                    Text(r.displayName ?? r.name ?? "—").font(.callout)
                }
            }
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Yorum Ekle").font(.callout.weight(.medium))
            TextEditor(text: $commentDraft)
                .font(.callout)
                .frame(minHeight: 80, maxHeight: 160)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button {
                    Task { await postComment() }
                } label: {
                    Label("Yorum Yap", systemImage: "bubble.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commentInflight)
            }
        }
    }

    // MARK: - Data calls

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            async let detailTask = client.getJiraTask(task.issue_key)
            async let trTask = client.getJiraTransitions(task.issue_key)
            let (d, tr) = try await (detailTask, trTask)
            self.detail = d
            self.transitions = tr
        } catch {
            self.error = vpnAwareMessage(error)
        }
    }

    private func vpnAwareMessage(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.contains("nodename") || raw.contains("HTTP 5") || raw.contains("not known") {
            return "Jira'ya bağlanılamıyor. VPN bağlı mı?\n\nDetay: \(raw)"
        }
        return raw
    }

    private func doTransition(_ tr: APIClient.JiraTransition) async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            let res = try await client.transitionJira(task.issue_key, transitionId: tr.id, projectId: projectId)
            actionMessage = "Durum: \(res.from ?? "?") → \(res.to ?? "?")"
            await load(); onChanged()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func saveSummary() async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.setJiraSummary(task.issue_key, summary: summaryDraft, projectId: projectId)
            editingSummary = false
            await load(); onChanged()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func saveDescription() async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.setJiraDescription(task.issue_key, description: descriptionDraft, projectId: projectId)
            editingDescription = false
            await load()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func saveLabels() async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        let labels = labelsDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try await client.setJiraLabels(task.issue_key, labels: labels, projectId: projectId)
            labelsEditing = false
            await load()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func fetchAssignableUsers() async {
        do {
            let project = String(task.issue_key.split(separator: "-").first ?? "")
            assignableUsers = try await client.assignableJiraUsers(
                project: project, issueKey: task.issue_key, query: assigneeQuery
            )
        } catch {
            actionMessage = "Kullanıcı listesi: \(error.localizedDescription)"
        }
    }

    private func setAssignee(username: String?) async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.setJiraAssignee(task.issue_key, username: username, projectId: projectId)
            editingAssignee = false
            await load(); onChanged()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func postComment() async {
        commentInflight = true; actionMessage = nil
        defer { commentInflight = false }
        do {
            try await client.addJiraComment(task.issue_key, body: commentDraft, projectId: projectId)
            commentDraft = ""
            actionMessage = "Yorum eklendi"
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func createBranch() async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            let res = try await client.createBranchFromJira(task.issue_key, projectId: projectId)
            actionMessage = "Branch: \(res.branch ?? "?")"
        } catch { actionMessage = "Branch: \(error.localizedDescription)" }
    }
}
