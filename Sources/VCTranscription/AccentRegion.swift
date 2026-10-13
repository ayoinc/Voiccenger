import Foundation
import VCModels

/// A country whose English (or other language) accent a person has, or where they live. Drives default
/// spelling, the languages offered for Whisper, and vocabulary that biases and corrects recognition
/// toward local names and places.
public struct AccentRegion: Sendable, Hashable, Identifiable {
    /// ISO 3166-1 alpha-2, lower-case ("ng").
    public let id: String
    /// Country name ("Nigeria").
    public let name: String
    /// Name of the variety of speech ("Nigerian English").
    public let englishName: String
    /// "Africa", "Europe", "Asia", "North America", "South America", "Oceania", "Caribbean", "Middle East".
    public let continent: String
    public let defaultSpelling: SpellingVariant
    /// ISO 639-1 languages spoken there that Whisper can transcribe, most common in meetings first.
    public let languageCodes: [String]
    /// Common personal names, cities, institutions and currency terms, as they are usually written.
    public let vocabulary: [String]
    /// Cities and well-known places (a subset of `vocabulary`, largest or best known first).
    public let places: [String]

    public init(
        id: String, name: String, englishName: String, continent: String, defaultSpelling: SpellingVariant,
        languageCodes: [String], vocabulary: [String], places: [String]
    ) {
        self.id = id
        self.name = name
        self.englishName = englishName
        self.continent = continent
        self.defaultSpelling = defaultSpelling
        self.languageCodes = languageCodes
        self.vocabulary = vocabulary
        self.places = places
    }
}

public enum AccentRegions {
    /// Every region, African regions first, then the Caribbean and the rest of the world; within a continent by name.
    public static let all: [AccentRegion] = catalog.sorted { lhs, rhs in
        let l = continentOrder.firstIndex(of: lhs.continent) ?? continentOrder.count
        let r = continentOrder.firstIndex(of: rhs.continent) ?? continentOrder.count
        return l != r ? l < r : lhs.name < rhs.name
    }

    /// Region by id, case-insensitive ("NG" → Nigeria).
    public static func region(_ id: String) -> AccentRegion? {
        byID[id.lowercased()]
    }

    /// Continents in the order pickers group them.
    public static let continentOrder = [
        "Africa", "Caribbean", "Europe", "North America", "South America", "Asia", "Middle East", "Oceania",
    ]

    /// Regional vocabulary for a person's accent and residence regions, de-duplicated, accent region first.
    public static func vocabulary(for settings: VoiceSettings) -> [String] {
        guard settings.useRegionalVocabulary else { return [] }
        var seen = Set<String>()
        var terms: [String] = []
        for id in [settings.accentRegionID, settings.residenceRegionID].compactMap({ $0 }) {
            for term in region(id)?.vocabulary ?? [] where seen.insert(term.lowercased()).inserted {
                terms.append(term)
            }
        }
        return terms
    }

    private static let byID: [String: AccentRegion] = Dictionary(
        catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
}
