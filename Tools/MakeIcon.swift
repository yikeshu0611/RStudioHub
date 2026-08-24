import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

image.lockFocus()
let fullRect = NSRect(origin: .zero, size: canvas)
NSColor.clear.setFill()
fullRect.fill()

let tileRect = NSRect(x: 48, y: 48, width: 928, height: 928)
let tilePath = rounded(tileRect, 200)
tilePath.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.45, green: 0.65, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.72, alpha: 1)
])?.draw(in: tileRect, angle: 135)

let letter = "R" as NSString
let font = NSFont.systemFont(ofSize: 620, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white
]
let textSize = letter.size(withAttributes: attrs)
let textRect = NSRect(
    x: (canvas.width - textSize.width) / 2 - 24,
    y: (canvas.height - textSize.height) / 2 + 36,
    width: textSize.width,
    height: textSize.height
)
letter.draw(in: textRect, withAttributes: attrs)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}

try png.write(to: URL(fileURLWithPath: outputPath))
