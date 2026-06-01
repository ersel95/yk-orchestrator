import SwiftUI

/// PR listesi — backend `/api/pr/review` ve `/api/pr/cache`.
/// Sekmeler: Review Bekleyenler / Benim Açtıklarım (cache → is_mine).
struct PRListView: View {
    let client: APIClient
    let projectId: Int?

    @State private var prs: [APIClient.PullRequest] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedTab: Filter = .needsReview
    @State private var selectedPR: APIClient.PullRequest?

    enum Filter: String, CaseIterable {
        case needsReview = "Review bekliyor"
        case mine = "Benim açtıklarım"
        case all = "Tümü"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: projectId) { await refresh() }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $selectedTab) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            Spacer()

            Button {
                Task { await refresh() }
            } label: {
                Label("Yenile", systemImage: "arrow.clockwise")
            }
            .disabled(loading)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if loading && prs.isEmpty {
            ProgressView("PR listesi yükleniyor...").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            EmptyState("Hata", systemImage: "exclamationmark.triangle",
                                   description: error)
        } else if filtered.isEmpty {
            EmptyState("Boş", systemImage: "checklist",
                                   description: "Bu filtreye uyan PR yok.")
        } else {
            NavigationSplitView {
                List(filtered, id: \.pr_id, selection: $selectedPR) { pr in
                    NavigationLink(value: pr) {
                        PRRow(pr: pr)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 380, idealWidth: 440)
            } detail: {
                if let pr = selectedPR {
                    PRDetailView(client: client, pr: pr, projectId: projectId)
                } else {
                    EmptyState("Seç", systemImage: "arrow.left",
                                           description: "Soldan bir PR seç")
                }
            }
        }
    }

    private var filtered: [APIClient.PullRequest] {
        switch selectedTab {
        case .needsReview: return prs.filter { $0.needs_my_review }
        case .mine:        return prs.filter { $0.is_mine }
        case .all:         return prs
        }
    }

    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            prs = try await client.listForReview(projectId: projectId)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PRRow: View {
    let pr: APIClient.PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(pr.number)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
                statusBadge
            }
            HStack(spacing: 8) {
                Label(pr.author, systemImage: "person")
                    .font(.caption).foregroundStyle(.secondary)
                Label(pr.repo, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                if pr.needs_my_review {
                    Text("YENİ").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .cornerRadius(4)
                }
                if pr.has_my_unread_comment {
                    Image(systemName: "bubble.right.fill").font(.caption).foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let s = pr.my_status ?? pr.status {
            let (label, color) = badgeStyle(for: s)
            Text(label).font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .cornerRadius(4)
        }
    }

    private func badgeStyle(for status: String) -> (String, Color) {
        switch status {
        case "APPROVED":  return ("Onaylı", .green)
        case "NEEDS_WORK": return ("İşlenmeli", .red)
        default:           return ("Bekliyor", .secondary)
        }
    }
}
