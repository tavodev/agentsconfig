#!/usr/bin/env swift
// Packages the approved AI-chip artwork as a macOS ICNS and Xcode app icon catalog.
// Usage: swift scripts/make_icon.swift [Resources/icon.png] [Resources/AppIcon.icns]
// The source PNG is preserved; sips retains its transparency at every size.
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let source = URL(fileURLWithPath: arguments.first ?? "Resources/icon.png").standardizedFileURL
let destination = URL(fileURLWithPath: arguments.dropFirst().first ?? "Resources/AppIcon.icns").standardizedFileURL
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentsconfig-icon-\(UUID())", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

enum IconError: Error { case commandFailed(String, Int32) }
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconError.commandFailed(executable, process.terminationStatus)
    }
}

let catalog = destination.deletingLastPathComponent().appendingPathComponent("Assets.xcassets", isDirectory: true)
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = String(size * scale)
        let suffix = scale == 2 ? "@2x" : ""
        let output = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try run("/usr/bin/sips", ["-s", "format", "png", "-z", pixels, pixels, source.path, "--out", output.path])
        try Data(contentsOf: output).write(to: appIcon.appendingPathComponent(output.lastPathComponent), options: .atomic)
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": output.lastPathComponent])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appendingPathComponent("Contents.json"), options: .atomic)
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: appIcon.appendingPathComponent("Contents.json"), options: .atomic)
let packaged = temporary.appendingPathComponent("AppIcon.icns")
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", packaged.path])
try Data(contentsOf: packaged).write(to: destination, options: .atomic)
print("App icon generated: \(destination.path)")
