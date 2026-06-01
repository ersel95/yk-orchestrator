import SwiftUI

/// Chat (RAG) ekranı — backend /api/chat/stream SSE.
struct ChatView: View {
    let client: APIClient
    let projectId: Int?

    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streaming: Bool = false
    @State private var streamTask: Task<Void, Never>?
    @State private var error: String?

    struct ChatMessage: Identifiable, Hashable {
        let id = UUID()
        let role: Role
        var text: String
        enum Role: String { case user, assistant }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.last?.text) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 16)
            }
            Divider()
            composer
        }
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if msg.role == .user { Spacer(minLength: 40) }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                Text(msg.role == .user ? "Sen" : "Asistan")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(msg.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(msg.role == .user
                                ? Color.accentColor.opacity(0.14)
                                : Color.secondary.opacity(0.10))
                    .cornerRadius(10)
            }
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Bir soru yaz... (örn 'geçen Salı IOS-1234 için ne demiştik?')", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
            if streaming {
                Button {
                    streamTask?.cancel()
                    streaming = false
                } label: { Label("Durdur", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
                    .tint(.red)
            } else {
                Button {
                    send()
                } label: { Label("Gönder", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !streaming else { return }
        input = ""
        error = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        let placeholderIndex = messages.count
        messages.append(ChatMessage(role: .assistant, text: ""))
        streaming = true

        streamTask = Task {
            defer { Task { @MainActor in streaming = false } }
            let stream = client.chatStream(question: prompt, projectId: projectId)
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    switch event.event {
                    case "delta", "message":
                        if let chunk = decodeJSONString(event.data) {
                            await MainActor.run { messages[placeholderIndex].text += chunk }
                        } else {
                            await MainActor.run { messages[placeholderIndex].text += event.data }
                        }
                    case "done":
                        return
                    case "error":
                        let msg = decodeJSONString(event.data) ?? event.data
                        await MainActor.run { self.error = msg }
                        return
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func decodeJSONString(_ raw: String) -> String? {
        if let data = raw.data(using: .utf8),
           let s = try? JSONDecoder().decode(String.self, from: data) {
            return s
        }
        return nil
    }
}
