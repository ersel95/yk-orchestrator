import SwiftUI

/// Terminal-benzeri canlı konsol satırı.
struct ConsoleLine: Identifiable {
    let id = UUID()
    enum Kind: Equatable {
        case text          // Claude'un yazdığı metin (akış)
        case thinking      // düşünme
        case tool(name: String)   // tool kullanımı (Edit/Bash…)
        case toolResult(isError: Bool)
        case info          // meta / sistem
        case error
    }
    var kind: Kind
    var text: String
}

/// Claude agent'ın canlı çıktısını terminal gibi gösterir (olay satırları + auto-scroll).
struct AgentConsoleView: View {
    let lines: [ConsoleLine]
    var running: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        row(line).id(line.id)
                    }
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("çalışıyor…").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        .id("cursor")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.last?.id) { _, _ in scrollToEnd(proxy) }
            .onChange(of: lines.last?.text) { _, _ in scrollToEnd(proxy) }
            .onChange(of: running) { _, _ in scrollToEnd(proxy) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target = running ? "cursor" : lines.last?.id.uuidString
        withAnimation(.easeOut(duration: 0.15)) {
            if running { proxy.scrollTo("cursor", anchor: .bottom) }
            else if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            _ = target
        }
    }

    @ViewBuilder
    private func row(_ line: ConsoleLine) -> some View {
        switch line.kind {
        case .text:
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            HStack(alignment: .top, spacing: 6) {
                Text("💭").font(.caption)
                Text(line.text).font(.caption).italic().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name):
            HStack(spacing: 6) {
                Text(icon(for: name)).font(.caption)
                Text(name).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.tint)
                if !line.text.isEmpty {
                    Text(line.text).font(.caption.monospaced()).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .toolResult(let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(isError ? .red : .green)
                Text(isError ? "hata" : "tamam").font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .info:
            Text(line.text).font(.caption2.monospaced()).foregroundStyle(.secondary)
        case .error:
            Text(line.text).font(.caption.monospaced()).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func icon(for tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "📝"
        case "Read": return "📖"
        case "Bash": return "🔧"
        case "Grep", "Glob": return "🔍"
        case "Task": return "🤖"
        default: return "•"
        }
    }
}
