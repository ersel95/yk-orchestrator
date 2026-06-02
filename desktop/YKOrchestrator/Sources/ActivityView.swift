import SwiftUI

/// Geçmiş — yapılan tüm aksiyonların timeline'ı (v1.0).
/// Backend action_log tablosundan okur.
struct ActivityView: View {
    let client: APIClient
    let projectId: Int?

    @State private var entries: [APIClient.ActionEntry] = []
    @State private var stats: APIClient.ActionStats?
    @State private var loading = false
    @State private var error: String?

    @State private var filterType: String? = nil
    @State private var onlyFailures: Bool = false
    @State private var sinceHours: Int = 168   // default: son 1 hafta

    private let typeChoices: [(label: String, value: String?)] = [
        ("Hepsi", nil),
        ("PR Aksiyonları", "pr."),
        ("Jira", "jira."),
        ("TestFlight", "testflight."),
        ("Chat / AI", "chat."),
        ("Ayarlar", "settings."),
    ]

    private let periodChoices: [(label: String, hours: Int)] = [
        ("24 saat", 24), ("48 saat", 48), ("1 hafta", 168), ("1 ay", 720),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading && entries.isEmpty {
                ProgressView("Yükleniyor...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState("Hata", systemImage: "exclamationmark.triangle", description: error)
            } else if entries.isEmpty {
                EmptyState("Aksiyon yok", systemImage: "clock.arrow.circlepath",
                           description: "Seçili filtre için bu zaman aralığında kayıt yok.")
            } else {
                timeline
            }
        }
        .task(id: cacheKey) { await refresh() }
    }

    private var cacheKey: String {
        "\(projectId ?? 0)-\(filterType ?? "")-\(onlyFailures)-\(sinceHours)"
    }

    // MARK: - Header (stats + filtreler)

    private var header: some View {
        VStack(spacing: 10) {
            if let stats {
                HStack(spacing: 14) {
                    StatPill(label: "Toplam", value: "\(stats.total)", color: .accentColor)
                    StatPill(label: "Hata", value: "\(stats.failures)",
                             color: stats.failures > 0 ? .red : .secondary)
                    if let topAction = stats.by_type.max(by: { $0.value < $1.value }) {
                        StatPill(label: topAction.key, value: "\(topAction.value)", color: .blue)
                    }
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(loading)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }

            HStack(spacing: 12) {
                Picker("", selection: $filterType) {
                    ForEach(typeChoices, id: \.label) { c in
                        Text(c.label).tag(c.value)
                    }
                }
                .frame(maxWidth: 180).labelsHidden()

                Picker("", selection: $sinceHours) {
                    ForEach(periodChoices, id: \.hours) { c in
                        Text(c.label).tag(c.hours)
                    }
                }
                .frame(maxWidth: 130).labelsHidden()

                Toggle("Sadece hatalar", isOn: $onlyFailures).toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    ActionRow(entry: entry).innerPanel(padding: 10)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Data

    private func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let listTask = client.listActions(
                projectId: projectId,
                actionType: nil,
                actor: nil,
                sinceHours: sinceHours,
                onlyFailures: onlyFailures,
                limit: 300
            )
            async let statsTask = client.actionStats(projectId: projectId, sinceHours: sinceHours)
            var (list, s) = try await (listTask, statsTask)
            // action_type prefix filter (client side)
            if let prefix = filterType {
                list = list.filter { $0.action_type.hasPrefix(prefix) }
            }
            entries = list
            stats = s
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StatPill: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }
}

private struct ActionRow: View {
    let entry: APIClient.ActionEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.action_type)
                        .font(.callout.weight(.medium).monospaced())
                    if let target = entry.target_id {
                        Text("·").foregroundStyle(.tertiary)
                        Text(target).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    if entry.actor != "user" {
                        Text(entry.actor.uppercased()).font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .cornerRadius(3)
                    }
                    Spacer()
                    Text(formatTimestamp(entry.created_at))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let err = entry.error {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let summary = payloadSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var iconName: String {
        if entry.outcome == "failure" { return "xmark.octagon" }
        switch entry.action_type.split(separator: ".").first.map(String.init) {
        case "pr":          return "arrow.triangle.pull"
        case "jira":        return "list.bullet.clipboard"
        case "testflight":  return "paperplane"
        case "chat":        return "bubble.left"
        case "settings":    return "gearshape"
        case "branch":      return "arrow.triangle.branch"
        case "agent":       return "sparkles"
        default:            return "circle.dotted"
        }
    }

    private var iconColor: Color {
        if entry.outcome == "failure" { return .red }
        if entry.actor == "ai" { return .purple }
        return .accentColor
    }

    private var payloadSummary: String? {
        guard let p = entry.payload else { return nil }
        let keys = ["status", "from", "to", "text_preview", "question", "suggestion_count", "lane", "count", "completed"]
        var parts: [String] = []
        for k in keys {
            if let v = p[k]?.stringValue, !v.isEmpty {
                parts.append("\(k)=\(v)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatTimestamp(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            return rel.localizedString(for: d, relativeTo: Date())
        }
        return iso
    }
}
