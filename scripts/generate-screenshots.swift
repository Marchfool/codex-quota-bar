#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("docs/assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "ScreenshotGen", code: 1)
    }
    try png.write(to: url)
}

func text(_ string: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineBreakMode = .byTruncatingTail
    NSString(string: string).draw(
        in: rect,
        withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    )
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func progress(_ rect: NSRect, value: CGFloat, color: NSColor) {
    rounded(rect, radius: rect.height / 2, fill: NSColor.white.withAlphaComponent(0.12))
    rounded(NSRect(x: rect.minX, y: rect.minY, width: rect.width * value, height: rect.height), radius: rect.height / 2, fill: color)
}

func drawPanelScreenshot() -> NSImage {
    let image = NSImage(size: NSSize(width: 1200, height: 760))
    image.lockFocus()
    defer { image.unlockFocus() }

    let canvas = NSRect(x: 0, y: 0, width: 1200, height: 760)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.07, alpha: 1)
    ])?.draw(in: canvas, angle: 25)

    text("CodexQuotaBar", rect: NSRect(x: 72, y: 620, width: 520, height: 48), size: 42, weight: .bold)
    text("A compact macOS menu bar monitor for Codex quota. / 一个精致的 macOS 状态栏 Codex 额度监控器。", rect: NSRect(x: 74, y: 585, width: 720, height: 28), size: 18, color: NSColor.white.withAlphaComponent(0.68))

    let panel = NSRect(x: 734, y: 154, width: 326, height: 306)
    rounded(panel, radius: 24, fill: NSColor.black.withAlphaComponent(0.48), stroke: NSColor.white.withAlphaComponent(0.18), lineWidth: 1.2)

    let icon = NSRect(x: panel.minX + 18, y: panel.maxY - 52, width: 30, height: 30)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.00, green: 0.82, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.18, green: 0.36, blue: 1.00, alpha: 1)
    ])?.draw(in: NSBezierPath(roundedRect: icon, xRadius: 9, yRadius: 9), angle: -30)
    text(">_", rect: NSRect(x: icon.minX, y: icon.minY + 5, width: icon.width, height: 18), size: 14, weight: .bold, align: .center)

    text("Codex 额度", rect: NSRect(x: panel.minX + 58, y: panel.maxY - 44, width: 130, height: 18), size: 14, weight: .semibold)
    text("5h 与周额度实时监控", rect: NSRect(x: panel.minX + 58, y: panel.maxY - 62, width: 155, height: 16), size: 11, color: NSColor.white.withAlphaComponent(0.56))
    text("84%", rect: NSRect(x: panel.maxX - 80, y: panel.maxY - 52, width: 62, height: 28), size: 24, weight: .bold, align: .right)

    let card = NSRect(x: panel.minX + 10, y: panel.minY + 72, width: panel.width - 20, height: 168)
    rounded(card, radius: 13, fill: NSColor.white.withAlphaComponent(0.10), stroke: NSColor.white.withAlphaComponent(0.17), lineWidth: 0.8)
    text("user@example.com", rect: NSRect(x: card.minX + 12, y: card.maxY - 32, width: 186, height: 20), size: 13, weight: .semibold)
    text("套餐 prolite · API", rect: NSRect(x: card.minX + 12, y: card.maxY - 50, width: 140, height: 16), size: 11, color: NSColor.white.withAlphaComponent(0.56))
    rounded(NSRect(x: card.maxX - 54, y: card.maxY - 30, width: 42, height: 20), radius: 10, fill: NSColor.systemGreen.withAlphaComponent(0.20))
    text("正常", rect: NSRect(x: card.maxX - 54, y: card.maxY - 27, width: 42, height: 14), size: 10.5, weight: .semibold, color: NSColor.systemGreen, align: .center)

    let green = NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.36, alpha: 1)
    text("5 小时额度", rect: NSRect(x: card.minX + 12, y: card.maxY - 78, width: 100, height: 16), size: 11.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.86))
    text("84%", rect: NSRect(x: card.maxX - 60, y: card.maxY - 81, width: 48, height: 18), size: 14, weight: .bold, color: green, align: .right)
    progress(NSRect(x: card.minX + 12, y: card.maxY - 94, width: card.width - 24, height: 6), value: 0.84, color: green)
    text("已用 16%", rect: NSRect(x: card.minX + 12, y: card.maxY - 111, width: 72, height: 14), size: 10.5, color: NSColor.white.withAlphaComponent(0.50))
    text("重置 2 小时后", rect: NSRect(x: card.maxX - 112, y: card.maxY - 111, width: 100, height: 14), size: 10.5, color: NSColor.white.withAlphaComponent(0.50), align: .right)

    text("周额度", rect: NSRect(x: card.minX + 12, y: card.maxY - 136, width: 80, height: 16), size: 11.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.86))
    text("98%", rect: NSRect(x: card.maxX - 60, y: card.maxY - 139, width: 48, height: 18), size: 14, weight: .bold, color: green, align: .right)
    progress(NSRect(x: card.minX + 12, y: card.maxY - 152, width: card.width - 24, height: 6), value: 0.98, color: green)

    let bar = NSRect(x: panel.minX, y: panel.minY, width: panel.width, height: 54)
    rounded(bar, radius: 20, fill: NSColor.black.withAlphaComponent(0.18))
    ["刷新", "导入", "账号", "数据"].enumerated().forEach { index, label in
        let x = panel.minX + 18 + CGFloat(index) * 48
        rounded(NSRect(x: x, y: panel.minY + 13, width: 36, height: 31), radius: 9, fill: NSColor.white.withAlphaComponent(0.07))
        text(label, rect: NSRect(x: x, y: panel.minY + 17, width: 36, height: 12), size: 10, color: NSColor.white.withAlphaComponent(0.56), align: .center)
    }

    let menu = NSRect(x: 122, y: 398, width: 330, height: 40)
    rounded(menu, radius: 20, fill: NSColor.white.withAlphaComponent(0.10), stroke: NSColor.white.withAlphaComponent(0.14))
    text("5h 84%   W 98%", rect: NSRect(x: menu.minX + 24, y: menu.minY + 10, width: 160, height: 20), size: 16, weight: .semibold)
    text("menu bar readout / 状态栏紧凑显示", rect: NSRect(x: menu.minX + 24, y: menu.minY - 28, width: 300, height: 18), size: 15, color: NSColor.white.withAlphaComponent(0.55))

    return image
}

func drawMenuBarScreenshot() -> NSImage {
    let image = NSImage(size: NSSize(width: 1200, height: 360))
    image.lockFocus()
    defer { image.unlockFocus() }

    let canvas = NSRect(x: 0, y: 0, width: 1200, height: 360)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.13, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.28, alpha: 1)
    ])?.draw(in: canvas, angle: 0)

    let bar = NSRect(x: 100, y: 178, width: 1000, height: 48)
    rounded(bar, radius: 18, fill: NSColor.black.withAlphaComponent(0.42), stroke: NSColor.white.withAlphaComponent(0.16))
    text("Finder", rect: NSRect(x: bar.minX + 22, y: bar.minY + 15, width: 80, height: 18), size: 14, weight: .medium, color: NSColor.white.withAlphaComponent(0.78))
    text("File   Edit   View   Window   Help", rect: NSRect(x: bar.minX + 100, y: bar.minY + 15, width: 280, height: 18), size: 14, color: NSColor.white.withAlphaComponent(0.56))
    rounded(NSRect(x: bar.maxX - 206, y: bar.minY + 9, width: 146, height: 30), radius: 15, fill: NSColor.white.withAlphaComponent(0.11), stroke: NSColor.white.withAlphaComponent(0.16), lineWidth: 0.8)
    text("5h 84%   W 98%", rect: NSRect(x: bar.maxX - 190, y: bar.minY + 15, width: 116, height: 18), size: 13.5, weight: .semibold)
    text("CodexQuotaBar", rect: NSRect(x: 100, y: 104, width: 260, height: 34), size: 30, weight: .bold)
    text("See both short-term and weekly Codex quota at a glance. / 同时查看 5 小时与周额度。", rect: NSRect(x: 100, y: 76, width: 720, height: 24), size: 17, color: NSColor.white.withAlphaComponent(0.62))

    return image
}

try writePNG(drawPanelScreenshot(), to: assets.appendingPathComponent("screenshot-panel.png"))
try writePNG(drawMenuBarScreenshot(), to: assets.appendingPathComponent("screenshot-menubar.png"))
