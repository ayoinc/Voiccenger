import Foundation
import Testing
import VCModels
@testable import VCTranscription

@Suite struct ReplacementTests {
    private func settings(_ pairs: [(String, String)]) -> VoiceSettings {
        VoiceSettings(replacements: pairs.map { TextReplacement(heard: $0.0, meant: $0.1) }, useRegionalVocabulary: false)
    }

    @Test func caseInsensitiveOnWordBoundariesOnly() {
        let s = settings([("coffee", "Kofi")])
        #expect(TranscriptCustomizer.apply("Coffee said COFFEE is ready", settings: s) == "Kofi said Kofi is ready")
        #expect(TranscriptCustomizer.apply("coffeehouse and decoffee", settings: s) == "coffeehouse and decoffee")
    }

    @Test func longestPhraseWinsAndReplacedTextIsNotReplacedAgain() {
        let s = settings([("go", "Gozi"), ("and go zee", "Ngozi"), ("Ngozi", "WRONG")])
        #expect(TranscriptCustomizer.apply("Thanks and go  zee, let's go.", settings: s) == "Thanks Ngozi, let's Gozi.")
    }

    @Test func regexCharactersInHeardAreLiteral() {
        let s = settings([("C++", "C plus plus"), ("a.b", "AB")])
        #expect(TranscriptCustomizer.apply("We use C++ and aXb and a.b", settings: s) == "We use C plus plus and aXb and AB")
    }

    @Test func blankReplacementsAreIgnored() {
        let s = settings([("  ", "x")])
        #expect(TranscriptCustomizer.apply("unchanged text", settings: s) == "unchanged text")
    }
}

@Suite struct VocabularyCorrectionTests {
    private func apply(_ text: String, _ vocabulary: [String]) -> String {
        TranscriptCustomizer.apply(
            text, settings: VoiceSettings(vocabulary: vocabulary, useRegionalVocabulary: false))
    }

    @Test func nearMissNamesAreCorrected() {
        #expect(apply("I spoke to Ngozy yesterday.", ["Ngozi"]) == "I spoke to Ngozi yesterday.")
        #expect(apply("Ask Oluwaseyi about it", ["Oluwaseun"]) == "Ask Oluwaseun about it")
    }

    @Test func splitNamesAreJoinedAndPunctuationKept() {
        #expect(apply("Have you read Chima manda's book?", ["Chimamanda"]) == "Have you read Chimamanda's book?")
        #expect(apply("(Kwame Ncrumah)", ["Kwame Nkrumah"]) == "(Kwame Nkrumah)")
    }

    @Test func caseIsFixedForExactTerms() {
        #expect(apply("we flew to abuja", ["Abuja"]) == "we flew to Abuja")
    }

    @Test func commonWordsAreNeverChanged() {
        // "coffee" is one edit from nothing in the list, "kept" is close to "Kemi", "taco" to "Tako"...
        #expect(apply("I kept the coffee by the market", ["Kemi", "Kofi", "Markus"]) == "I kept the coffee by the market")
        #expect(apply("Please call Stella today", ["Stela"]) == "Please call Stella today")
        #expect(apply("We will meet on Wednesday", ["Wale"]) == "We will meet on Wednesday")
    }

    @Test func distantOrShortWordsAreLeftAlone() {
        #expect(apply("Tolu met Ade", ["Tunde", "Ada"]) == "Tolu met Ade")
        #expect(apply("Zainab arrived", ["Abuja"]) == "Zainab arrived")
    }

    @Test func spansDoNotCrossPunctuation() {
        #expect(apply("Chima. Manda", ["Chimamanda"]) == "Chima. Manda")
    }

    @Test func regionalVocabularyIsUsedOnlyWhenEnabled() throws {
        let region = try #require(AccentRegions.region("ng"))
        let term = try #require(region.places.first { $0.count >= 5 && !$0.contains(" ") })
        let misspelt = String(term.dropLast()) + (term.last == "a" ? "e" : "a")
        var settings = VoiceSettings(accentRegionID: "ng", useRegionalVocabulary: true)
        #expect(TranscriptCustomizer.apply("Flying to \(misspelt) now", settings: settings) == "Flying to \(term) now")
        settings.useRegionalVocabulary = false
        #expect(TranscriptCustomizer.apply("Flying to \(misspelt) now", settings: settings) == "Flying to \(misspelt) now")
    }
}

@Suite struct SpellingTests {
    @Test func britishToAmericanAcrossFamilies() {
        let text = "My favourite colour: we organised a catalogue of travelled theatres; the defence analysed it."
        #expect(TranscriptCustomizer.applySpelling(text, .american)
            == "My favorite color: we organized a catalog of traveled theaters; the defense analyzed it.")
    }

    @Test func americanToBritishAcrossFamilies() {
        let text = "Color the center gray, realize the labeled behavior, and enroll in the program."
        #expect(TranscriptCustomizer.applySpelling(text, .british)
            == "Colour the centre grey, realise the labelled behaviour, and enrol in the program.")
    }

    @Test func oneWayWordsDoNotGoBackwards() {
        // "tire", "check", "program", "meter" and "story" are British words too.
        let text = "Check the tire, the parking meter and the story."
        #expect(TranscriptCustomizer.applySpelling(text, .british) == text)
        #expect(TranscriptCustomizer.applySpelling("Change the tyre, pay by cheque", .american) == "Change the tire, pay by check")
    }

    @Test func properNounsAndAllCapsStay() {
        #expect(TranscriptCustomizer.applySpelling("She joined the Labour Party at Pearl Harbor.", .american)
            == "She joined the Labour Party at Pearl Harbor.")
        #expect(TranscriptCustomizer.applySpelling("Labour costs rose. Colour matters", .american)
            == "Labor costs rose. Color matters")
        #expect(TranscriptCustomizer.applySpelling("COLOUR", .american) == "COLOUR")
    }

    @Test func wordsThatOnlyLookSimilarAreUntouched() {
        let text = "Advertise, surprise and exercise; humorous, glamorous and rigorous; seize the prize."
        #expect(TranscriptCustomizer.applySpelling(text, .american) == text)
        #expect(TranscriptCustomizer.applySpelling(text, .british) == text)
    }

    @Test func unchangedLeavesTextAlone() {
        #expect(TranscriptCustomizer.applySpelling("colour color", .unchanged) == "colour color")
    }

    @Test func tableRoundTrips() {
        // American → British → American returns the word, and no word is both a British and an American key.
        for (american, british) in SpellingTable.toBritish {
            #expect(SpellingTable.toAmerican[british] == american, "\(american) → \(british)")
        }
        #expect(Set(SpellingTable.toAmerican.keys).isDisjoint(with: SpellingTable.toBritish.keys))
    }

    @Test func applyRunsReplacementsThenVocabularyThenSpelling() {
        let settings = VoiceSettings(
            spelling: .american, vocabulary: ["Ngozi"],
            replacements: [TextReplacement(heard: "and go zee", meant: "Ngozy")], useRegionalVocabulary: false)
        // Replacement produces "Ngozy", vocabulary fixes it to "Ngozi", spelling converts "colour".
        #expect(TranscriptCustomizer.apply("and go zee likes the colour", settings: settings) == "Ngozi likes the color")
    }
}
