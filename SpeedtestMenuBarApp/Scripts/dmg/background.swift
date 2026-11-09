import AppKit

let width = 720
let height = 400
let scale = Int(CommandLine.arguments[2])!
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
                              pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func line(_ points: [(CGFloat, CGFloat)], color: NSColor, width: CGFloat = 1) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for (x, y) in points.dropFirst() { path.line(to: NSPoint(x: x, y: y)) }
    color.setStroke()
    path.stroke()
}
func center(_ text: String, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight, tint: UInt32) {
    let label = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(tint)
    ])
    label.draw(at: NSPoint(x: (CGFloat(width) - label.size().width) / 2, y: y))
}

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: color(0x081523), ending: color(0x183747))!.draw(in: bounds, angle: 32)

for x in stride(from: 0, through: width, by: 30) {
    line([(CGFloat(x), 0), (CGFloat(x), CGFloat(height))], color: color(0xA8F2ED, alpha: 0.055))
}
for y in stride(from: 10, through: height, by: 30) {
    line([(0, CGFloat(y)), (CGFloat(width), CGFloat(y))], color: color(0xA8F2ED, alpha: 0.055))
}
line([(0, 80), (75, 80), (113, 112), (148, 92), (208, 117), (254, 78), (293, 102),
      (341, 101), (393, 122), (433, 110), (490, 149), (550, 120), (607, 138), (660, 91), (720, 112)],
     color: color(0x5EEAD4, alpha: 0.17), width: 2)

center("S P E E D B A R   /   M A C O S", 351, size: 12, weight: .semibold, tint: 0x75EDD5)
center("Drag to install", 302, size: 35, weight: .bold, tint: 0xF0FBFF)
center("Move SpeedBar into Applications.", 273, size: 16, weight: .medium, tint: 0xC0D9E3)
line([(315, 177), (405, 177)], color: color(0x75EDD5), width: 3)
line([(390, 192), (405, 177), (390, 162)], color: color(0x75EDD5), width: 3)
center("APPLE SILICON + INTEL   /   MACOS 14 OR LATER", 28, size: 11, weight: .semibold, tint: 0xC0D9E3)

let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
