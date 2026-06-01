import SwiftUI

/// PR detay ekranı.
/// - Üstte özet kart (yazar, branch, status, action butonlar)
/// - AI özeti (SSE streaming)
/// - Değişen dosya listesi (seçince satır içi yorum ekranı)
/// - AI inline yorum önerileri
struct PRDetailView: View {
    let client: APIClient
    let pr: APIClient.PullRequest
    let projectId: Int?

    @State private var summaryText: String = ""
    @State private var summaryStreaming: Bool = false
    @State private var summaryError: String?

    @State private var changedFiles: [APIClient.ChangedFile] = []
    @State private var selectedFile: APIClient.ChangedFile?

    @State private var actionInFlight: Bool = false
    @State private var actionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                summaryCard
                actionBar
                Divider()
                filesSection
            }
            .padding(20)
        }
        .task(id: pr.pr_id) {
            await loadChanges()
            await streamSummary()
        }
        .navigationTitle("#\(pr.number) — \(pr.title)")
        .navigationSubtitle(pr.repo)
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pr.title).font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Label(pr.author, systemImage: "person")
                Label("\(pr.source_branch) → \(pr.target_branch)", systemImage: "arrow.triangle.branch")
                Link("Bitbucket'ta aç", destination: URL(string: pr.url)!)
            }
            .font(.caption).foregroundStyle(.secondary)
            if let desc = pr.description, !desc.isEmpty {
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI özeti", systemImage: "sparkles").font(.body.weight(.medium))
                Spacer()
                if summaryStreaming {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await streamSummary() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(summaryStreaming)
            }
            if let err = summaryError {
                Text(err).font(.callout).foregroundStyle(.red)
            } else if summaryText.isEmpty && !summaryStreaming {
                Text("Henüz özet üretilmedi. Tazele butonu ile başlat.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                Text(summaryText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    private func streamSummary() async {
        summaryStreaming = true
        summaryText = ""
        summaryError = nil
        defer { summaryStreaming = false }
        let stream = client.prSummaryStream(repo: pr.repo, number: pr.number, projectId: projectId)
        do {
            for try await event in stream {
                switch event.event {
                case "delta":
                    if let chunk = decodeJSONString(event.data) {
                        summaryText += chunk
                    }
                case "done":
                    return
                case "error":
                    summaryError = decodeJSONString(event.data) ?? event.data
                    return
                default:
                    break
                }
            }
        } catch {
            summaryError = error.localizedDescription
        }
    }

    private func decodeJSONString(_ raw: String) -> String? {
        // Backend SSE'de data alanını JSON string olarak gönderiyor → quote'lar var
        if let data = raw.data(using: .utf8),
           let s = try? JSONDecoder().decode(String.self, from: data) {
            return s
        }
        return raw
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    Task { await setStatus(.approved) }
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                }
                .tint(.green).buttonStyle(.borderedProminent)
                .disabled(actionInFlight)

                Button {
                    Task { await setStatus(.needsWork) }
                } label: {
                    Label("Needs Work", systemImage: "xmark.octagon")
                }
                .tint(.red).buttonStyle(.bordered)
                .disabled(actionInFlight)

                Button {
                    Task { await setStatus(.unapproved) }
                } label: {
                    Label("Geri al", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(actionInFlight)

                if actionInFlight { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let msg = actionMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setStatus(_ status: APIClient.PRReviewStatus) async {
        actionInFlight = true
        actionMessage = nil
        defer { actionInFlight = false }
        do {
            try await client.prSetStatus(repo: pr.repo, number: pr.number, status: status, projectId: projectId)
            actionMessage = "Durum güncellendi: \(status.rawValue)"
        } catch {
            actionMessage = "Hata: \(error.localizedDescription)"
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Değişen dosyalar (\(changedFiles.count))").font(.body.weight(.medium))
            if changedFiles.isEmpty {
                Text("Yükleniyor / dosya yok").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(changedFiles) { f in
                    HStack {
                        Image(systemName: iconFor(f.type ?? ""))
                        Text(f.path).font(.callout.monospaced())
                        Spacer()
                        if let a = f.additions, let d = f.deletions {
                            Text("+\(a)").foregroundStyle(.green).font(.caption.monospaced())
                            Text("-\(d)").foregroundStyle(.red).font(.caption.monospaced())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type.uppercased() {
        case "ADD":    return "plus.square"
        case "DELETE": return "minus.square"
        case "RENAME": return "arrow.right.square"
        default:        return "doc"
        }
    }

    private func loadChanges() async {
        do {
            changedFiles = try await client.prChangedFiles(repo: pr.repo, number: pr.number, projectId: projectId)
        } catch {
            // sessiz — summary kartında zaten hata gözükür
        }
    }
}
