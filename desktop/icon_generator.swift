// YK Orchestrator app icon — 1024x1024 PNG üretir.
// Run: swift desktop/icon_generator.swift <output.png>
//
// Tasarım: koyu lacivert → teal-mavi gradient squircle bg üzerinde
// 4 dashboard barı (her biri bir AI agent / metrik temsili) + üstte
// altın sparkle (AI vurgusu) + alt sol checkmark (bugün hazır).
//
// Renkler bilinçli olarak Yapı Kredi kurumsal kırmızısından uzak —
// kişisel "iç araç" hissi vermeli, banka markası gibi durmamalı.

import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)

img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

// ───────────────────────────────────────────────────────────────
// 1) Squircle background — Apple HIG continuous-corner uyumlu radius
// ───────────────────────────────────────────────────────────────
let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                          xRadius: 224, yRadius: 224)
bgPath.addClip()

// Diagonal gradient: deep navy → ocean teal
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.05, green: 0.12, blue: 0.27, alpha: 1.0),  // deep navy üst-sol
        CGColor(red: 0.09, green: 0.45, blue: 0.65, alpha: 1.0),  // ocean teal alt-sağ
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: 0, y: size.height),
                       end:   CGPoint(x: size.width, y: 0),
                       options: [])

// Hafif radial highlight (üst-sol parıltı)
let highlight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(highlight,
                       startCenter: CGPoint(x: 240, y: 820), startRadius: 0,
                       endCenter:   CGPoint(x: 240, y: 820), endRadius: 520,
                       options: [])

// İnce iç çerçeve halkası (depth illüzyonu)
let ring = NSBezierPath(roundedRect: NSRect(x: 28, y: 28,
                                            width: size.width - 56,
                                            height: size.height - 56),
                        xRadius: 200, yRadius: 200)
NSColor(white: 1.0, alpha: 0.08).setStroke()
ring.lineWidth = 6
ring.stroke()

// ───────────────────────────────────────────────────────────────
// 2) Dashboard barları — 4 dikey çubuk
//    her biri farklı yükseklikte, hafif rounded
//    soldan sağa: artan trend (agent'ların toplam çıktısı)
// ───────────────────────────────────────────────────────────────
let barCount = 4
let barWidth: CGFloat = 110
let barGap:   CGFloat = 38
let groupWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
let baseX = (size.width - groupWidth) / 2
let baseY: CGFloat = 320              // tabandaki Y koordinatı (alt sıra)
let barHeights: [CGFloat] = [180, 280, 220, 360]

// Bar renkleri — beyazdan parlak teal'e geçiş
let barColors: [NSColor] = [
    NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.92), // beyaz
    NSColor(red: 0.65, green: 0.95, blue: 1.00, alpha: 0.95), // açık cyan
    NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 0.95), // mid cyan
    NSColor(red: 1.00, green: 0.75, blue: 0.30, alpha: 1.0),  // altın (en yüksek bar = "bugünün vurgusu")
]

for i in 0..<barCount {
    let x = baseX + CGFloat(i) * (barWidth + barGap)
    let h = barHeights[i]
    let r = NSRect(x: x, y: baseY, width: barWidth, height: h)
    let bar = NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26)
    barColors[i].setFill()
    bar.fill()
}

// ───────────────────────────────────────────────────────────────
// 3) Üstte AI sparkle (altın, parıldayan 4-noktalı yıldız)
// ───────────────────────────────────────────────────────────────
func sparkle(at center: CGPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.curve(to: NSPoint(x: center.x + radius, y: center.y),
               controlPoint1: NSPoint(x: center.x + radius * 0.25, y: center.y + radius * 0.25),
               controlPoint2: NSPoint(x: center.x + radius * 0.25, y: center.y + radius * 0.25))
    path.curve(to: NSPoint(x: center.x, y: center.y - radius),
               controlPoint1: NSPoint(x: center.x + radius * 0.25, y: center.y - radius * 0.25),
               controlPoint2: NSPoint(x: center.x + radius * 0.25, y: center.y - radius * 0.25))
    path.curve(to: NSPoint(x: center.x - radius, y: center.y),
               controlPoint1: NSPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.25),
               controlPoint2: NSPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.25))
    path.curve(to: NSPoint(x: center.x, y: center.y + radius),
               controlPoint1: NSPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.25),
               controlPoint2: NSPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.25))
    path.close()
    color.setFill()
    path.fill()
}

// Ana sparkle — son barın üstünde, altın
sparkle(at: CGPoint(x: baseX + groupWidth - barWidth/2 + 10, y: baseY + barHeights[3] + 100),
        radius: 78, color: NSColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0))
// İkincil küçük sparkle
sparkle(at: CGPoint(x: baseX + groupWidth + 30, y: baseY + barHeights[3] + 20),
        radius: 32, color: NSColor(red: 1.0, green: 0.95, blue: 0.60, alpha: 0.95))
// Üçüncüsü çok küçük, beyaz
sparkle(at: CGPoint(x: baseX + groupWidth - 60, y: baseY + barHeights[3] + 220),
        radius: 20, color: NSColor.white.withAlphaComponent(0.85))

// ───────────────────────────────────────────────────────────────
// 4) Alt-sol checkmark — "bugün hazır" göstergesi
//    daire içinde tick
// ───────────────────────────────────────────────────────────────
let checkCenter = CGPoint(x: 200, y: 200)
let checkRadius: CGFloat = 86
let checkCircle = NSBezierPath(ovalIn: NSRect(x: checkCenter.x - checkRadius,
                                              y: checkCenter.y - checkRadius,
                                              width: checkRadius * 2,
                                              height: checkRadius * 2))
NSColor(red: 0.30, green: 0.78, blue: 0.55, alpha: 1.0).setFill()  // taze yeşil
checkCircle.fill()

let tick = NSBezierPath()
tick.move(to: NSPoint(x: checkCenter.x - 36, y: checkCenter.y + 4))
tick.line(to: NSPoint(x: checkCenter.x - 6,  y: checkCenter.y - 28))
tick.line(to: NSPoint(x: checkCenter.x + 40, y: checkCenter.y + 28))
tick.lineWidth = 18
tick.lineCapStyle = .round
tick.lineJoinStyle = .round
NSColor.white.setStroke()
tick.stroke()

img.unlockFocus()

// ───────────────────────────────────────────────────────────────
// 5) PNG yaz
// ───────────────────────────────────────────────────────────────
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}

let url = URL(fileURLWithPath: outPath)
try png.write(to: url)
print("✓ wrote \(url.path) (\(png.count) bytes)")
