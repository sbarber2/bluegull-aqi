#!/usr/bin/env swift
// Regenerate mac-app/branding/uninstall-icon.png and kill-all-icon.png.
//
// Run with `swift gen-script-icons.swift <output-dir>` (defaults to the
// current directory). Needs no external dependencies -- unlike
// gen-dmg-background.py (Pillow), this uses AppKit/SF Symbols directly,
// since it needs a real symbol glyph, not hand-drawn shapes.
//
// Why these exist at all: mac-app/scripts/uninstall.command and
// kill-all.command are plain-text shell scripts, and macOS's Finder
// renders small text files as a live text-preview thumbnail at large
// icon sizes rather than a generic icon -- confirmed live, Steve,
// 2026-08-28 (screenshotted the actual DMG: the "icon" was legible tiny
// script text, not a cached image as first suspected). `fileicon` (the
// Makefile's app-package target) applies these PNGs as each file's
// custom Finder icon so they show something deliberate instead.
//
// Colors match AppBrand's own palette (mac-app/BluegullAQI/AppBrand.swift)
// -- navy background, midBlue ring accent, white glyph -- so these read
// as part of the same brand family as the app icon and every other
// branded surface, not a mismatched generic icon.
//
// Symbol names were verified by actually rendering and looking at the
// result, not assumed -- `NSImage(systemSymbolName:)` does NOT return nil
// for a made-up name (confirmed: "poweroff", not a real SF Symbol,
// still resolved to something -- a bare circle, not a power glyph).
// "trash" and "power" are the two confirmed-correct names here.

import AppKit

let navy = NSColor(srgbRed: 20 / 255, green: 40 / 255, blue: 70 / 255, alpha: 1)
let midBlue = NSColor(srgbRed: 62 / 255, green: 127 / 255, blue: 190 / 255, alpha: 1)

func renderIcon(symbolName: String, ringColor: NSColor, outputPath: String) {
    let size = NSSize(width: 512, height: 512)
    let image = NSImage(size: size)
    image.lockFocus()

    // Background: navy rounded square, matching AppBrand.navy -- same
    // "control surface" language as the rest of the app's branding.
    let bgRect = NSRect(origin: .zero, size: size)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 110, yRadius: 110)
    navy.setFill()
    bgPath.fill()

    // Ring accent, matching AppBrand.midBlue -- ties visually to the
    // filled-button/field color used everywhere else in Settings.
    let ringRect = bgRect.insetBy(dx: 24, dy: 24)
    let ringPath = NSBezierPath(roundedRect: ringRect, xRadius: 96, yRadius: 96)
    ringPath.lineWidth = 14
    ringColor.setStroke()
    ringPath.stroke()

    // The SF Symbol itself, white, centered, large.
    let config = NSImage.SymbolConfiguration(pointSize: 220, weight: .medium)
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = symbol.image(withTintColor: .white)
        let symbolSize = tinted.size
        let origin = NSPoint(x: (size.width - symbolSize.width) / 2, y: (size.height - symbolSize.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Couldn't render \(symbolName)")
    }
    try! png.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(outputPath)")
}

extension NSImage {
    // `.sourceAtop` compositing recolors every opaque pixel of the
    // symbol to `tintColor` while preserving its own alpha shape --
    // the standard AppKit recipe for tinting a template/monochrome
    // image without needing to touch its underlying alpha mask.
    func image(withTintColor tintColor: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        tintColor.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
renderIcon(symbolName: "trash", ringColor: midBlue, outputPath: "\(outDir)/uninstall-icon.png")
renderIcon(symbolName: "power", ringColor: midBlue, outputPath: "\(outDir)/kill-all-icon.png")
