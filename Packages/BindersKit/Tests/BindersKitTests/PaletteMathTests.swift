import XCTest
@testable import BindersKit

final class PaletteMathTests: XCTestCase {
    func testContrastAsWCAGHasIt() {
        XCTAssertEqual(PaletteColor.black.contrast(with: .white), 21, accuracy: 0.001)
        XCTAssertEqual(PaletteColor.white.contrast(with: .white), 1, accuracy: 0.001)
        // Either way round.
        let indigo = PaletteColor(hex: 0x604CF4)
        XCTAssertEqual(indigo.contrast(with: .white), PaletteColor.white.contrast(with: indigo), accuracy: 0.0001)
        // #777777 on white is the textbook 4.48:1.
        XCTAssertEqual(PaletteColor(hex: 0x777777).contrast(with: .white), 4.48, accuracy: 0.01)
    }

    func testHexAndMixing() {
        XCTAssertEqual(PaletteColor(hex: 0xFF8000), PaletteColor(red: 1, green: 128.0 / 255, blue: 0))
        XCTAssertEqual(PaletteColor.black.mixed(with: .white, by: 0.5), PaletteColor(red: 0.5, green: 0.5, blue: 0.5))
        // Out of range stays in range.
        XCTAssertEqual(PaletteColor.black.mixed(with: .white, by: 2), .white)
    }

    func testReadableMovesOnlyAsFarAsItMust() {
        let dark = [PaletteColor(hex: 0x0B0A17)]
        // Already readable: unchanged.
        let amber = PaletteColor(red: 0.85, green: 0.68, blue: 0.20)
        XCTAssertEqual(amber.readable(on: dark, toward: .white, ratio: 4.5), amber)
        // Indigo on the dark ground isn't, so it's lifted, and not all the way to white.
        let indigo = PaletteColor(hex: 0x604CF4)
        let lifted = indigo.readable(on: dark, toward: .white, ratio: 4.5)
        XCTAssertNotEqual(lifted, indigo)
        XCTAssertNotEqual(lifted, .white)
        XCTAssertGreaterThanOrEqual(lifted.contrast(with: dark[0]), 4.5)
        // A step less wouldn't have been enough.
        guard let step = (1...20).first(where: { indigo.mixed(with: .white, by: Double($0) / 20) == lifted }) else {
            return XCTFail("Not lifted in 5% steps")
        }
        XCTAssertLessThan(indigo.mixed(with: .white, by: Double(step - 1) / 20).contrast(with: dark[0]), 4.5)
    }

    func testEveryBinderReadsInBothAppearances() {
        XCTAssertEqual(BinderShades.all.count, BinderShades.names.count)
        for (index, shades) in BinderShades.all.enumerated() {
            let name = BinderShades.names[index]
            let darkWashed = BinderShades.darkGrounds[0].mixed(with: shades.base, by: BinderShades.wash)
            let lightWashed = BinderShades.lightGrounds[0].mixed(with: shades.base, by: BinderShades.wash)
            // On the screen, its cards, the washed screen and a note's page, where its links are.
            for ground in BinderShades.darkGrounds + [darkWashed, NotePage.dark] {
                XCTAssertGreaterThanOrEqual(shades.darkText.contrast(with: ground), 4.5, "\(name) words in the dark")
            }
            for ground in BinderShades.lightGrounds + [lightWashed, NotePage.light] {
                XCTAssertGreaterThanOrEqual(shades.lightText.contrast(with: ground), 4.5, "\(name) words in the light")
            }
            XCTAssertGreaterThanOrEqual(shades.fill.contrast(with: .white), 3, "\(name) behind white words")
        }
    }

    func testTheWashIsBarelyThere() {
        // About 3% in both appearances: enough to tell which binder you're in, and no more. The washes before it (9% in the
        // dark, 6% in the light) moved the ground by up to 1.13:1.
        XCTAssertEqual(BinderShades.wash, 0.03, accuracy: 0.01)
        for (index, shades) in BinderShades.all.enumerated() {
            for ground in [BinderShades.darkGrounds[0], BinderShades.lightGrounds[0]] {
                let washed = ground.mixed(with: shades.base, by: BinderShades.wash)
                XCTAssertNotEqual(washed, ground, "\(BinderShades.names[index]) doesn't show at all")
                XCTAssertLessThan(washed.contrast(with: ground), 1.05, "\(BinderShades.names[index]) washes the page")
            }
        }
    }

    func testANotesPageFollowsTheAppearance() {
        let screen = BinderShades.darkGrounds[0], cards = BinderShades.darkGrounds[1]
        // In the dark the page is dark, not paper: lighter than the screen, so it reads as a page on it, and no lighter
        // than the cards.
        XCTAssertGreaterThan(NotePage.dark.luminance, screen.luminance)
        XCTAssertLessThanOrEqual(NotePage.dark.luminance, cards.luminance)
        XCTAssertGreaterThan(NotePage.dark.contrast(with: NotePage.light), 15)
        // Its words read on it, and so do the secondary ones (bullets, quotes, ticked items), which SwiftUI draws at
        // about half the ink.
        XCTAssertGreaterThanOrEqual(NotePage.darkInk.contrast(with: NotePage.dark), 4.5)
        XCTAssertGreaterThanOrEqual(NotePage.dark.mixed(with: NotePage.darkInk, by: 0.5).contrast(with: NotePage.dark), 4.5)
        // In the light it stays the paper it was, with its own ink.
        XCTAssertEqual(NotePage.light, PaletteColor(hex: 0xFBFBF8))
        XCTAssertEqual(NotePage.lightInk, PaletteColor(hex: 0x1B1740))
        XCTAssertGreaterThanOrEqual(NotePage.lightInk.contrast(with: NotePage.light), 4.5)
    }

    func testIndigoWearsTheBrand() {
        let indigo = BinderShades.binder(0)
        XCTAssertEqual(indigo.base, PaletteColor(hex: 0x604CF4))
        XCTAssertEqual(indigo.fill, PaletteColor(hex: 0x604CF4))
        XCTAssertEqual(indigo.darkText, PaletteColor(hex: 0xAA9EFF))
        XCTAssertEqual(indigo.lightText, PaletteColor(hex: 0x4A39D6))
    }

    func testAnyIndexLandsOnABinderColour() {
        XCTAssertEqual(BinderShades.binder(8), BinderShades.binder(0))
        XCTAssertEqual(BinderShades.binder(-3), BinderShades.binder(3))
        // Amber is too light for white words as it is, so its buttons are deepened; Teal's aren't.
        XCTAssertNotEqual(BinderShades.binder(6).fill, BinderShades.binder(6).base)
        XCTAssertEqual(BinderShades.binder(1).fill, BinderShades.binder(1).base)
    }
}
