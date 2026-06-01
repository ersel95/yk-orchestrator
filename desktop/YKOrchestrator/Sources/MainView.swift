import SwiftUI

/// Native SwiftUI ana ekran — NavigationSplitView ile sol sidebar + sağ detay.
/// v0.9.0+ — Next.js + WKWebView katmanı kaldırıldı.
struct MainView: View {
    @EnvironmentObject private var sidecar: SidecarManager
    @EnvironmentObject private var config: ConfigStore

    @State private var selected: Tab? = Tab.pullRequests
    @State private var activeProjectId: Int? = nil
    @State private var projects: [APIClient.ProjectInfo] = []
    @State private var loadError: String?

    enum Tab: String, Hashable, CaseIterable {
        case pullRequests, chat, testflight, activity, settings
        var title: String {
            switch self {
            case .pullRequests: return "Pull Request'ler"
            case .chat:         return "Chat"
            case .testflight:   return "TestFlight"
            case .activity:     return "Geçmiş"
            case .settings:     return "Ayarlar"
            }
        }
        var systemImage: String {
            switch self {
            case .pullRequests: return "arrow.triangle.pull"
            case .chat:         return "bubble.left.and.bubble.right"
            case .testflight:   return "paperplane"
            case .activity:     return "clock.arrow.circlepath"
            case .settings:     return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            detailView
                .frame(minWidth: 700, minHeight: 480)
        }
        .navigationTitle("YK Orchestrator")
        .task { await loadProjects() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Brand + active project picker
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    Text("YK Orchestrator").font(.headline)
                }
                if !projects.isEmpty {
                    Picker("Aktif proje", selection: Binding(
                        get: { activeProjectId ?? projects.first?.id ?? -1 },
                        set: { newId in
                            activeProjectId = newId
                            Task { await activateProject(id: newId) }
                        }
                    )) {
                        ForEach(projects) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            .padding(14)
            Divider()

            // Tabs — List selection ile detail view doğrudan tetiklenir.
            // NavigationLink kullanma; iki paradigma karışırsa detail boş kalır.
            List(Tab.allCases, id: \.self, selection: $selected) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(Optional(tab))
            }
            .listStyle(.sidebar)

            Spacer()

            // Health badge (alt)
            HealthFooter()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if let base = sidecar.apiBaseURL {
            let client = APIClient(baseURL: base)
            switch selected ?? .pullRequests {
            case .pullRequests: PRListView(client: client, projectId: activeProjectId)
            case .chat:         ChatView(client: client, projectId: activeProjectId)
            case .testflight:   TestFlightView(client: client, projectId: activeProjectId)
            case .activity:     ActivityView(client: client, projectId: activeProjectId)
            case .settings:     SettingsView(client: client)
            }
        } else {
            EmptyState(
                "Backend bağlantısı bekleniyor",
                systemImage: "wifi.slash",
                description: "Sidecar henüz başlatılmadı"
            )
        }
    }

    // MARK: - Data

    private func loadProjects() async {
        guard let base = sidecar.apiBaseURL else { return }
        let client = APIClient(baseURL: base)
        do {
            let resp = try await client.listProjects()
            self.projects = resp.projects
            self.activeProjectId = resp.active_id ?? resp.projects.first?.id
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    private func activateProject(id: Int) async {
        guard let base = sidecar.apiBaseURL else { return }
        let client = APIClient(baseURL: base)
        try? await client.activateProject(id: id)
    }
}

/// Sidebar altında küçük sağlık göstergesi — backend health endpoint'i her 30 sn poll.
struct HealthFooter: View {
    @EnvironmentObject private var sidecar: SidecarManager
    @State private var health: APIClient.Health?
    @State private var lastChecked: Date = .distantPast

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
        .task { await pollLoop() }
    }

    private var statusDot: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        guard let h = health else { return .gray }
        if h.ok && h.llm && h.jira && h.bitbucket { return .green }
        if h.ok { return .yellow }
        return .red
    }

    private var statusText: String {
        guard let h = health else { return "Sağlık kontrol ediliyor..." }
        let okBits: [String] = [
            h.llm ? "LLM" : nil,
            h.jira ? "Jira" : nil,
            h.bitbucket ? "BB" : nil,
        ].compactMap { $0 }
        let badBits: [String] = [
            !h.llm ? "LLM" : nil,
            !h.jira ? "Jira" : nil,
            !h.bitbucket ? "BB" : nil,
        ].compactMap { $0 }
        if badBits.isEmpty {
            return "Tümü aktif (\(okBits.joined(separator: " · ")))"
        }
        return "Kapalı: \(badBits.joined(separator: ", "))"
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await checkOnce()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    private func checkOnce() async {
        guard let base = sidecar.apiBaseURL else { return }
        let client = APIClient(baseURL: base)
        do {
            self.health = try await client.health()
            self.lastChecked = Date()
        } catch {
            // sessizce geç — sidecar restart sırasında normal
        }
    }
}
