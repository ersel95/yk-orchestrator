import SwiftUI
import WebKit

/// Next.js static export'unu bundle içinden WKWebView'a yükler.
/// API base URL'i `window.__YKORCH_API_BASE__` global olarak inject eder
/// — utils.ts bu değeri ilk modül yüklemesinde okur.
struct DashboardView: NSViewRepresentable {

    let apiBase: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        // API base'i sayfa scriptleri çalışmadan ÖNCE window'a yaz
        let injection = """
        (function() {
          window.__YKORCH_API_BASE__ = "\(apiBase.absoluteString)";
        })();
        """
        let userScript = WKUserScript(
            source: injection,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)

        // Localhost http çağrılarına izin (Info.plist NSAllowsLocalNetworking ile birlikte)
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.navigationDelegate = context.coordinator

        loadDashboard(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // API base değişirse (örn. sidecar restart) tekrar yükle
        if context.coordinator.lastAPIBase != apiBase {
            context.coordinator.lastAPIBase = apiBase
            loadDashboard(into: webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(initial: apiBase) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastAPIBase: URL
        init(initial: URL) { self.lastAPIBase = initial }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WKWebView] didFail: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            print("[WKWebView] didFailProvisional: \(error.localizedDescription)")
        }
    }

    private func loadDashboard(into webView: WKWebView) {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let dashboardDir = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("dashboard")
        let indexURL = dashboardDir.appendingPathComponent("index.html")

        if FileManager.default.fileExists(atPath: indexURL.path) {
            // loadFileURL bundle içindeki kaynaklara file:// ile erişim verir
            webView.loadFileURL(indexURL, allowingReadAccessTo: dashboardDir)
            return
        }

        // Dev fallback: build çıktısı doğrudan repo'dan
        let devPath = "/Users/\(NSUserName())/Desktop/Automated Report/build/dist/dashboard/index.html"
        let devURL = URL(fileURLWithPath: devPath)
        let devDir = devURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: devURL.path) {
            webView.loadFileURL(devURL, allowingReadAccessTo: devDir)
            return
        }

        // Hiçbiri yoksa açıklayıcı sayfa
        let html = """
        <html><body style="font-family:-apple-system;padding:40px;color:#888">
        <h2>Dashboard kaynakları bulunamadı</h2>
        <p>Bundle: \(dashboardDir.path)</p>
        <p>Dev fallback: \(devPath)</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
