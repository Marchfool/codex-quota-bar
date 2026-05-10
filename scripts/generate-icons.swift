#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let build = root.appendingPathComponent(".build", isDirectory: true)
let iconset = build.appendingPathComponent("CodexQuotaBar.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int, template: Bool = false) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    if template {
        NSColor.black.setFill()
        let path = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: size - 8, height: size - 8), xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.white.setStroke()
        let terminal = NSBezierPath()
        terminal.lineWidth = 2.5
        terminal.move(to: NSPoint(x: s * 0.28, y: s * 0.58))
        terminal.line(to: NSPoint(x: s * 0.42, y: s * 0.50))
        terminal.line(to: NSPoint(x: s * 0.28, y: s * 0.42))
        terminal.stroke()
        NSBezierPath(rect: NSRect(x: s * 0.50, y: s * 0.40, width: s * 0.22, height: 2.5)).fill()
        return image
    }

    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size) * 0.08, dy: CGFloat(size) * 0.08), xRadius: CGFloat(size) * 0.18, yRadius: CGFloat(size) * 0.18)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.76, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.92, alpha: 1)
    ])
    gradient?.draw(in: bg, angle: -35)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    bg.lineWidth = CGFloat(size) * 0.018
    bg.stroke()

    let gaugeRect = rect.insetBy(dx: CGFloat(size) * 0.23, dy: CGFloat(size) * 0.25)
    let center = NSPoint(x: gaugeRect.midX, y: gaugeRect.midY - CGFloat(size) * 0.03)
    let radius = CGFloat(size) * 0.24
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 205, endAngle: -25, clockwise: true)
    track.lineWidth = CGFloat(size) * 0.055
    track.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.26).setStroke()
    track.stroke()

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: radius, startAngle: 205, endAngle: 26, clockwise: true)
    progress.lineWidth = CGFloat(size) * 0.055
    progress.lineCapStyle = .round
    NSColor(calibratedRed: 0.76, green: 1.0, blue: 0.54, alpha: 1).setStroke()
    progress.stroke()

    NSColor.white.setFill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(size) * 0.24, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    NSString(string: "%").draw(in: NSRect(x: 0, y: CGFloat(size) * 0.34, width: CGFloat(size), height: CGFloat(size) * 0.28), withAttributes: attrs)

    let terminalAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: CGFloat(size) * 0.12, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        .paragraphStyle: paragraph
    ]
    NSString(string: ">_").draw(in: NSRect(x: 0, y: CGFloat(size) * 0.18, width: CGFloat(size), height: CGFloat(size) * 0.16), withAttributes: terminalAttrs)

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGen", code: 1)
    }
    try png.write(to: url)
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    try writePNG(drawIcon(size: size), to: iconset.appendingPathComponent(name))
}
try writePNG(drawIcon(size: 32, template: true), to: resources.appendingPathComponent("StatusIcon.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "IconGen", code: Int(process.terminationStatus))
}
