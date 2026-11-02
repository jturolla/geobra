#!/usr/bin/env swift
import AppKit

enum IconError: LocalizedError {
    case invalidArgument
    case imageCreation
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidArgument: return "Specify the output path for Geobra.icns."
        case .imageCreation: return "Geobra could not create the icon image."
        case .writeFailed: return "Geobra could not save the icon file."
        }
    }
}

func drawGlobeMark() {
    let background = NSBezierPath(
        roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
        xRadius: 208,
        yRadius: 208
    )
    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.18, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 0.035, green: 0.065, blue: 0.075, alpha: 1)
    ])?.draw(in: background, angle: -60)
    NSColor(srgbRed: 0.28, green: 0.42, blue: 0.42, alpha: 0.55).setStroke()
    background.lineWidth = 3
    background.stroke()

    let globeRect = NSRect(x: 214, y: 214, width: 596, height: 596)
    let globe = NSBezierPath(ovalIn: globeRect)
    let teal = NSColor(srgbRed: 0.42, green: 0.77, blue: 0.69, alpha: 1)
    teal.withAlphaComponent(0.045).setFill()
    globe.fill()

    NSGraphicsContext.saveGraphicsState()
    globe.addClip()
    teal.withAlphaComponent(0.76).setStroke()
    let meridian = NSBezierPath(ovalIn: NSRect(x: 374, y: 214, width: 276, height: 596))
    meridian.lineWidth = 20
    meridian.stroke()
    let latitude = NSBezierPath(ovalIn: NSRect(x: 214, y: 393, width: 596, height: 238))
    latitude.lineWidth = 20
    latitude.stroke()
    let equator = NSBezierPath()
    equator.move(to: NSPoint(x: 214, y: 512))
    equator.line(to: NSPoint(x: 810, y: 512))
    equator.lineWidth = 18
    equator.stroke()
    NSGraphicsContext.restoreGraphicsState()

    teal.setStroke()
    globe.lineWidth = 25
    globe.stroke()

    let accent = NSColor(srgbRed: 0.92, green: 0.73, blue: 0.41, alpha: 1)
    let accentCenter = NSPoint(x: 732, y: 712)
    NSColor(srgbRed: 0.055, green: 0.095, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 666, y: 646, width: 132, height: 132)).fill()
    accent.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: 674, y: 654, width: 116, height: 116)).fill()
    let diamond = NSBezierPath()
    diamond.move(to: NSPoint(x: accentCenter.x, y: accentCenter.y + 43))
    diamond.line(to: NSPoint(x: accentCenter.x + 36, y: accentCenter.y))
    diamond.line(to: NSPoint(x: accentCenter.x, y: accentCenter.y - 43))
    diamond.line(to: NSPoint(x: accentCenter.x - 36, y: accentCenter.y))
    diamond.close()
    accent.setFill()
    diamond.fill()
}

func iconImage(pixelSize: Int) throws -> CGImage {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.imageCreation
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.cgContext.setShouldAntialias(true)
    let scale = CGFloat(pixelSize) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawGlobeMark()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = bitmap.cgImage else { throw IconError.imageCreation }
    return image
}

do {
    guard CommandLine.arguments.count == 2 else { throw IconError.invalidArgument }
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let iconsetURL = outputURL.deletingLastPathComponent()
        .appendingPathComponent("GeobraIcon-\(UUID().uuidString).iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconsetURL) }
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let image = try iconImage(pixelSize: size * scale)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw IconError.imageCreation
            }
            let suffix = scale == 2 ? "@2x" : ""
            let filename = "icon_\(size)x\(size)\(suffix).png"
            try data.write(to: iconsetURL.appendingPathComponent(filename))
        }
    }
    let converter = Process()
    converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    converter.arguments = ["--convert", "icns", "--output", outputURL.path, iconsetURL.path]
    try converter.run()
    converter.waitUntilExit()
    guard converter.terminationStatus == 0 else { throw IconError.writeFailed }
    print("Created \(outputURL.path)")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
