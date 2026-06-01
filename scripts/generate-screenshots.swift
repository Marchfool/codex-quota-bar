#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("docs/assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let cyan = NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.92, alpha: 1)
let orange = NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.20, alpha: 1)
let green = NSColor(calibratedRed: 0.26, green: 0.78, blue: 0.34, alpha: 1)
let yellow = NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.22, alpha: 1)
let panelDark = NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.09, alpha: 1)

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "ScreenshotGen", code: 1)
    }
    try png.write(to: url)
}

func text(
    _ string: String,
    rect: NSRect,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .white,
    align: NSTextAlignment = .left
) {
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

func circle(_ center: NSPoint, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
}

func progress(_ rect: NSRect, value: CGFloat, color: NSColor) {
    rounded(rect, radius: rect.height / 2, fill: NSColor.white.withAlphaComponent(0.12))
    rounded(NSRect(x: rect.minX, y: rect.minY, width: rect.width * value, height: rect.height), radius: rect.height / 2, fill: color)
}

func drawSparkline(in rect: NSRect, color: NSColor) {
    rounded(rect, radius: 9, fill: NSColor.black.withAlphaComponent(0.18), stroke: NSColor.white.withAlphaComponent(0.07), lineWidth: 0.8)

    let fillPath = NSBezierPath()
    let linePath = NSBezierPath()
    let values: [CGFloat] = [0.58, 0.56, 0.57, 0.61, 0.59, 0.63, 0.66, 0.62, 0.64, 0.68, 0.67, 0.70]
    for (index, value) in values.enumerated() {
        let x = rect.minX + 10 + (rect.width - 20) * CGFloat(index) / CGFloat(values.count - 1)
        let y = rect.minY + 8 + (rect.height - 16) * value
        if index == 0 {
            fillPath.move(to: NSPoint(x: x, y: rect.minY + 8))
            fillPath.line(to: NSPoint(x: x, y: y))
            linePath.move(to: NSPoint(x: x, y: y))
        } else {
            fillPath.line(to: NSPoint(x: x, y: y))
            linePath.line(to: NSPoint(x: x, y: y))
        }
        if index == values.count - 1 {
            fillPath.line(to: NSPoint(x: x, y: rect.minY + 8))
            fillPath.close()
        }
    }
    color.withAlphaComponent(0.24).setFill()
    fillPath.fill()
    color.withAlphaComponent(0.92).setStroke()
    linePath.lineWidth = 2
    linePath.lineJoinStyle = .round
    linePath.stroke()
}

func quotaCard(
    title: String,
    subtitle: String,
    dot: NSColor,
    rect: NSRect,
    rows: [(String, String, CGFloat, NSColor)]
) {
    rounded(rect, radius: 12, fill: panelDark.withAlphaComponent(0.82), stroke: dot.withAlphaComponent(0.32), lineWidth: 1)
    circle(NSPoint(x: rect.minX + 17, y: rect.maxY - 21), radius: 4, color: dot)
    text(title, rect: NSRect(x: rect.minX + 28, y: rect.maxY - 30, width: 120, height: 18), size: 14, weight: .semibold)
    text(subtitle, rect: NSRect(x: rect.minX + 28, y: rect.maxY - 47, width: rect.width - 40, height: 15), size: 10.5, color: NSColor.white.withAlphaComponent(0.52))

    for (index, row) in rows.enumerated() {
        let y = rect.maxY - 72 - CGFloat(index) * 30
        text(row.0, rect: NSRect(x: rect.minX + 12, y: y, width: 66, height: 15), size: 10.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.60))
        progress(NSRect(x: rect.minX + 80, y: y + 4, width: rect.width - 132, height: 7), value: row.2, color: row.3)
        text(row.1, rect: NSRect(x: rect.maxX - 45, y: y - 1, width: 33, height: 15), size: 10.5, weight: .semibold, color: row.3, align: .right)
    }
}

func drawPanelScreenshot() -> NSImage {
    let image = NSImage(size: NSSize(width: 1200, height: 760))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGradient(colors: [
        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.09, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.19, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.07, alpha: 1)
    ])?.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 760), angle: 20)

    text("CodexQuotaBar", rect: NSRect(x: 78, y: 620, width: 520, height: 50), size: 42, weight: .bold)
    text("Codex, Claude, memory pressure, and task status in one menu bar app.",
         rect: NSRect(x: 80, y: 587, width: 650, height: 26), size: 17, color: NSColor.white.withAlphaComponent(0.66))

    let panel = NSRect(x: 730, y: 92, width: 344, height: 590)
    rounded(panel, radius: 27, fill: NSColor.black.withAlphaComponent(0.46), stroke: NSColor.white.withAlphaComponent(0.18), lineWidth: 1.2)

    let icon = NSRect(x: panel.minX + 16, y: panel.maxY - 48, width: 32, height: 32)
    NSGradient(colors: [cyan, NSColor(calibratedRed: 0.20, green: 0.37, blue: 1.00, alpha: 1)])?
        .draw(in: NSBezierPath(roundedRect: icon, xRadius: 9, yRadius: 9), angle: -25)
    text(">_", rect: NSRect(x: icon.minX, y: icon.minY + 6, width: icon.width, height: 18), size: 14, weight: .bold, align: .center)
    text("CodexQuotaBar", rect: NSRect(x: panel.minX + 58, y: panel.maxY - 39, width: 145, height: 18), size: 14, weight: .semibold)
    text("5小时与周额度实时监控", rect: NSRect(x: panel.minX + 58, y: panel.maxY - 58, width: 160, height: 16), size: 11, color: NSColor.white.withAlphaComponent(0.55))
    text("83%", rect: NSRect(x: panel.maxX - 84, y: panel.maxY - 51, width: 64, height: 28), size: 24, weight: .bold, color: cyan, align: .right)

    let mem = NSRect(x: panel.minX + 12, y: panel.maxY - 155, width: panel.width - 24, height: 84)
    rounded(mem, radius: 12, fill: NSColor(calibratedRed: 0.03, green: 0.13, blue: 0.15, alpha: 0.95), stroke: green.withAlphaComponent(0.25), lineWidth: 0.9)
    circle(NSPoint(x: mem.minX + 17, y: mem.maxY - 21), radius: 4, color: green)
    text("内存", rect: NSRect(x: mem.minX + 28, y: mem.maxY - 30, width: 60, height: 18), size: 14, weight: .semibold)
    text("18.6 / 32 GB", rect: NSRect(x: mem.maxX - 115, y: mem.maxY - 31, width: 100, height: 18), size: 13, weight: .semibold, align: .right)
    drawSparkline(in: NSRect(x: mem.minX + 12, y: mem.minY + 15, width: mem.width - 24, height: 34), color: green)

    quotaCard(
        title: "Codex",
        subtitle: "Pro · Spark quota included",
        dot: cyan,
        rect: NSRect(x: panel.minX + 12, y: panel.maxY - 305, width: panel.width - 24, height: 138),
        rows: [("5小时", "83%", 0.83, green), ("每周", "96%", 0.96, green), ("Spark", "100%", 1.0, green)]
    )
    quotaCard(
        title: "Claude",
        subtitle: "Desktop login synced · Routine 0/5",
        dot: orange,
        rect: NSRect(x: panel.minX + 12, y: panel.maxY - 455, width: panel.width - 24, height: 138),
        rows: [("5小时", "71%", 0.71, green), ("每周", "84%", 0.84, green), ("Routine", "5", 1.0, orange)]
    )

    let strip = NSRect(x: panel.minX + 12, y: panel.minY + 68, width: panel.width - 24, height: 34)
    rounded(strip, radius: 10, fill: NSColor.white.withAlphaComponent(0.05), stroke: NSColor.white.withAlphaComponent(0.07), lineWidth: 0.8)
    circle(NSPoint(x: strip.minX + 17, y: strip.midY), radius: 4, color: yellow)
    text("Codex 任务", rect: NSRect(x: strip.minX + 29, y: strip.minY + 9, width: 80, height: 14), size: 10.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.78))
    text("执行中 · 3秒前", rect: NSRect(x: strip.maxX - 112, y: strip.minY + 9, width: 96, height: 14), size: 10.5, color: NSColor.white.withAlphaComponent(0.58), align: .right)

    let actions = ["刷新", "桌面", "设置", "退出"]
    for (index, label) in actions.enumerated() {
        let x = panel.minX + 24 + CGFloat(index) * 75
        rounded(NSRect(x: x, y: panel.minY + 20, width: 56, height: 28), radius: 9, fill: NSColor.white.withAlphaComponent(0.07), stroke: NSColor.white.withAlphaComponent(0.07), lineWidth: 0.8)
        text(label, rect: NSRect(x: x, y: panel.minY + 27, width: 56, height: 12), size: 10.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.62), align: .center)
    }

    let menu = NSRect(x: 98, y: 410, width: 490, height: 42)
    rounded(menu, radius: 21, fill: NSColor.white.withAlphaComponent(0.11), stroke: NSColor.white.withAlphaComponent(0.14), lineWidth: 1)
    circle(NSPoint(x: menu.minX + 24, y: menu.midY), radius: 4, color: cyan)
    text("Codex 83% 1h42m", rect: NSRect(x: menu.minX + 36, y: menu.minY + 12, width: 150, height: 18), size: 14, weight: .semibold)
    circle(NSPoint(x: menu.minX + 212, y: menu.midY), radius: 4, color: orange)
    text("Claude 71% 2h05m", rect: NSRect(x: menu.minX + 224, y: menu.minY + 12, width: 165, height: 18), size: 14, weight: .semibold)
    text("18.6G", rect: NSRect(x: menu.maxX - 78, y: menu.minY + 12, width: 55, height: 18), size: 14, weight: .bold, color: green, align: .right)

    text("Dashboard + floating widget share the same card stack.",
         rect: NSRect(x: 100, y: 358, width: 520, height: 22), size: 16, color: NSColor.white.withAlphaComponent(0.58))

    return image
}

func drawMenuBarScreenshot() -> NSImage {
    let image = NSImage(size: NSSize(width: 1200, height: 360))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.10, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.17, blue: 0.21, alpha: 1)
    ])?.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 360), angle: 0)

    let bar = NSRect(x: 82, y: 184, width: 1036, height: 50)
    rounded(bar, radius: 18, fill: NSColor.black.withAlphaComponent(0.42), stroke: NSColor.white.withAlphaComponent(0.16), lineWidth: 1)
    text("Finder", rect: NSRect(x: bar.minX + 22, y: bar.minY + 16, width: 80, height: 18), size: 14, weight: .medium, color: NSColor.white.withAlphaComponent(0.78))
    text("File   Edit   View   Window   Help", rect: NSRect(x: bar.minX + 102, y: bar.minY + 16, width: 280, height: 18), size: 14, color: NSColor.white.withAlphaComponent(0.55))

    let right = bar.maxX - 470
    circle(NSPoint(x: right + 14, y: bar.midY), radius: 5, color: yellow)
    rounded(NSRect(x: right + 32, y: bar.minY + 10, width: 74, height: 30), radius: 15, fill: NSColor.white.withAlphaComponent(0.10))
    text("18.6G", rect: NSRect(x: right + 42, y: bar.minY + 17, width: 52, height: 16), size: 12.5, weight: .bold, color: green, align: .center)
    rounded(NSRect(x: right + 116, y: bar.minY + 10, width: 308, height: 30), radius: 15, fill: NSColor.white.withAlphaComponent(0.11), stroke: NSColor.white.withAlphaComponent(0.14), lineWidth: 0.8)
    circle(NSPoint(x: right + 136, y: bar.midY), radius: 4, color: cyan)
    text("Codex 83% 1h42m", rect: NSRect(x: right + 148, y: bar.minY + 17, width: 128, height: 16), size: 12.5, weight: .semibold)
    circle(NSPoint(x: right + 292, y: bar.midY), radius: 4, color: orange)
    text("Claude 71%", rect: NSRect(x: right + 304, y: bar.minY + 17, width: 82, height: 16), size: 12.5, weight: .semibold)

    text("CodexQuotaBar", rect: NSRect(x: 88, y: 104, width: 260, height: 34), size: 30, weight: .bold)
    text("Menu bar quota, Codex task light, and memory pressure indicator at a glance.",
         rect: NSRect(x: 90, y: 76, width: 700, height: 24), size: 17, color: NSColor.white.withAlphaComponent(0.62))

    return image
}

try writePNG(drawPanelScreenshot(), to: assets.appendingPathComponent("screenshot-panel.png"))
try writePNG(drawMenuBarScreenshot(), to: assets.appendingPathComponent("screenshot-menubar.png"))
