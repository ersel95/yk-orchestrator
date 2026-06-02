import SwiftUI

/// Jira task listesi + filtreler + detay (split-view).
struct JiraView: View {
    let client: APIClient
    let projectId: Int?

    @State private var tasks: [APIClient.JiraTask] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedTask: APIClient.JiraTask?

    // Filtreler — kişi varsayılan: bana atanmış
    @State private var assigneeFilter: AssigneeOption = .mine
    @State private var categoryFilters: Set<CategoryOption> = []  // boş = hepsi
    @State private var textFilter: String = ""
    @State private var labelFilter: String = ""
    @State private var labelSuggestions: [String] = []
    @State private var labelSearchTask: Task<Void, Never>?
    @State private var jqlOverride: String = ""
    @State private var advancedOpen: Bool = false

    enum AssigneeOption: String, CaseIterable, Hashable {
        case all = "Hepsi"
        case mine = "Bana atanmış"
        case unassigned = "Atanmamış"
        var queryValue: String? {
            switch self {
            case .all: return nil
            case .mine: return "me"
            case .unassigned: return "unassigned"
            }
        }
    }
    enum CategoryOption: String, CaseIterable, Hashable {
        case todo = "To Do"
        case inProgress = "In Progress"
        case done = "Done"
    }

    var body: some View {
        // Dış MainView zaten NavigationSplitView — burada İKİNCİ bir split iç içe
        // girince ortada hayalet boş bir kolon oluşuyor. İki kolonlu HStack kullanıyoruz.
        GeometryReader { geo in
            let listW = min(CGFloat(420), max(CGFloat(320), geo.size.width * 0.40))
            let detailW = max(CGFloat(0), geo.size.width - listW - 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    content
                }
                .frame(width: listW, height: geo.size.height)
                Divider()
                Group {
                    if let t = selectedTask {
                        JiraDetailView(client: client, task: t, projectId: projectId,
                                       onChanged: { Task { await refresh() } })
                            .id(t.id)
                    } else {
                        EmptyState("Seç", systemImage: "arrow.left",
                                   description: "Soldan bir task seç")
                    }
                }
                .frame(width: detailW, height: geo.size.height)
            }
        }
        .task(id: filterKey) { await refresh() }
    }

    private var filterKey: String {
        let cats = categoryFilters.map(\.rawValue).sorted().joined(separator: ",")
        return "\(projectId ?? 0)-\(assigneeFilter.rawValue)-\(cats)-\(textFilter)-\(labelFilter)-\(jqlOverride)"
    }

    private func scheduleLabelSearch() {
        labelSearchTask?.cancel()
        let q = labelFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { labelSuggestions = []; return }
        labelSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            if let res = try? await client.listJiraLabels(query: q), !Task.isCancelled {
                labelSuggestions = res
            }
        }
    }

    private var categoryLabel: String {
        if categoryFilters.isEmpty { return "Durum: Hepsi" }
        if categoryFilters.count == 1 { return categoryFilters.first!.rawValue }
        return "\(categoryFilters.count) durum"
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $assigneeFilter) {
                    ForEach(AssigneeOption.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 160).labelsHidden()

                Menu {
                    ForEach(CategoryOption.allCases, id: \.self) { c in
                        Button {
                            if categoryFilters.contains(c) { categoryFilters.remove(c) }
                            else { categoryFilters.insert(c) }
                        } label: {
                            if categoryFilters.contains(c) { Label(c.rawValue, systemImage: "checkmark") }
                            else { Text(c.rawValue) }
                        }
                    }
                    if !categoryFilters.isEmpty {
                        Divider()
                        Button("Temizle") { categoryFilters.removeAll() }
                    }
                } label: {
                    Text(categoryLabel)
                }
                .frame(maxWidth: 150)

                TextField("Ara (summary/desc)", text: $textFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { Task { await refresh() } }

                Button {
                    Task { await refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
            // Etiket filtresi + autocomplete
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                TextField("Etikete göre filtrele", text: $labelFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onChange(of: labelFilter) { _, _ in scheduleLabelSearch() }
                    .onSubmit { Task { await refresh() } }
                if !labelFilter.isEmpty {
                    Button {
                        labelFilter = ""; labelSuggestions = []
                        Task { await refresh() }
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                ForEach(labelSuggestions.filter { $0 != labelFilter }.prefix(5), id: \.self) { s in
                    Button {
                        labelFilter = s; labelSuggestions = []
                        Task { await refresh() }
                    } label: {
                        Text(s).font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            DisclosureGroup("Gelişmiş JQL", isExpanded: $advancedOpen) {
                HStack(spacing: 6) {
                    TextField("project in (CAPYBARZ) AND ...", text: $jqlOverride)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onSubmit { Task { await refresh() } }
                    if !jqlOverride.isEmpty {
                        Button("Temizle") { jqlOverride = "" }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Jira'dan task'lar çekiliyor...").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 12) {
                EmptyState("Erişilemiyor", systemImage: "wifi.exclamationmark", description: error)
                Button("Tekrar dene") { Task { await refresh() } }
            }
        } else if tasks.isEmpty {
            EmptyState("Boş", systemImage: "checklist", description: "Bu filtreye uyan task yok.")
        } else {
            List(tasks, id: \.issue_key, selection: $selectedTask) { task in
                JiraTaskRow(task: task, isSelected: selectedTask?.issue_key == task.issue_key)
                    .tag(task)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Data

    private func refresh() async {
        loading = true; error = nil
        do {
            let result = try await client.listJiraTasks(
                projectId: projectId,
                jql: jqlOverride.isEmpty ? nil : jqlOverride,
                assignee: assigneeFilter.queryValue,
                statusCategory: categoryFilters.isEmpty ? nil : categoryFilters.map(\.rawValue).joined(separator: ","),
                text: textFilter.isEmpty ? nil : textFilter,
                label: labelFilter.isEmpty ? nil : labelFilter,
                maxResults: 200
            )
            // "Bana atanmış" görünümünde durum önceliğine göre sırala:
            // In Progress → To Do → diğer → Done (eşitlikte backend sırası = updated DESC korunur).
            if assigneeFilter == .mine {
                tasks = result.enumerated()
                    .sorted { a, b in
                        let ra = Self.statusRank(a.element.status), rb = Self.statusRank(b.element.status)
                        return ra != rb ? ra < rb : a.offset < b.offset
                    }
                    .map(\.element)
            } else {
                tasks = result
            }
            loading = false
        } catch {
            // İptal: yeni bir yükleme devraldı — loading'i kapatma, spinner dönsün.
            if error.isCancellation { return }
            self.error = vpnAwareMessage(error)
            loading = false
        }
    }

    /// Durum öncelik sırası: In Progress(0) → To Do(1) → diğer(2) → Done(3).
    private static func statusRank(_ status: String) -> Int {
        let s = status.lowercased()
        if s.contains("done") || s.contains("closed") || s.contains("resolved")
            || s.contains("tamam") || s.contains("kapal") { return 3 }
        if s.contains("progress") { return 0 }
        if s.contains("to do") || s.contains("todo") || s.contains("open")
            || s.contains("backlog") || s.contains("yapılacak") || s.contains("açık") { return 1 }
        return 2
    }

    private func vpnAwareMessage(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.contains("nodename") || raw.contains("HTTP 5") || raw.contains("not known") {
            return "Jira'ya bağlanılamıyor. VPN bağlı mı?\n\nDetay: \(raw)"
        }
        return raw
    }
}

private struct JiraTaskRow: View {
    let task: APIClient.JiraTask
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(typeColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(task.issue_key)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(typeColor.opacity(0.18))
                        .foregroundStyle(typeColor)
                        .cornerRadius(3)
                    Text(task.summary).font(.body.weight(.medium)).lineLimit(2)
                    Spacer()
                    statusBadge
                }
                HStack(spacing: 10) {
                    if let a = task.assignee {
                        Label(a, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Atanmamış", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let p = task.priority {
                        Label(p, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = task.sprint {
                        Label(s, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 9)
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.08 : 0.035), radius: isSelected ? 5 : 3, x: 0, y: 1)
    }

    private var typeColor: Color {
        switch (task.issue_type ?? "").lowercased() {
        case "bug": return .red
        case "story": return .green
        case "task": return .blue
        case "epic": return .purple
        case "sub-task", "subtask": return .gray
        default: return .accentColor
        }
    }

    private var statusBadge: some View {
        Text(task.status).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .cornerRadius(4)
    }
    private var statusColor: Color {
        let s = task.status.lowercased()
        if s.contains("done") || s.contains("closed") || s.contains("kapal") || s.contains("tamam") { return .green }
        if s.contains("progress") || s.contains("review") || s.contains("devam") { return .orange }
        if s.contains("block") || s.contains("hold") { return .red }
        return .secondary
    }
}
