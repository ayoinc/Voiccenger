import Foundation
import Speech

/// Locale discovery and on-device model installation for `SpeechTranscriber`.
public enum SpeechAssets {
    /// BCP-47 identifiers (e.g. "en-GB") of every locale SpeechTranscriber can transcribe, sorted.
    public static func supportedLocaleIDs() async -> [String] {
        uniqueSortedIDs(await SpeechTranscriber.supportedLocales)
    }

    /// BCP-47 identifiers of locales whose recognition assets are already on this Mac, sorted.
    public static func installedLocaleIDs() async -> [String] {
        uniqueSortedIDs(await SpeechTranscriber.installedLocales)
    }

    /// Downloads and installs recognition assets for every locale that is not installed yet.
    /// Installation reserves the locales with `AssetInventory` (the system allows
    /// `AssetInventory.maximumReservedLocales` reservations per app).
    /// - Parameter progress: fraction completed in 0...1; called with 1 when nothing needed installing.
    /// - Throws: `TranscriptionError.unsupportedLocale` for unknown locales, or the Speech framework's
    ///   download/reservation error.
    public static func ensureInstalled(
        localeIDs: [String], progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechTranscriberUnavailable }
        var locales: [Locale] = []
        for id in localeIDs {
            let locale = try await resolveLocale(id)
            if !locales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                locales.append(locale)
            }
        }
        let installed = Set(await installedLocaleIDs())
        let missing = locales.filter { !installed.contains($0.identifier(.bcp47)) }
        guard !missing.isEmpty else {
            progress?(1)
            return
        }
        let modules: [any SpeechModule] = missing.map { TranscriberFactory.make(locale: $0, volatile: false) }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            progress?(1)
            return
        }
        let observation = progress.map { report in
            request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                report(p.fractionCompleted)
            }
        }
        defer { observation?.invalidate() }
        try await request.downloadAndInstall()
        progress?(1)
    }

    /// Maps any identifier ("en_GB", "en-GB", "fr") to the equivalent locale SpeechTranscriber supports.
    static func resolveLocale(_ id: String) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw TranscriptionError.unsupportedLocale(id)
        }
        return locale
    }

    /// Resolves the locale and checks its assets are present; recognition needs no network after this.
    static func resolveInstalledLocale(_ id: String) async throws -> Locale {
        let locale = try await resolveLocale(id)
        let installed = Set(await installedLocaleIDs())
        guard installed.contains(locale.identifier(.bcp47)) else {
            throw TranscriptionError.assetsNotInstalled(locale.identifier(.bcp47))
        }
        return locale
    }

    private static func uniqueSortedIDs(_ locales: [Locale]) -> [String] {
        Array(Set(locales.map { $0.identifier(.bcp47) })).sorted()
    }
}

/// Single place that decides the transcriber configuration, so live, offline and accent scoring agree.
enum TranscriberFactory {
    /// - Parameter volatile: live recognition wants `.volatileResults` (provisional text while someone is
    ///   still speaking). `.fastResults` is deliberately not used: it trades final accuracy for latency,
    ///   and volatile results already give sub-second feedback, while finals feed the report and the
    ///   confidence-based language detection that depends on accurate scores.
    static func make(locale: Locale, volatile: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: volatile ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
}
