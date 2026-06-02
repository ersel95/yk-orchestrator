import SwiftUI
import AppKit

/// Jira'nın `renderedFields` HTML'ini (description/yorum) formatlı gösterir.
/// NSAttributedString HTML parse'ı main-thread'de yapılır, sonuç cache'lenir.
struct HTMLText: View {
    let html: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

    @State private var attributed: AttributedString?

    var body: some View {
        Group {
            if let a = attributed {
                Text(a).textSelection(.enabled)
            } else {
                // Parse bitene kadar / başarısızsa: tag'leri sökerek düz metin
                Text(Self.stripTags(html)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: html) { attributed = Self.render(html, font: font) }
    }

    @MainActor
    static func render(_ html: String, font: NSFont) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSMutableAttributedString(data: data, options: opts, documentAttributes: nil) else {
            return nil
        }
        // HTML kendi (küçük) fontunu getirir — uygulama fontuyla normalize et,
        // rengi sistem label rengine çek (dark mode uyumu), satır aralığı ekle (okunabilirlik).
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.font, value: font, range: full)
        ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        ns.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let para = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            para.lineSpacing = 3
            para.paragraphSpacing = 7
            ns.addAttribute(.paragraphStyle, value: para, range: range)
        }
        return try? AttributedString(ns, including: \.appKit)
    }

    /// Fallback: kaba tag temizleme + temel HTML entity çözme.
    static func stripTags(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
