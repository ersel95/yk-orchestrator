import Foundation
import WebKit
import UniformTypeIdentifiers

/// Next.js static export'unu WKWebView'da düzgün serve etmek için özel scheme.
///
/// Sorun: `next export` çıktısında asset path'leri MUTLAK (`/_next/static/...`).
/// WKWebView `loadFileURL(.../index.html)` ile yüklerken bu mutlak path'ler
/// filesystem root'una gider (file:///_next/...) → 404 → CSS/JS yüklenmez,
/// sayfa salt-HTML olarak görünür.
///
/// Çözüm: `yk-app://app/` scheme'i tanımla, root'unu bundle/dashboard'a bağla.
/// WebView mutlak `/_next/...` path'lerini `yk-app://app/_next/...` olarak
/// resolve eder, biz de bundle dizininden dosyayı okuyup MIME type ile döneriz.
///
/// Kullanım (DashboardView'da):
///   let handler = DashboardSchemeHandler(rootURL: dashboardDir)
///   config.setURLSchemeHandler(handler, forURLScheme: "yk-app")
///   webView.load(URLRequest(url: URL(string: "yk-app://app/")!))
final class DashboardSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Dashboard dosyalarının kökü — index.html, _next/, vs. bunun altında.
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.invalidURL)
            return
        }

        // Path'i bundle root'una bağla. `yk-app://app/_next/static/css/X.css`
        // → rootURL/_next/static/css/X.css
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }

        var fileURL = rootURL.appendingPathComponent(rel.isEmpty ? "index.html" : rel)

        // Dizin isteği veya trailing slash → o dizinin index.html'i
        // Next.js trailingSlash: true → /chat/ → /chat/index.html
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }

        // 404 fallback'leri
        if !fm.fileExists(atPath: fileURL.path) {
            // /pull-requests gibi trailing-slash'siz URL'lerde Next.js dizini bekler
            let altDir = rootURL.appendingPathComponent(rel)
            let altIndex = altDir.appendingPathComponent("index.html")
            if fm.fileExists(atPath: altIndex.path) {
                fileURL = altIndex
            } else {
                urlSchemeTask.didFailWithError(SchemeError.notFound(rel))
                return
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = mimeType(for: fileURL)
            let resp = URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: mime.hasPrefix("text/") || mime.hasSuffix("/json") || mime.hasSuffix("javascript") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Cancel handling — şu an no-op (Data ile sync okuduğumuz için)
    }

    // MARK: - MIME type lookup

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "html", "htm":  return "text/html"
        case "css":           return "text/css"
        case "js", "mjs":     return "application/javascript"
        case "json":          return "application/json"
        case "svg":           return "image/svg+xml"
        case "png":           return "image/png"
        case "jpg", "jpeg":   return "image/jpeg"
        case "gif":           return "image/gif"
        case "webp":          return "image/webp"
        case "ico":           return "image/x-icon"
        case "woff":          return "font/woff"
        case "woff2":         return "font/woff2"
        case "ttf":           return "font/ttf"
        case "otf":           return "font/otf"
        case "map":           return "application/json"
        case "txt":           return "text/plain"
        case "xml":           return "application/xml"
        default:
            // UTI fallback
            if let utType = UTType(filenameExtension: ext),
               let mime = utType.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }

    enum SchemeError: LocalizedError {
        case invalidURL
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Geçersiz URL"
            case .notFound(let p): return "Dosya bulunamadı: \(p)"
            }
        }
    }
}
