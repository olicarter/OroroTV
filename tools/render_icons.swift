// Renders the tvOS app icon layers and top shelf images from an SVG logo.
// Usage: swift tools/render_icons.swift <logo.svg> <Assets.xcassets>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    fatalError("usage: render_icons.swift <logo.svg> <Assets.xcassets>")
}
let catalog = URL(fileURLWithPath: args[2])
let background = NSColor(srgbRed: 0x2E / 255, green: 0x35 / 255, blue: 0x3D / 255, alpha: 1)
let brand = catalog.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let info: [String: Any] = ["author": "xcode", "version": 1]

func writeJSON(_ object: [String: Any], to dir: URL) {
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: dir.appendingPathComponent("Contents.json"))
}

/// Draws one PNG. `logoHeight` is the logo's height as a fraction of the canvas height.
func render(width: Int, height: Int, fill: Bool, logoHeight: CGFloat?, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    if fill {
        background.setFill()
        canvas.fill()
    } else {
        NSColor.clear.setFill()
        canvas.fill(using: .copy)
    }
    if let logoHeight {
        let aspect = logo.size.width / logo.size.height
        var h = CGFloat(height) * logoHeight
        var w = h * aspect
        // Keep the logo inside 64% of the width (the icon is cropped/scaled when focused).
        if w > CGFloat(width) * 0.64 { w = CGFloat(width) * 0.64; h = w / aspect }
        logo.draw(in: NSRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// An app icon image stack: an opaque background layer and a transparent logo layer.
func imageStack(_ name: String, size: (Int, Int), scales: [Int]) {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    writeJSON(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]], to: stack)
    for (layer, isBack) in [("Front", false), ("Back", true)] {
        let layerDir = stack.appendingPathComponent("\(layer).imagestacklayer")
        writeJSON(["info": info], to: layerDir)
        let set = layerDir.appendingPathComponent("Content.imageset")
        var images: [[String: Any]] = []
        for scale in scales {
            let file = "\(layer.lowercased())\(scale > 1 ? "@\(scale)x" : "").png"
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
            try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            render(width: size.0 * scale, height: size.1 * scale, fill: isBack,
                   logoHeight: isBack ? nil : 0.36, to: set.appendingPathComponent(file))
        }
        writeJSON(["images": images, "info": info], to: set)
    }
}

/// A flat top shelf image (shown when the app sits in the top row of the home screen).
func topShelf(_ name: String, size: (Int, Int)) {
    let set = brand.appendingPathComponent("\(name).imageset")
    var images: [[String: Any]] = []
    for scale in [1, 2] {
        let file = "topshelf\(scale > 1 ? "@\(scale)x" : "").png"
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        render(width: size.0 * scale, height: size.1 * scale, fill: true, logoHeight: 0.3,
               to: set.appendingPathComponent(file))
    }
    writeJSON(["images": images, "info": info], to: set)
}

try? FileManager.default.removeItem(at: brand)
writeJSON(["info": info], to: catalog)
writeJSON(["info": info, "assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
]], to: brand)
imageStack("App Icon", size: (400, 240), scales: [1, 2])
imageStack("App Icon - App Store", size: (1280, 768), scales: [1])
topShelf("Top Shelf Image", size: (1920, 720))
topShelf("Top Shelf Image Wide", size: (2320, 720))
print("Wrote", brand.path)
