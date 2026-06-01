import SwiftUI

/// Jira task listesi + filtreler + detay (split-view).
struct JiraView: View {
    let client: APIClient
    let projectId: Int?

    @State private var tasks: [APIClient.JiraTask] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedTask: APIClient.JiraTask?

    // Filtreler
    @State private var assigneeFilter: AssigneeOption = .all
    @State private var categoryFilter: CategoryOption = .all
    @State private var textFilter: String = ""
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
        case all = "Hepsi"
        case todo = "To Do"
        case inProgress = "In Progress"
        case done = "Done"
        var queryValue: String? {
            switch self {
            case .all: return nil
            default: return rawValue
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                content
            }
            .frame(minWidth: 420, idealWidth: 480)
        } detail: {
            if let t = selectedTask {
                JiraDetailView(client: client, task: t, projectId: projectId,
                               onChanged: { Task { await refresh() } })
                    .id(t.id)
            } else {
                EmptyState("Seç", systemImage: "arrow.left",
                           description: "Soldan bir task seç")
            }
        }
        .task(id: filterKey) { await refresh() }
    }

    private var filterKey: String {
        "\(projectId ?? 0)-\(assigneeFilter.rawValue)-\(categoryFilter.rawValue)-\(textFilter)-\(jqlOverride)"
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $assigneeFilter) {
                    ForEach(AssigneeOption.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 160).labelsHidden()

                Picker("", selection: $categoryFilter) {
                    ForEach(CategoryOption.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 140).labelsHidden()

                TextField("Ara (summary/desc)", text: $textFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { Task { await refresh() } }

                Button {
                    Task { await refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
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
        if loading && tasks.isEmpty {
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
                JiraTaskRow(task: task)
                    .tag(task)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Data

    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            tasks = try await client.listJiraTasks(
                projectId: projectId,
                jql: jqlOverride.isEmpty ? nil : jqlOverride,
                assignee: assigneeFilter.queryValue,
                statusCategory: categoryFilter.queryValue,
                text: textFilter.isEmpty ? nil : textFilter,
                maxResults: 200
            )
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
}

private struct JiraTaskRow: View {
    let task: APIClient.JiraTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(.vertical, 4)
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
