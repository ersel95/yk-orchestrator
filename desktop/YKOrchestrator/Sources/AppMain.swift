import SwiftUI
import Sparkle

@main
struct YKOrchestratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sidecar = SidecarManager()
    @StateObject private var config = ConfigStore.shared

    private let updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("YK Orchestrator") {
            RootView()
                .environmentObject(sidecar)
                .environmentObject(config)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    sidecar.start(config: config.snapshot)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("YK Orchestrator Hakkında") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            CommandGroup(after: .appInfo) {
                Button("Güncelleme Kontrol Et...") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SidecarManager.shared?.stop()
    }
}
