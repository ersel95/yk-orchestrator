import SwiftUI

/// Uygulama açılış orkestrasyonu:
/// 1) Wizard tamamlanmamışsa SetupWizardView göster
/// 2) Sidecar (ykorch-api) henüz hazır değilse SplashView göster
/// 3) Hazır olunca DashboardView (WKWebView) yükle
struct RootView: View {
    @EnvironmentObject private var sidecar: SidecarManager
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        ZStack {
            if !config.isConfigured {
                SetupWizardView()
                    .transition(.opacity)
            } else if sidecar.state == .ready, let base = sidecar.apiBaseURL {
                DashboardView(apiBase: base)
                    .transition(.opacity)
            } else {
                SplashView(state: sidecar.state, lastError: sidecar.lastError)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sidecar.state)
        .animation(.easeInOut(duration: 0.2), value: config.isConfigured)
    }
}

struct SplashView: View {
    let state: SidecarManager.State
    let lastError: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("YK Orchestrator")
                .font(.title2.weight(.semibold))
            Text(stateLabel)
                .foregroundStyle(.secondary)
            if state == .starting || state == .waitingHealth {
                ProgressView().controlSize(.small)
            }
            if let lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "Hazırlanıyor..."
        case .starting: return "Backend başlatılıyor"
        case .waitingHealth: return "Servisler doğrulanıyor"
        case .ready: return "Hazır"
        case .failed: return "Backend başlatılamadı"
        case .stopped: return "Durduruldu"
        }
    }
}
