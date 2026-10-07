import AppKit
import Testing
@testable import Pepper

/// Title cards' SBS brand fonts (`TitleCardFont`).
struct TitleCardFontTests {
    @Test func newCardsStartOnTheBrand() {
        #expect(TitleCard.defaultStart.fontName == TitleCardFont.sbs)
        #expect(TitleCard.defaultEnd.fontName == TitleCardFont.sbs)
    }

    @Test func aCardSavedBeforeFontsKeepsTheSystemFont() throws {
        let json = #"{"enabled":true,"title":"Hi","subtitle":"","fadeDuration":2,"textColor":{"red":1,"green":1,"blue":1,"alpha":1},"backgroundColor":{"red":0,"green":0,"blue":0,"alpha":1}}"#
        let card = try JSONDecoder().decode(TitleCard.self, from: Data(json.utf8))
        #expect(card.fontName == nil)
        #expect(!TitleCardFont.isBrand(card.fontName))
    }

    @Test func theBrandPairsTheHeadlineFaceWithNantes() {
        let title = TitleCardFont.titleFont(name: TitleCardFont.sbs, size: 80)
        #expect(isHeadlineFace(title))
        // Nantes ships in the app, so it's never a stand-in here.
        #expect(TitleCardFont.subtitleFont(name: TitleCardFont.sbs, size: 40).fontName == "Nantes-Light")
    }

    @Test func eachBrandChoiceUsesItsFaces() {
        #expect(isHeadlineFace(TitleCardFont.subtitleFont(name: TitleCardFont.sbsHeadline, size: 40)))
        #expect(TitleCardFont.titleFont(name: TitleCardFont.nantes, size: 80).fontName == "Nantes-Light")
        #expect(TitleCardFont.isBrand(TitleCardFont.sbsHeadline))
        #expect(!TitleCardFont.isBrand("Helvetica Neue"))
    }

    /// Maison Neue Extended when installed, else SF Pro Expanded.
    private func isHeadlineFace(_ font: NSFont) -> Bool {
        if font.fontName == "MaisonNeueExtended-Demi" { return true }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return ((traits?[.width] as? NSNumber)?.doubleValue ?? 0) > 0
    }
}
