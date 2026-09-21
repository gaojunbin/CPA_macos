#!/usr/bin/env swift
// Generate the macOS ICNS from Resources/AppIcon.svg, the editable vector master.
// Usage: swift Scripts/generate_app_icon.swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Render the SVG directly at the destination size, without cropping or resampling a bitmap.
func render(_ image: NSImage, pixels: Int, alpha: Bool, to output: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: alphaInfo.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let source = root.appendingPathComponent("Resources/AppIcon.svg")
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot load SVG master") }
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-icon-" + UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
// PNG-backed ICNS representations, including explicit Retina scale variants.
let slots: [(type: String, pixels: Int)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
    ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)
]
func chunk(_ type: String, payload: Data) -> Data {
    var result = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}
var payload = Data()
for slot in slots {
    let output = iconset.appendingPathComponent(slot.type + ".png")
    try render(image, pixels: slot.pixels, alpha: true, to: output)
    payload.append(chunk(slot.type, payload: try Data(contentsOf: output)))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
try chunk("icns", payload: payload).write(to: output)
print("Generated \(output.lastPathComponent): 16–1024 px")
