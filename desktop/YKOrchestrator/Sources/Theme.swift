import SwiftUI

/// Uygulama genelinde tutarlı görsel dil — ince gölge, yumuşak yüzeyler, radius.
/// Bankacılık aracı: sade ama okunur; abartılı renk yok.
enum Theme {
    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 7
    static let cardPadding: CGFloat = 12
    static let gap: CGFloat = 12
}

extension View {
    /// Yüzey kartı: yumuşak arkaplan + ince kenarlık + hafif gölge (yükseltilmiş his).
    func surfaceCard(padding: CGFloat = Theme.cardPadding, radius: CGFloat = Theme.radius) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    /// Gömük iç panel — gölgesiz, hafif arkaplan (kart içi gruplama için).
    func innerPanel(padding: CGFloat = Theme.cardPadding, radius: CGFloat = Theme.radiusSmall) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}

/// Bölüm başlığı — ufak accent çizgisiyle, tutarlı tipografi.
struct SectionLabel: View {
    let text: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption).foregroundStyle(.tint)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}
