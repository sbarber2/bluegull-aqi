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
// Colors, Steve's own follow-up request (2026-08-28): background =
// AppBrand.iconBlue (the app icon's OWN background blue -- "the same
// color as the AQI icon"), border = AppBrand.navy. Originally shipped
// the other way around (navy background, midBlue ring) -- revised once
// Steve actually saw it rendered.
//
// Size, same follow-up: `create-dmg`'s `--icon-size` is ONE setting for
// the whole Finder window (confirmed via `create-dmg --help` -- no
// per-file size option exists; this is a Finder icon-view limitation,
// not just a create-dmg one), so these can't be shown at a genuinely
// different pixel size than the app icon while sharing that window.
// `CONTENT_SCALE` below is the workaround: it draws the icon artwork
// smaller within its own transparent canvas, so it visually reads as
// smaller inside the SAME uniform Finder icon slot -- 0.75 here for
// Steve's own "about 25% smaller" ask.
//
// Symbol names were verified by actually rendering and looking at the
// result, not assumed -- `NSImage(systemSymbolName:)` does NOT return nil
// for a made-up name (confirmed: "poweroff", not a real SF Symbol,
// still resolved to something -- a bare circle, not a power glyph).
// "trash" and "power" are the two confirmed-correct names here.

import AppKit

let iconBlue = NSColor(srgbRed: 112 / 255, green: 181 / 255, blue: 236 / 255, alpha: 1)
let navy = NSColor(srgbRed: 20 / 255, green: 40 / 255, blue: 70 / 255, alpha: 1)

// Fraction of the full canvas the icon artwork itself occupies -- see the
// module header's own comment on why this, not a smaller canvas outright
// (fileicon/Finder both expect a square input and scale it to fit the
// window's one shared --icon-size regardless of the source image's own
// pixel dimensions, so a smaller canvas wouldn't visually shrink
// anything; the padding has to be baked INTO the image content instead).
let CONTENT_SCALE: CGFloat = 0.75

func renderIcon(symbolName: String, outputPath: String) {
    let canvasSize = NSSize(width: 512, height: 512)
    let image = NSImage(size: canvasSize)
    image.lockFocus()

    let contentSize = NSSize(width: canvasSize.width * CONTENT_SCALE, height: canvasSize.height * CONTENT_SCALE)
    let contentOrigin = NSPoint(x: (canvasSize.width - contentSize.width) / 2, y: (canvasSize.height - contentSize.height) / 2)
    let bgRect = NSRect(origin: contentOrigin, size: contentSize)

    // Background: AppBrand.iconBlue -- "the same color as the AQI icon"
    // (Steve, 2026-08-28), not navy.
    let cornerRadius = 110 * CONTENT_SCALE
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    iconBlue.setFill()
    bgPath.fill()

    // Border: AppBrand.navy, not midBlue -- same follow-up request.
    let ringInset = 24 * CONTENT_SCALE
    let ringRect = bgRect.insetBy(dx: ringInset, dy: ringInset)
    let ringPath = NSBezierPath(roundedRect: ringRect, xRadius: cornerRadius - ringInset, yRadius: cornerRadius - ringInset)
    ringPath.lineWidth = 14 * CONTENT_SCALE
    navy.setStroke()
    ringPath.stroke()

    // The SF Symbol itself, white, centered, scaled down with everything
    // else so it stays proportional to the smaller background.
    let config = NSImage.SymbolConfiguration(pointSize: 220 * CONTENT_SCALE, weight: .medium)
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = symbol.image(withTintColor: .white)
        let symbolSize = tinted.size
        let origin = NSPoint(x: (canvasSize.width - symbolSize.width) / 2, y: (canvasSize.height - symbolSize.height) / 2)
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
renderIcon(symbolName: "trash", outputPath: "\(outDir)/uninstall-icon.png")
renderIcon(symbolName: "power", outputPath: "\(outDir)/kill-all-icon.png")
