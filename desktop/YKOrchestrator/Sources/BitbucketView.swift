import SwiftUI

/// Bitbucket sekmesi (v1.2) — branch / commit / tag listeleri.
/// PR'lar ayrı sekmede tutulur (PRListView).
struct BitbucketView: View {
    let client: APIClient
    let projectId: Int?

    @State private var tab: SubTab = .branches
    @State private var loading = false
    @State private var error: String?

    @State private var branches: [APIClient.BBBranch] = []
    @State private var commits: [APIClient.BBCommit] = []
    @State private var tags: [APIClient.BBTag] = []

    @State private var branchFilter: String = ""
    @State private var commitBranch: String = ""

    enum SubTab: String, CaseIterable, Hashable {
        case branches = "Branch'lar"
        case commits = "Commit'ler"
        case tags = "Tag'ler"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: tabKey) { await refresh() }
    }

    private var tabKey: String { "\(projectId ?? 0)-\(tab.rawValue)-\(branchFilter)-\(commitBranch)" }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(SubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                Spacer()
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
            switch tab {
            case .branches:
                TextField("Branch ara (filter)", text: $branchFilter)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await refresh() } }
            case .commits:
                TextField("Branch (örn develop, boş = HEAD)", text: $commitBranch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await refresh() } }
            case .tags:
                EmptyView()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Yükleniyor...").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            EmptyState("Erişilemiyor", systemImage: "wifi.exclamationmark", description: error)
        } else {
            switch tab {
            case .branches: branchesList
            case .commits:  commitsList
            case .tags:     tagsList
            }
        }
    }

    // MARK: - Lists

    private var branchesList: some View {
        if branches.isEmpty {
            return AnyView(EmptyState("Boş", systemImage: "arrow.triangle.branch", description: "Branch bulunamadı."))
        }
        return AnyView(
            List(branches) { b in
                BBBranchRow(branch: b)
            }
            .listStyle(.inset)
        )
    }

    private var commitsList: some View {
        if commits.isEmpty {
            return AnyView(EmptyState("Boş", systemImage: "circle.dotted", description: "Commit bulunamadı."))
        }
        return AnyView(
            List(commits) { c in
                BBCommitRow(commit: c)
            }
            .listStyle(.inset)
        )
    }

    private var tagsList: some View {
        if tags.isEmpty {
            return AnyView(EmptyState("Boş", systemImage: "tag", description: "Tag bulunamadı."))
        }
        return AnyView(
            List(tags) { t in
                HStack {
                    Image(systemName: "tag")
                    Text(t.displayId).font(.callout.weight(.medium))
                    Spacer()
                    if let c = t.latestCommit { Text(c.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            .listStyle(.inset)
        )
    }

    // MARK: - Data

    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            switch tab {
            case .branches:
                branches = try await client.bbBranches(projectId: projectId, filter: branchFilter)
            case .commits:
                let br = commitBranch.isEmpty ? nil : commitBranch
                commits = try await client.bbCommits(projectId: projectId, branch: br)
            case .tags:
                tags = try await client.bbTags(projectId: projectId)
            }
        } catch {
            self.error = vpnAwareMessage(error)
        }
    }

    private func vpnAwareMessage(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.contains("nodename") || raw.contains("not known") || raw.contains("HTTP 5") {
            return "Bitbucket'a bağlanılamıyor. VPN bağlı mı?\n\nDetay: \(raw)"
        }
        return raw
    }
}

private struct BBBranchRow: View {
    let branch: APIClient.BBBranch
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: branch.default == true ? "star.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.default == true ? .yellow : .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(branch.displayId).font(.body.weight(.medium))
                    Spacer()
                    if let ab = branch.metadata?.aheadBehind {
                        if let a = ab.ahead, a > 0 {
                            Text("↑\(a)").font(.caption.monospaced()).foregroundStyle(.green)
                        }
                        if let b = ab.behind, b > 0 {
                            Text("↓\(b)").font(.caption.monospaced()).foregroundStyle(.red)
                        }
                    }
                }
                if let m = branch.metadata?.latestCommit {
                    HStack(spacing: 6) {
                        if let id = m.displayId { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let auth = m.author?.displayName ?? m.author?.name {
                            Text(auth).font(.caption).foregroundStyle(.secondary)
                        }
                        if let ts = m.authorTimestamp {
                            Text(relative(ts)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let msg = m.message {
                        Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func relative(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct BBCommitRow: View {
    let commit: APIClient.BBCommit
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dotted").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(commit.displayId).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(commit.message?.split(separator: "\n").first.map(String.init) ?? "")
                        .font(.callout).lineLimit(1)
                    Spacer()
                    if let ts = commit.authorTimestamp {
                        Text(relative(ts)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if let n = commit.author?.displayName ?? commit.author?.name {
                        Text(n).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    private func relative(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
