import SwiftUI

/// Jira task'tan Claude agent ile geliştirme akışı — step-by-step (v1.5).
///
/// 4 adım:
///   1) Plan üret (read-only) → kullanıcı onaylar
///   2) Branch hazırla (Bitbucket + lokal git checkout)
///   3) Kod yaz (Claude lokal repo'da değişiklik yapar)
///   4) Diff göster → commit message → push
@MainActor
struct AgentSheet: View {
    let client: APIClient
    let jiraKey: String
    let jiraSummary: String
    let projectId: Int?
    @Binding var isPresented: Bool

    @State private var step: Step = .plan
    @State private var loading: Bool = false
    @State private var error: String?

    @State private var plan: String = ""
    @State private var planCost: Double?

    @State private var branchName: String = ""
    @State private var sourceBranch: String = "develop"
    @State private var repoPath: String = ""

    @State private var codeReport: String = ""
    @State private var codeCost: Double?

    @State private var diffStatus: String = ""
    @State private var diffText: String = ""
    @State private var commitMessage: String = ""
    @State private var pushed: Bool = false

    enum Step: Int, CaseIterable {
        case plan, prepare, code, commit, done
        var title: String {
            switch self {
            case .plan:    return "Plan"
            case .prepare: return "Branch"
            case .code:    return "Kod"
            case .commit:  return "Commit & Push"
            case .done:    return "Tamamlandı"
            }
        }
    }

    init(client: APIClient, jiraKey: String, jiraSummary: String, projectId: Int?, isPresented: Binding<Bool>) {
        self.client = client
        self.jiraKey = jiraKey
        self.jiraSummary = jiraSummary
        self.projectId = projectId
        self._isPresented = isPresented
        let slug = jiraSummary
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        self._branchName = State(initialValue: "feature/\(jiraKey)-\(slug)".lowercased())
        self._commitMessage = State(initialValue: "\(jiraKey): \(jiraSummary)")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20).frame(maxWidth: 800) }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                stepBadge(s)
                if s != Step.allCases.last {
                    Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1)
                }
            }
            Spacer()
            Button("Kapat") { isPresented = false }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
    private func stepBadge(_ s: Step) -> some View {
        let isActive = s == step
        let isPast = s.rawValue < step.rawValue
        return HStack(spacing: 5) {
            Circle()
                .fill(isActive ? Color.accentColor : (isPast ? .secondary : .secondary.opacity(0.3)))
                .frame(width: 8, height: 8)
            Text(s.title).font(.caption).foregroundStyle(isActive ? .primary : .secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .plan:    planContent
        case .prepare: prepareContent
        case .code:    codeContent
        case .commit:  commitContent
        case .done:    doneContent
        }
    }

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan").font(.title3.weight(.semibold))
            Text("\(jiraKey) — \(jiraSummary)").font(.callout).foregroundStyle(.secondary)
            if plan.isEmpty && !loading {
                Text("Claude task'ı analiz edip ne yapacağını planlamalı. 'Plan Üret' butonuna bas.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Plan üretiliyor...") }
            }
            if !plan.isEmpty {
                Text(plan).font(.body).textSelection(.enabled)
                    .padding(12).background(Color.secondary.opacity(0.06)).cornerRadius(8)
                if let c = planCost { Text(String(format: "Maliyet: $%.4f", c)).font(.caption).foregroundStyle(.secondary) }
            }
            errorLine
        }
    }

    private var prepareContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Branch Hazırla").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Branch adı").font(.caption).foregroundStyle(.secondary)
                TextField("feature/...", text: $branchName)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Source branch").font(.caption).foregroundStyle(.secondary)
                TextField("develop", text: $sourceBranch)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            }
            if !repoPath.isEmpty {
                Label(repoPath, systemImage: "folder.fill")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if loading { HStack { ProgressView().controlSize(.small); Text("Branch hazırlanıyor...") } }
            errorLine
        }
    }

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kod Üret").font(.title3.weight(.semibold))
            Text("Claude planı uygulayıp lokal repo'da değişiklik yapacak. Süre 1-5 dk arası.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { HStack { ProgressView().controlSize(.small); Text("Kod yazılıyor...") } }
            if !codeReport.isEmpty {
                Text(codeReport).font(.callout).textSelection(.enabled)
                    .padding(12).background(Color.green.opacity(0.06)).cornerRadius(8)
                if let c = codeCost { Text(String(format: "Maliyet: $%.4f", c)).font(.caption).foregroundStyle(.secondary) }
            }
            errorLine
        }
    }

    private var commitContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit & Push").font(.title3.weight(.semibold))
            if !diffStatus.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Değişen dosyalar").font(.caption).foregroundStyle(.secondary)
                    Text(diffStatus).font(.caption.monospaced())
                        .padding(8).background(Color.secondary.opacity(0.06)).cornerRadius(6)
                }
            }
            if !diffText.isEmpty {
                DisclosureGroup("Diff göster") {
                    ScrollView {
                        Text(diffText).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .padding(8).background(Color.secondary.opacity(0.04)).cornerRadius(6)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Commit mesajı").font(.caption).foregroundStyle(.secondary)
                TextField("Jira key + özet", text: $commitMessage, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
            }
            if loading { HStack { ProgressView().controlSize(.small); Text("Commit + push...") } }
            errorLine
        }
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title)
                Text("Tamamlandı").font(.title2.weight(.semibold))
            }
            if pushed { Text("Branch push'landı. Pull Request'ler sekmesinden açabilirsin.").font(.callout) }
            else { Text("Commit oldu ama push başarısız. Manuel push gerekebilir.").font(.callout).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let err = error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(err).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            .padding(10).background(Color.red.opacity(0.06)).cornerRadius(6)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .plan:
                Button(plan.isEmpty ? "Plan Üret" : "Devam Et") {
                    Task { plan.isEmpty ? await runPlan() : advance() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
            case .prepare:
                Button("Branch Hazırla") { Task { await runPrepare() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || branchName.isEmpty)
            case .code:
                Button(codeReport.isEmpty ? "Kod Üret" : "Devam Et") {
                    Task { codeReport.isEmpty ? await runCode() : await loadDiff() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
            case .commit:
                Button("Commit + Push") { Task { await runCommit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || commitMessage.isEmpty)
            case .done:
                Button("Kapat") { isPresented = false }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation { step = next }
            error = nil
        }
    }

    // MARK: - Actions

    private func runPlan() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await client.agentPlan(jiraKey: jiraKey, projectId: projectId)
            plan = r.plan; planCost = r.cost_usd; repoPath = r.repo ?? ""
        } catch { self.error = error.localizedDescription }
    }

    private func runPrepare() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await client.agentPrepare(
                jiraKey: jiraKey, branchName: branchName,
                sourceBranch: sourceBranch, projectId: projectId
            )
            repoPath = r.repo_path ?? repoPath
            advance()
        } catch { self.error = error.localizedDescription }
    }

    private func runCode() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await client.agentCode(jiraKey: jiraKey, plan: plan, projectId: projectId)
            codeReport = r.report; codeCost = r.cost_usd
        } catch { self.error = error.localizedDescription }
    }

    private func loadDiff() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await client.agentDiff(projectId: projectId)
            diffStatus = r.status
            diffText = r.diff
            advance()
        } catch { self.error = error.localizedDescription }
    }

    private func runCommit() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await client.agentCommit(message: commitMessage, push: true, projectId: projectId)
            pushed = r.pushed
            advance()
        } catch { self.error = error.localizedDescription }
    }
}
