// Merum's icon: its own name, typed. «merum» has no ascender and no descender: five letters that stand wholly
// inside the x-height, a line of text and nothing else. STT's icon is its name spoken; this one is its name written.
//
// One picture for macOS and iOS (an Icon Composer document, `squares: shared`; the system masks it to each platform's
// shape). Drawn on the family's grid (STT, HoldQ): the old 824-unit plate (100..924) scaled to the whole 1024 canvas.
// Every number below is derived; `icon --spec` prints the results.
//
// - Font: San Francisco, the app's only font, set exactly as the app sets a note at 100 %: the system font at 13 pt
//   (NSFont.systemFontSize, mac/editor.swift), so its optical size (17, the axis minimum: the Text design, open
//   apertures for small sizes) and its tracking for 13 pt (SF's own size-specific tracking table, applied by Core Text)
//   are the app's. The line is then scaled up whole. The icon is seen at about that size: the em comes to 12 pt in a
//   64 pt Dock tile and 14 pt on a 60 pt iPhone icon, sizes the Text design is drawn for. (Set at its drawn size,
//   SF would take its Display design and tight tracking: the letters close up at Dock size.)
// - Width: 672 units between the outer edges of the two m's, the width of STT's wave (11 bars on a 64 pitch).
// - Weight: the point on SF's weight axis where the word's stems (the straight stems of m, r, u, measured at half the
//   x-height) are 32 units, STT's bar and half HoldQ's line: found by bisection, since stem and width both move
//   with the weight and the tracking.
// - Centring by the visible shape, not the ink mass: horizontally between the flat outer stems of the two m's
//   (the word starts and ends on a straight stem, so the visible edges are exact); vertically the x-height band,
//   from the flat baseline of the m's stems to the flat top of the u's stems, centred on the plate. The round
//   overshoots of e, u and the arches stay outside the band, as they do in type.
// - Results (icon --spec, with the San Francisco of macOS 27.2): weight 818 on the axis (between Heavy and Black);
//   em 193.59 units = 13 pt x 14.891; stem 32.01; x-height 104.93; outer stems at 176 and 848; band 459.54..564.46
//   around 512; the round overshoots 2.39 below and 2.39 above, so the ink box is centred too.
// - Ink: #1C1C1E on light (the family's, STT's bars), white on dark. Clear and Tinted (Icon Composer's «tinted»
//   appearance) take the white picture: given the light one they render dark ink on glass that all but vanishes.
//
// Usage:
//   icon <dir>                writes <dir>/light.png and <dir>/dark.png (1024 px, transparent)
//   icon --document <X.icon>  writes the whole Icon Composer document: Assets/light.png, Assets/dark.png, icon.json
//   icon --github <dir>       writes <dir>/icon-github.png and icon-github-dark.png: the README's own icon (dev/apps.md,
//                             «README icons»): no plate, transparent, 206 px at +25+25 on 256 as ictool places the
//                             icon, Primer 11.10.0 fgColor-default (#1f2328 light, #f0f6fc dark)
//   icon --spec               prints the derived numbers

import AppKit
import CoreText

let plate: CGFloat = 824, centre: CGFloat = 512   // plate units; the plate spans 100..924
let bar: CGFloat = 32, width: CGFloat = 672, textSize: CGFloat = 13
let word = "merum"

func sf(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let d = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [0x7767_6874: weight]] as CFDictionary)
    return CTFontCreateCopyWithAttributes(NSFont.systemFont(ofSize: size) as CTFont, size, nil, d)
}

// Glyph outlines of each letter, laid out by Core Text at 13 pt (its optical size and tracking), baseline at y = 0.
func letters(_ weight: CGFloat) -> [CGPath] {
    let font = sf(textSize, weight: weight)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: font]))
    var out: [CGPath] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var g = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(), &g); CTRunGetPositions(run, CFRange(), &pos)
        let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<n {
            var t = CGAffineTransform(translationX: pos[i].x, y: pos[i].y)
            out.append(CTFontCreatePathForGlyph(f, g[i], &t)!)
        }
    }
    return out
}

// Filled runs along a horizontal line through a path, by sampling (step in the path's units).
func runs(_ p: CGPath, y: CGFloat, step: CGFloat) -> [CGFloat] {
    let b = p.boundingBoxOfPath
    var out: [CGFloat] = [], start: CGFloat? = nil, x = b.minX - step
    while x <= b.maxX + step {
        let inside = p.contains(CGPoint(x: x, y: y), using: .winding)
        if inside, start == nil { start = x }
        if !inside, let s = start { out.append(x - s); start = nil }
        x += step
    }
    return out
}

struct Spec { let weight, scale, stem, xHeight, left, right: CGFloat; let paths: [CGPath] }

func measure(_ weight: CGFloat) -> Spec {
    let ps = letters(weight)
    // The x-height band from the flat parts: the bottom of m's stems (the m's ink bottom: m has no round bottom) and
    // the top of u's stems (u's ink top: its only round part is at the bottom).
    let m = ps[0].boundingBoxOfPath, u = ps[3].boundingBoxOfPath
    let xh = u.maxY - m.minY
    // Straight stems at half the x-height: m (3), r (1), u (2). Their mean.
    let step = textSize / 4000
    let st = [0, 2, 3, 4].flatMap { runs(ps[$0], y: m.minY + xh / 2, step: step) }
    let stem = st.reduce(0, +) / CGFloat(st.count)
    let left = ps[0].boundingBoxOfPath.minX, right = ps[4].boundingBoxOfPath.maxX
    let scale = width / (right - left)
    return Spec(weight: weight, scale: scale, stem: stem * scale, xHeight: xh * scale, left: left, right: right, paths: ps)
}

let spec: Spec = {
    var lo: CGFloat = 400, hi: CGFloat = 1000
    for _ in 0..<40 { let mid = (lo + hi) / 2; if measure(mid).stem < bar { lo = mid } else { hi = mid } }
    return measure((lo + hi) / 2)
}()

// The word in plate units: the outer stems at centre ± 336, the x-height band centred on 512.
func wordPath() -> CGPath {
    let s = spec, p = CGMutablePath()
    let baseline = centre - s.xHeight / 2
    let base = spec.paths[0].boundingBoxOfPath.minY   // the m's flat stem bottom: the baseline (0 in SF)
    let t = CGAffineTransform(translationX: centre - width / 2, y: baseline)
        .scaledBy(x: s.scale, y: s.scale).translatedBy(x: -s.left, y: -base)
    for g in s.paths { p.addPath(g, transform: t) }
    return p
}

func picture(pixels: Int, inset: CGFloat, color: CGColor) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let side = CGFloat(pixels) - 2 * inset          // the plate's side in pixels
    c.translateBy(x: inset, y: inset); c.scaleBy(x: side / plate, y: side / plate); c.translateBy(x: -100, y: -100)
    c.addPath(wordPath()); c.setFillColor(color); c.fillPath()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let ink = CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1), white = CGColor(gray: 1, alpha: 1)
func pictures(_ dir: String) {
    write(picture(pixels: 1024, inset: 0, color: ink), "\(dir)/light.png")
    write(picture(pixels: 1024, inset: 0, color: white), "\(dir)/dark.png")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "--document":
    let doc = args[2]
    try! FileManager.default.createDirectory(atPath: "\(doc)/Assets", withIntermediateDirectories: true)
    pictures("\(doc)/Assets")
    // Glass, group shadow and translucency off (dev/apps.md, «Icons, light and dark»); the light picture is the entry
    // without an appearance, or the dark one is ignored; «tinted» (Clear and Tinted) takes the white picture.
    try! """
    {
      "fill" : "system-light",
      "fill-specializations" : [ { "appearance" : "dark", "value" : "system-dark" } ],
      "groups" : [ { "layers" : [ { "name" : "picture", "glass" : false,
        "image-name-specializations" : [ { "value" : "light.png" }, { "appearance" : "dark", "value" : "dark.png" },
          { "appearance" : "tinted", "value" : "dark.png" } ] } ],
        "shadow" : { "kind" : "none", "opacity" : 0.5 }, "translucency" : { "enabled" : false, "value" : 0.5 } } ],
      "supported-platforms" : { "squares" : "shared" }
    }

    """.write(toFile: "\(doc)/icon.json", atomically: true, encoding: .utf8)
case "--github":
    let dir = args[2]
    write(picture(pixels: 256, inset: 25, color: CGColor(srgbRed: 0x1f / 255, green: 0x23 / 255, blue: 0x28 / 255, alpha: 1)), "\(dir)/icon-github.png")
    write(picture(pixels: 256, inset: 25, color: CGColor(srgbRed: 0xf0 / 255, green: 0xf6 / 255, blue: 0xfc / 255, alpha: 1)), "\(dir)/icon-github-dark.png")
case "--spec":
    let b = wordPath().boundingBoxOfPath, s = spec
    print(String(format: "weight %.1f  em %.2f units (13 pt x %.3f)  stem %.2f  x-height %.2f  width %.2f",
                 s.weight, textSize * s.scale, s.scale, s.stem, s.xHeight, width))
    print(String(format: "band %.2f..%.2f (centre %.2f)  ink box x %.2f..%.2f y %.2f..%.2f  overshoot below %.2f above %.2f",
                 centre - s.xHeight / 2, centre + s.xHeight / 2, centre, b.minX, b.maxX, b.minY, b.maxY,
                 centre - s.xHeight / 2 - b.minY, b.maxY - (centre + s.xHeight / 2)))
default:
    pictures(args[1])
}
