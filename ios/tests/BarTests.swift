// The bar over the keyboard and at the bottom (KeyboardBar) at every width an iPhone gives, every text size and any
// counter: New Note stays a 44-point button inside the bar, the counter never touches it, is never empty, and is
// centred whenever the room allows.
import UIKit
import XCTest
@testable import Merum

@MainActor final class BarTests: XCTestCase {
    // From the narrowest compact width (SE-class 320, Duo folded) to Pro Max and Duo open.
    private let widths: [CGFloat] = [320, 344, 360, 375, 390, 393, 402, 430, 440, 600, 744, 951]
    private let sizes: [UIContentSizeCategory] = [.extraSmall, .large, .extraExtraExtraLarge,
                                                   .accessibilityMedium, .accessibilityExtraExtraExtraLarge]
    private let counts: [Facts] = [
        Facts(characters: 0, words: 0, tokens: 0),
        Facts(characters: 1, words: 1, tokens: 1),
        Facts(characters: 12_345, words: 2_345, tokens: 4_100),
        Facts(characters: 10_000_000, words: 1_500_000, tokens: 3_300_000),
        Facts(characters: 999_999_999, words: 199_999_999, tokens: 333_333_333),
    ]

    func testEveryWidthSizeAndCount() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 200))
        window.isHidden = false
        var cases = 0
        for size in sizes {
            for w in widths {
                for f in counts {
                    let bar = KeyboardBar(compose: {})
                    bar.translatesAutoresizingMaskIntoConstraints = true   // placed by its frame here, as UIKit's input host places it
                    bar.traitOverrides.preferredContentSizeCategory = size
                    bar.frame = CGRect(x: 0, y: 0, width: w, height: 56)
                    window.addSubview(bar)
                    bar.facts = f
                    bar.setNeedsLayout(); bar.layoutIfNeeded()
                    bar.setNeedsLayout(); bar.layoutIfNeeded()   // the text chosen for the laid-out width
                    let label = bar.subviews.compactMap { $0 as? UILabel }.first!
                    let button = bar.subviews.compactMap { $0 as? UIButton }.first!
                    let tag = "width \(w), \(size.rawValue), \(f.characters) characters"
                    XCTAssertEqual(button.frame.size, CGSize(width: 44, height: 44), tag)
                    XCTAssertEqual(button.frame.maxX, w - 16, accuracy: 0.5, tag)
                    XCTAssertLessThanOrEqual(label.frame.maxX, button.frame.minX - 8 + 0.5, tag)
                    XCTAssertGreaterThanOrEqual(label.frame.minX, 16 - 0.5, tag)
                    let text = label.text ?? ""
                    XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, tag)
                    // The text fits the label at its own size, or at worst at the label's smallest scale.
                    let need = (text as NSString).size(withAttributes: [.font: label.font!]).width
                    XCTAssertLessThanOrEqual(need * label.minimumScaleFactor, label.frame.width + 0.5, tag + ": " + text)
                    // Centred when the full room on both sides of New Note's mirror image is there.
                    if w >= 375 {
                        XCTAssertEqual(label.frame.midX, w / 2, accuracy: 0.5, tag)
                    }
                    // Never shrunk while a shorter form would fit at full size.
                    let full = (text as NSString).size(withAttributes: [.font: label.font!]).width
                    if text != KeyboardBar.compact(f) { XCTAssertLessThanOrEqual(full, label.frame.width + 0.5, tag) }
                    // One wording everywhere: only the numbers change.
                    XCTAssertTrue(text.contains(" chars · ") || text.contains(" char · "), tag + ": " + text)
                    bar.removeFromSuperview()
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, sizes.count * widths.count * counts.count)
    }

    // iPhone Duo's outer display: the system bars at the right edge, ~62 points of safe area.
    func testSideSafeArea() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        let vc = UIViewController()
        vc.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 62)
        window.rootViewController = vc
        window.isHidden = false
        let bar = KeyboardBar(compose: {})
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.frame = CGRect(x: 0, y: 300, width: 466, height: 56)
        vc.view.addSubview(bar)
        bar.facts = Facts(characters: 10_000_000, words: 1_500_000, tokens: 3_300_000)
        vc.view.layoutIfNeeded(); bar.setNeedsLayout(); bar.layoutIfNeeded()
        let label = bar.subviews.compactMap { $0 as? UILabel }.first!
        let button = bar.subviews.compactMap { $0 as? UIButton }.first!
        let safe = bar.safeAreaLayoutGuide.layoutFrame
        XCTAssertEqual(safe.width, 466 - 62 - window.safeAreaInsets.left - window.safeAreaInsets.right, accuracy: 0.5)
        XCTAssertEqual(button.frame.maxX, safe.maxX - 16, accuracy: 0.5)
        XCTAssertEqual(label.frame.midX, safe.midX, accuracy: 0.5)
        XCTAssertLessThanOrEqual(label.frame.maxX, button.frame.minX - 8 + 0.5)
        let need = (label.text! as NSString).size(withAttributes: [.font: label.font!]).width
        XCTAssertLessThanOrEqual(need, label.frame.width + 0.5, label.text!)
    }

    func testFormsShortenInOrder() {
        let f = Facts(characters: 10_000_000, words: 1_500_000, tokens: 3_300_000)
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        XCTAssertEqual(KeyboardBar.fit(f, width: 10_000, font: font), KeyboardBar.full(f))
        let compact = (KeyboardBar.compact(f) as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(KeyboardBar.fit(f, width: compact, font: font), KeyboardBar.compact(f))
        XCTAssertEqual(KeyboardBar.fit(f, width: 10, font: font), KeyboardBar.compact(f))
        XCTAssertTrue(KeyboardBar.full(Facts(characters: 3230, words: 660, tokens: 810)).hasSuffix(" chars · 660 words · ≈\u{00A0}810 tokens"))
        XCTAssertEqual(KeyboardBar.full(Facts(characters: 1, words: 1, tokens: 1)), "1 char · 1 word · ≈\u{00A0}1 token")
        XCTAssertEqual(KeyboardBar.fit(nil, width: 100, font: font), " ")
    }
}
