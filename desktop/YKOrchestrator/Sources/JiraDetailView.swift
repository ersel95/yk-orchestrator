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
    @State private var loading: Bool = true   // ilk render dolu olsun ki .task tetiklensin (boş Group zero-size = .task ölür)
    @State private var error: String?

    // Inline edit state
    @State private var editingSummary: Bool = false
    @State private var summaryDraft: String = ""
    @State private var editingDescription: Bool = false
    @State private var descriptionDraft: String = ""
    @State private var editingAssignee: Bool = false
    @State private var assigneeQuery: String = ""
    @State private var assigneeSearchTask: Task<Void, Never>?

    @State private var labelsEditing: Bool = false
    @State private var labelsList: [String] = []
    @State private var labelInput: String = ""
    @State private var labelSuggestions: [String] = []
    @State private var labelSearchTask: Task<Void, Never>?

    // Priority / sprint / fix versions seçenekleri (lazy yüklenir)
    @State private var priorities: [APIClient.JiraPriority] = []
    @State private var sprints: [APIClient.JiraSprint] = []
    @State private var versions: [APIClient.JiraVersion] = []
    @State private var fixVersionsEditing: Bool = false
    @State private var fixVersionsDraft: Set<String> = []
    @State private var sprintLabel: String?  // optimistik gösterim (detail raw'da sprint decode edilmiyor)

    @State private var commentDraft: String = ""
    @State private var commentInflight: Bool = false
    @State private var activityTab: ActivityTab = .all

    enum ActivityTab: String, CaseIterable, Hashable {
        case all = "Tümü"
        case comments = "Yorumlar"
        case history = "Geçmiş"
    }

    @State private var actionInFlight: Bool = false
    @State private var actionMessage: String?
    @State private var showAgentSheet: Bool = false
    @State private var issueBranches: [APIClient.BBBranch] = []  // bu issue için mevcut branch'ler

    var body: some View {
        Group {
            if loading && detail == nil {
                ProgressView("Detay yükleniyor...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = error {
                VStack(spacing: 12) {
                    EmptyState("Erişilemiyor", systemImage: "wifi.exclamationmark", description: err)
                    Button("Tekrar dene") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = detail, let f = d.fields {
                scrollBody(d, f)
            }
        }
        .task(id: task.id) { sprintLabel = task.sprint; await load() }
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

    private func scrollBody(_ d: APIClient.JiraIssueDetail, _ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(d, f).surfaceCard()

                if let msg = actionMessage {
                    Label(msg, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .innerPanel(padding: 10)
                }

                VStack(alignment: .leading, spacing: 14) {
                    summarySection(f)
                    Divider()
                    descriptionSection(f, d.renderedFields)
                }
                .surfaceCard()

                VStack(alignment: .leading, spacing: 14) {
                    statusBar(f)
                    Divider()
                    sidebarFields(f)
                }
                .surfaceCard()

                attachmentsSection(f)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Etkinlik").font(.callout.weight(.semibold))
                        Spacer()
                        Picker("", selection: $activityTab) {
                            ForEach(ActivityTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        .labelsHidden()
                    }
                    if activityTab != .history {
                        commentsSection(f, d.renderedFields)
                    }
                    if activityTab != .comments {
                        if activityTab == .all { Divider() }
                        historySection(d.changelog)
                    }
                    Divider()
                    commentComposer
                }
                .surfaceCard()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
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
                if issueBranches.isEmpty {
                    Button {
                        Task { await createBranch() }
                    } label: { Label("Branch oluştur", systemImage: "arrow.triangle.branch") }
                        .buttonStyle(.bordered)
                        .disabled(actionInFlight)
                }

                Button {
                    showAgentSheet = true
                } label: { Label("Claude Agent", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(actionInFlight)
            }

            if !issueBranches.isEmpty {
                branchInfoView
            }
        }
    }

    /// Bu issue için açılmış branch'ler + ahead/behind durumu.
    private var branchInfoView: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(issueBranches) { b in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.green)
                    Text(b.displayId).font(.caption.monospaced())
                    if let ab = b.metadata?.aheadBehind {
                        let ahead = ab.ahead ?? 0
                        let behind = ab.behind ?? 0
                        if ahead > 0 { Text("↑\(ahead)").font(.caption2.monospaced()).foregroundStyle(.green) }
                        if behind > 0 { Text("↓\(behind)").font(.caption2.monospaced()).foregroundStyle(.orange) }
                        if ahead == 0 && behind == 0 {
                            Label("güncel", systemImage: "checkmark.seal")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10))
                .cornerRadius(6)
            }
            Button {
                Task { await createBranch() }
            } label: { Label("Yeni branch oluştur", systemImage: "plus") }
                .buttonStyle(.borderless).font(.caption).disabled(actionInFlight)
        }
    }

    private func statusBar(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        HStack(spacing: 8) {
            Text("Durum").font(.caption).foregroundStyle(.secondary)
            Menu {
                if transitions.isEmpty {
                    Text("Geçiş yok")
                } else {
                    ForEach(transitions) { tr in
                        Button {
                            Task { await doTransition(tr) }
                        } label: {
                            // tr.name = aksiyon (Done/On Hold…); to.name = hedef durum
                            Label(tr.to?.name ?? tr.name, systemImage: "arrow.right.circle")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(f.status?.name ?? "—").font(.callout.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(actionInFlight || transitions.isEmpty)
            Spacer()
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

    private func descriptionSection(_ f: APIClient.JiraIssueDetail.JiraFields,
                                    _ rendered: APIClient.JiraIssueDetail.RenderedFields?) -> some View {
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
            } else if let html = rendered?.description, !html.isEmpty {
                HTMLText(html: html)   // Jira formatlı (HTML) açıklama
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
                    TextField("İsim yaz (ör. Erse)", text: $assigneeQuery)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: assigneeQuery) { _, _ in scheduleAssigneeSearch() }
                        .onSubmit { Task { await fetchAssignableUsers() } }
                    if assignableUsers.isEmpty {
                        Text(assigneeQuery.count < 2 ? "En az 2 harf yaz" : "Aranıyor…")
                            .font(.caption).foregroundStyle(.secondary)
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

            // Labels — tag (chip) + autocomplete
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Etiketler").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if labelsEditing {
                        Button("Kaydet") { Task { await saveLabels() } }
                            .buttonStyle(.borderedProminent).disabled(actionInFlight)
                        Button("İptal") { labelsEditing = false }
                    } else {
                        Button {
                            labelsList = f.labels ?? []
                            labelInput = ""; labelSuggestions = []
                            labelsEditing = true
                        } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                    }
                }
                if labelsEditing {
                    if !labelsList.isEmpty {
                        labelChips(labelsList, removable: true)
                    }
                    TextField("Etiket ara/ekle…", text: $labelInput)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: labelInput) { _, _ in scheduleLabelSearch() }
                        .onSubmit { addLabel(labelInput) }
                    ForEach(labelSuggestions.filter { !labelsList.contains($0) }.prefix(6), id: \.self) { s in
                        Button { addLabel(s) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "tag").font(.caption).foregroundStyle(.tint)
                                Text(s).font(.callout)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                } else if let ls = f.labels, !ls.isEmpty {
                    labelChips(ls, removable: false)
                } else {
                    Text("(yok)").font(.callout).foregroundStyle(.secondary)
                }
            }

            prioritySection(f)
            sprintSection(f)
            fixVersionsSection(f)

            // Reporter (read-only)
            if let r = f.reporter {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Raporlayan").font(.caption).foregroundStyle(.secondary)
                    Text(r.displayName ?? r.name ?? "—").font(.callout)
                }
            }
        }
    }

    private func prioritySection(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Öncelik").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(priorities) { p in
                    Button {
                        Task { await setPriority(p.name) }
                    } label: {
                        if f.priority?.name == p.name {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Label(f.priority?.name ?? "—", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(actionInFlight)
            .task { if priorities.isEmpty { await loadPriorities() } }
        }
    }

    private func sprintSection(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sprint").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button { Task { await setSprint(nil, label: "Backlog") } } label: {
                    Text("Backlog (sprint yok)")
                }
                if !sprints.isEmpty { Divider() }
                ForEach(sprints) { sp in
                    Button { Task { await setSprint(sp.id, label: sp.name) } } label: {
                        Text(sp.state == "active" ? "\(sp.name)  • aktif" : sp.name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Label(sprintLabel ?? "Backlog", systemImage: "flag.checkered")
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(actionInFlight)
            .task { if sprints.isEmpty { await loadSprints() } }
        }
    }

    private func fixVersionsSection(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fix Versions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if fixVersionsEditing {
                    Button("Kaydet") { Task { await saveFixVersions() } }
                        .buttonStyle(.borderedProminent).disabled(actionInFlight)
                    Button("İptal") { fixVersionsEditing = false }
                } else {
                    Button {
                        fixVersionsDraft = Set((f.fixVersions ?? []).compactMap { $0.id })
                        fixVersionsEditing = true
                        Task { await loadVersions() }
                    } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                }
            }
            if fixVersionsEditing {
                let selectable = versions.filter { $0.archived != true }
                if selectable.isEmpty {
                    Text("Yükleniyor / versiyon yok").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(selectable) { v in
                    Button {
                        if fixVersionsDraft.contains(v.id) { fixVersionsDraft.remove(v.id) }
                        else { fixVersionsDraft.insert(v.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: fixVersionsDraft.contains(v.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(fixVersionsDraft.contains(v.id) ? Color.accentColor : .secondary)
                            Text(v.name).font(.callout)
                            if v.released == true {
                                Text("released").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            } else if let vs = f.fixVersions, !vs.isEmpty {
                HStack {
                    ForEach(vs, id: \.self) { v in
                        Text(v.name ?? "?").font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            } else {
                Text("(yok)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var commentComposer: some View {
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

    // MARK: - Yorumlar / Ekler / Geçmiş

    private func commentsSection(_ f: APIClient.JiraIssueDetail.JiraFields,
                                 _ rendered: APIClient.JiraIssueDetail.RenderedFields?) -> some View {
        let comments = f.comment?.comments ?? []
        // id → rendered HTML eşlemesi
        let renderedById: [String: String] = Dictionary(
            uniqueKeysWithValues: (rendered?.comment?.comments ?? []).compactMap { rc in
                (rc.id != nil && rc.body != nil) ? (rc.id!, rc.body!) : nil
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text("Yorumlar (\(comments.count))").font(.callout.weight(.medium))
            if comments.isEmpty {
                Text("Henüz yorum yok").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(comments) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill").foregroundStyle(.tint)
                            Text(c.author?.displayName ?? c.author?.name ?? "?")
                                .font(.caption.weight(.semibold))
                            Text(prettyDate(c.created)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                        if let html = renderedById[c.id], !html.isEmpty {
                            HTMLText(html: html)
                        } else {
                            Text(c.body ?? "").font(.callout).textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentsSection(_ f: APIClient.JiraIssueDetail.JiraFields) -> some View {
        let atts = f.attachment ?? []
        if !atts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ekler (\(atts.count))").font(.callout.weight(.medium))
                ForEach(atts) { a in
                    HStack(spacing: 8) {
                        Image(systemName: iconForMime(a.mimeType))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.filename ?? "ek").font(.callout)
                            HStack(spacing: 6) {
                                if let s = a.size { Text(humanSize(s)).font(.caption2).foregroundStyle(.secondary) }
                                Text(prettyDate(a.created)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let urlStr = a.content, let url = URL(string: urlStr) {
                            Link("Aç", destination: url).font(.caption)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
            }
            .surfaceCard()
        }
    }

    @ViewBuilder
    private func historySection(_ changelog: APIClient.JiraIssueDetail.Changelog?) -> some View {
        let histories = changelog?.histories ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text("Geçmiş").font(.callout.weight(.medium))
            if histories.isEmpty {
                Text("Geçmiş kaydı yok").font(.caption).foregroundStyle(.secondary)
            } else {
                // En yeni üstte
                ForEach(histories.reversed()) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(h.author?.displayName ?? h.author?.name ?? "?")
                                .font(.caption.weight(.semibold))
                            Text(prettyDate(h.created)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(Array((h.items ?? []).enumerated()), id: \.offset) { _, item in
                            HistoryItemRow(
                                field: item.field ?? "",
                                from: item.fromString ?? "—",
                                to: item.toString ?? "—"
                            )
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // ISO8601 → kısa okunur tarih
    private func prettyDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return String(iso.prefix(16)) }
        let out = DateFormatter()
        out.dateFormat = "dd.MM.yyyy HH:mm"
        return out.string(from: date)
    }

    private func humanSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private func iconForMime(_ mime: String?) -> String {
        let m = (mime ?? "").lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.contains("zip") || m.contains("compress") { return "doc.zipper" }
        return "paperclip"
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
            if error.isCancellation { return }  // yeni yükleme başladı; iptali yut
            self.error = vpnAwareMessage(error)
        }
        loading = false
        // Branch (Bitbucket) opsiyonel + detay render'ını BLOKE ETMEZ — ayrı, hata yutulur
        issueBranches = (try? await client.bbBranches(projectId: projectId, filter: task.issue_key)) ?? []
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

    @ViewBuilder
    private func labelChips(_ labels: [String], removable: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 220), spacing: 6, alignment: .leading)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(labels, id: \.self) { l in
                HStack(spacing: 4) {
                    Text(l).font(.caption)
                    if removable {
                        Button { labelsList.removeAll { $0 == l } } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(removable ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.15))
                .cornerRadius(10)
            }
        }
    }

    private func scheduleLabelSearch() {
        labelSearchTask?.cancel()
        let q = labelInput.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { labelSuggestions = []; return }
        labelSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            do {
                let res = try await client.listJiraLabels(query: q)
                if !Task.isCancelled { labelSuggestions = res }
            } catch { if !error.isCancellation { /* sessiz */ } }
        }
    }

    private func addLabel(_ raw: String) {
        let l = raw.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, !labelsList.contains(l) else { labelInput = ""; return }
        labelsList.append(l)
        labelInput = ""
        labelSuggestions = []
    }

    private func saveLabels() async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        // Input'ta yazılı kalan etiketi de dahil et
        addLabel(labelInput)
        do {
            try await client.setJiraLabels(task.issue_key, labels: labelsList, projectId: projectId)
            labelsEditing = false
            await load()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    /// Yazarken (debounce'lu) kişi araması — Jira'nın default davranışı gibi.
    private func scheduleAssigneeSearch() {
        assigneeSearchTask?.cancel()
        let q = assigneeQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { assignableUsers = []; return }
        assigneeSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce
            if Task.isCancelled { return }
            await fetchAssignableUsers()
        }
    }

    private func fetchAssignableUsers() async {
        do {
            let project = String(task.issue_key.split(separator: "-").first ?? "")
            assignableUsers = try await client.assignableJiraUsers(
                project: project, issueKey: task.issue_key, query: assigneeQuery
            )
        } catch {
            if error.isCancellation { return }
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
        actionInFlight = true; actionMessage = "Branch oluşturuluyor…"
        defer { actionInFlight = false }
        do {
            let res = try await client.createBranchFromJira(task.issue_key, projectId: projectId)
            actionMessage = "✅ Branch oluşturuldu: \(res.branch ?? "?")  (source: \(res.source_branch ?? "?"))"
            await load()  // yeni yorum (branch link) görünsün
        } catch {
            if error.isCancellation { return }
            actionMessage = "⚠️ Branch oluşturulamadı: \(error.localizedDescription)"
        }
    }

    // MARK: - Priority / sprint / fix versions

    private func loadPriorities() async {
        do { priorities = try await client.listJiraPriorities() }
        catch { actionMessage = "Öncelik listesi: \(error.localizedDescription)" }
    }

    private func loadSprints() async {
        do { sprints = try await client.listJiraSprints(issueKey: task.issue_key) }
        catch { actionMessage = "Sprint listesi: \(error.localizedDescription)" }
    }

    private func loadVersions() async {
        do { versions = try await client.listJiraVersions(issueKey: task.issue_key) }
        catch { actionMessage = "Versiyon listesi: \(error.localizedDescription)" }
    }

    private func setPriority(_ name: String) async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.setJiraPriority(task.issue_key, priorityName: name, projectId: projectId)
            await load(); onChanged()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func setSprint(_ sprintId: Int?, label: String) async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.setJiraSprint(task.issue_key, sprintId: sprintId, projectId: projectId)
            sprintLabel = label
            onChanged()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }

    private func saveFixVersions() async {
        actionInFlight = true; actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.setJiraFixVersions(
                task.issue_key, versionIds: Array(fixVersionsDraft), projectId: projectId
            )
            fixVersionsEditing = false
            await load()
        } catch { actionMessage = "Hata: \(error.localizedDescription)" }
    }
}

/// Geçmiş satırı — uzun değer değişikliklerini kısa önizler, "Göster" ile açar.
private struct HistoryItemRow: View {
    let field: String
    let from: String
    let to: String
    @State private var expanded = false

    private var isLong: Bool { from.count + to.count > 80 }

    var body: some View {
        if isLong {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(field).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(expanded ? "Gizle" : "Göster") { withAnimation { expanded.toggle() } }
                        .font(.caption2).buttonStyle(.borderless)
                }
                if expanded {
                    Text(from).font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label("yeni değer", systemImage: "arrow.down").font(.caption2).foregroundStyle(.tertiary)
                    Text(to).font(.caption2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("\(preview(from)) → \(preview(to))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(5)
        } else {
            HStack(spacing: 4) {
                Text(field).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(from).font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(to).font(.caption2)
            }
        }
    }

    private func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 40 ? String(one.prefix(40)) + "…" : one
    }
}
