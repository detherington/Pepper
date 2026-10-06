import AppKit
// Run from the repo root: swift scripts/render-dmg-background.swift
// Muesli's installer background (~/Muesli/scripts/render-dmg-background.swift),
// with Pepper's name, so the SBS apps install the same way.

// Renders the installer window background: black, the iridescent band, an arrow between the icon slots,
// and the drag instruction in the brand's uppercase expanded style. 660×400 points, at 1x and 2x.
let size = NSSize(width: 660, height: 400)
func render(scale: CGFloat, to path: String) {
    let pixel = NSSize(width: size.width * scale, height: size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixel.width), pixelsHigh: Int(pixel.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    // Off White ground: Finder draws icon labels in black, which vanish on a black window.
    NSColor(srgbRed: 0.957, green: 0.957, blue: 0.957, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    // Iridescent band along the top edge.
    let colors = [NSColor(srgbRed: 0.149, green: 0.318, blue: 0.788, alpha: 1), NSColor(srgbRed: 0.529, green: 0.451, blue: 0.745, alpha: 1),
                  NSColor(srgbRed: 1.0, green: 0.373, blue: 0.106, alpha: 1), NSColor(srgbRed: 0.808, green: 1.0, blue: 0.345, alpha: 1),
                  NSColor(srgbRed: 0.251, green: 0.663, blue: 0.443, alpha: 1), NSColor(srgbRed: 0.612, green: 0.804, blue: 0.8, alpha: 1)]
    let gradient = NSGradient(colors: colors)!
    gradient.draw(in: NSRect(x: 0, y: size.height - 6, width: size.width, height: 6), angle: 0)
    // Arrow between the app icon (x ≈ 170) and the Applications alias (x ≈ 490), icons centred at y ≈ 200.
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 290, y: 205)); arrow.line(to: NSPoint(x: 370, y: 205))
    arrow.move(to: NSPoint(x: 352, y: 223)); arrow.line(to: NSPoint(x: 370, y: 205)); arrow.line(to: NSPoint(x: 352, y: 187))
    NSColor(srgbRed: 0.149, green: 0.318, blue: 0.788, alpha: 1).setStroke()   // Cobalt
    arrow.stroke()
    // Instruction.
    let base = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let descriptor = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: 0.2]])
    let font = NSFont(descriptor: descriptor, size: 13) ?? base
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    // One line, above Finder's status bar (which covers the bottom ~28 points of a 400-point window).
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0, alpha: 0.8),
                                                     .kern: -0.26, .paragraphStyle: paragraph]
    let text = NSAttributedString(string: "DRAG PEPPER TO APPLICATIONS", attributes: attributes)
    text.draw(in: NSRect(x: 0, y: 72, width: size.width, height: 24))
    NSGraphicsContext.restoreGraphicsState()
    // Finder reads the PNG's DPI (pHYs) only when it is the chunk right after IHDR; ImageIO writes it later and
    // Finder then draws the background at double size on Retina displays. So write the PNG and reorder the chunks.
    let png = rep.representation(using: .png, properties: [:])!
    try! withDPIChunkFirst(png, dpi: 72 * scale).write(to: URL(fileURLWithPath: path))
}
/// Rebuilds `png` with a pHYs chunk (`dpi`) immediately after IHDR, dropping any existing one.
func withDPIChunkFirst(_ png: Data, dpi: CGFloat) -> Data {
    let bytes = [UInt8](png)
    var out = Data(bytes[0..<8])
    var pos = 8
    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    let ppm = UInt32((Double(dpi) / 0.0254).rounded())
    let body: [UInt8] = be32(ppm) + be32(ppm) + [1]
    let typeAndBody: [UInt8] = Array("pHYs".utf8) + body
    var crc: UInt32 = 0xffffffff
    for byte in typeAndBody {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
    }
    let physChunk = Data(be32(UInt32(body.count)) + typeAndBody + be32(crc ^ 0xffffffff))
    while pos + 12 <= bytes.count {
        let length = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
        let type = String(decoding: bytes[(pos + 4)..<(pos + 8)], as: UTF8.self)
        let end = pos + 12 + length
        if type != "pHYs" { out.append(contentsOf: bytes[pos..<end]) }
        if type == "IHDR" { out.append(physChunk) }
        pos = end
    }
    return out
}

// Only the 1x file: dmgbuild pairs a `background@2x.png` sibling into a Retina TIFF, which Finder draws at double size.
render(scale: 1, to: "scripts/dmg/background.png")
print("rendered")
