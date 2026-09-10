#!/usr/bin/env swift
// Renders the app icon: 1024×1024 squircle, indigo→blue gradient,
// white "sliders" glyph. Usage: swift scripts/make_icon.swift Resources/icon.png
import AppKit

let outPath = CommandLine.arguments.dropFirst().first ?? "Resources/icon.png"
let s: CGFloat = 1024

let image = NSImage(size: NSSize(width: s, height: s))
image.lockFocus()

// Squircle-ish rounded rect
let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                        xRadius: 230, yRadius: 230)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.92, alpha: 1), // indigo
    NSColor(calibratedRed: 0.18, green: 0.50, blue: 0.98, alpha: 1), // blue
])!
grad.draw(in: path, angle: -60)

// Inner subtle ring
NSColor.white.withAlphaComponent(0.12).setStroke()
path.lineWidth = 10
path.stroke()

// Glyph
if let sym = NSImage(systemSymbolName: "slider.horizontal.3",
                     variableValue: 1,
                     accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 540, weight: .semibold)) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.isTemplate = false
    let sz = tinted.size
    tinted.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + 10,
                           width: sz.width, height: sz.height))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("no se pudo renderizar el PNG")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("icon → \(outPath)")
