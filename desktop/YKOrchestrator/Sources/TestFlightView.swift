import SwiftUI

/// TestFlight upload — Fastlane status + SSE log stream.
struct TestFlightView: View {
    let client: APIClient
    let projectId: Int?

    @State private var status: APIClient.TestFlightStatus?
    @State private var log: String = ""
    @State private var streaming: Bool = false
    @State private var streamTask: Task<Void, Never>?
    @State private var error: String?
    @State private var confirmUpload: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logArea
            Divider()
            actionBar
        }
        .task { await loadStatus() }
        .confirmationDialog("TestFlight'a yükle?",
                            isPresented: $confirmUpload,
                            titleVisibility: .visible) {
            Button("Yükle", role: .destructive) { startUpload() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Fastlane lane '\(projectLane)' çalıştırılacak. Bu işlem 10-20 dakika sürebilir.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TestFlight").font(.title2.weight(.semibold))
            HStack(spacing: 16) {
                Label("Son build: \(status?.latest_build ?? "—")", systemImage: "iphone")
                Label("Son upload: \(status?.last_upload_at ?? "—")", systemImage: "clock")
                if let s = status?.last_status {
                    Label(s, systemImage: "info.circle")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logArea: some View {
        ScrollView {
            Text(log.isEmpty ? "Fastlane çıktısı burada akacak. 'Yükle' tıkla, log canlı düşer." : log)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
        }
        .background(Color.secondary.opacity(0.04))
    }

    private var actionBar: some View {
        HStack {
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            if streaming {
                Button {
                    streamTask?.cancel()
                    streaming = false
                } label: { Label("Logu durdur", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
            }
            Button {
                confirmUpload = true
            } label: {
                Label("TestFlight'a Yükle", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(streaming)
        }
        .padding(12)
    }

    private var projectLane: String {
        // ConfigStore'dan proje fastlane lane'ini al; bilinmiyorsa 'beta'
        "beta"
    }

    private func loadStatus() async {
        do {
            status = try await client.testFlightStatus(projectId: projectId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startUpload() {
        Task {
            error = nil
            log = ""
            streaming = true
            do {
                _ = try await client.testFlightUpload(projectId: projectId)
                // Log channel adı backend ile uyumlu — 'testflight' kanal default
                streamTask = Task { await consumeLog() }
            } catch {
                self.error = error.localizedDescription
                streaming = false
            }
        }
    }

    private func consumeLog() async {
        defer { Task { @MainActor in streaming = false } }
        let stream = client.streamChannel("testflight")
        do {
            for try await event in stream {
                if Task.isCancelled { return }
                let line = (decodeJSONString(event.data) ?? event.data) + "\n"
                await MainActor.run { log += line }
            }
        } catch {
            if !Task.isCancelled {
                await MainActor.run { self.error = error.localizedDescription }
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
