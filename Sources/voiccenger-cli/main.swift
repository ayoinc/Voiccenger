import Foundation
import VCPipeline

// MARK: - Argument parsing

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Positional arguments plus `--name value` options and `--flag` switches.
struct Arguments {
    private(set) var positional: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []
    private var consumed: Set<String> = []

    init(_ args: some Collection<String>, flags known: Set<String>) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg == "-h" || arg == "--help" {
                flags.insert("help")
            } else if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if known.contains(body) {
                    flags.insert(body)
                } else if let value = it.next() {
                    options[body] = value
                } else {
                    throw UsageError("--\(body) needs a value")
                }
            } else {
                positional.append(arg)
            }
        }
    }

    var wantsHelp: Bool { flags.contains("help") }

    mutating func flag(_ name: String) -> Bool {
        consumed.insert(name)
        return flags.contains(name)
    }

    mutating func option(_ name: String) -> String? {
        consumed.insert(name)
        return options[name]
    }

    mutating func double(_ name: String, default value: Double) throws -> Double {
        guard let raw = option(name) else { return value }
        guard let v = Double(raw) else { throw UsageError("--\(name) must be a number, got “\(raw)”") }
        return v
    }

    func positional(_ i: Int, _ what: String) throws -> String {
        guard positional.indices.contains(i) else { throw UsageError("missing \(what)") }
        return positional[i]
    }

    /// Rejects options the command doesn't understand (typos would otherwise be silently ignored).
    func checkUnused() throws {
        let unknown = Set(options.keys).union(flags.subtracting(["help"])).subtracting(consumed)
        if let first = unknown.sorted().first { throw UsageError("unknown option --\(first)") }
    }
}

func fileURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else { throw UsageError("no such file: \(path)") }
    return url
}

func directoryURL(_ path: String?, default fallback: URL) -> URL {
    guard let path else { return fallback }
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
}

func eprint(_ items: Any...) {
    let line = items.map { "\($0)" }.joined(separator: " ") + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Help

let usage = """
    voiccenger-cli — meeting transcription toolkit

    USAGE
      voiccenger-cli <command> [arguments] [options]

    COMMANDS
      capabilities [--json]            What this Mac can run (OS, chip, voice models, Apple Speech, Apple
                                       Intelligence) and the defaults that follow.
      devices                          List audio input devices and apps using the microphone.
      detect [--watch]                 Show conferencing apps using the microphone; --watch streams
                                       debounced meeting start/end events until interrupted.
      enroll <name> <wav> [options]    Enroll a voice from a recording (≥ 5 s of speech).
          --store dir                  Profile store (default: the app's library)
          --accent id / --lives id     Accent and home regions, e.g. ng, gb (see `calibrate --regions`)
          --language code              Language they speak in meetings (default: en)
          --engine cohere|whisper|apple|deepgram Voice model for their lines (overrides calibration)
          --standard | --text file     The recording reads the standard passage / this text: also calibrate
                                       the voice models on it and save the best as their engine
      profiles [--store dir]           List enrolled voices.
      models                           List voice models: status, size, languages, measured accuracy
                                       (checks a Deepgram key with Deepgram).
      models download <engine>         Download a voice model (cohere, whisper).
      models deepgram [--language code] [--refresh]
                                       List the Deepgram models your key can use: languages, and whether each
                                       streams live or only transcribes recordings (--language: only those
                                       transcribing it).
      models delete <engine>           Delete a downloaded voice model.
      transcribe <file> [--engine cohere|whisper|apple|deepgram] [--language en] [--deepgram-model name]
                                       Transcribe an audio file with timestamps (default engine: cohere on
                                       Apple silicon, whisper on Intel). deepgram sends the audio to Deepgram
                                       (key: Keychain, DEEPGRAM_API_KEY or ~/.deepgram_secret) using
                                       --deepgram-model (default: nova-3).
          --truth file                 Print the word error rate against this reference: plain text, or a
                                       JSON array of {"text"} lines (e.g. .fixtures/meeting.truth.json)
          --max-wer 0.2                Exit 1 when the word error rate is higher (needs --truth)
      calibrate <wav> [options]        Score every downloaded voice model on a reading of a known text.
          --standard                   The recording reads the Speech Accent Archive passage
          --text file                  The recording reads this text
          --name N [--region id]       Without --standard/--text: the recording reads the enrollment
                                       passage (standard + a sentence with N and a place in the region)
          --engines cohere,whisper     Engines to score (default: Apple plus every downloaded model)
          --deepgram-model a,b         Deepgram models to score, up to 3 (default: nova-3)
          --language code              Language of the reading (default: en)
          --regions                    List accent/residence region ids and exit
      process <file> [options]         Run a recording through the full meeting pipeline
                                       (transcription, speaker identification, analysis, report).
          --profiles dir               Enrolled voices (default: the app's library)
          --engine cohere|whisper|apple|deepgram Voice model (default: cohere on Apple silicon, whisper on Intel;
                                       deepgram streams the audio to Deepgram)
          --deepgram-model name        Deepgram model (default: nova-3; Nova-3 when it can't stream)
          --intelligence apple|claude|outline Intelligence engine (default: apple; falls back to the other,
                                       then to outline: a transcript outline without AI)
          --locale id                  Apple preview locale and meeting language (default: system locale)
          --spelling british|american  Spelling for speakers without their own preference
          --title text                 Meeting title (default: proposed by the report, else the file name)
          --out report.md              Write the Markdown report here (default: print it)
          --json meeting.json          Also write the meeting as JSON
          --meetings dir               Store the meeting here (default: a temporary directory)
          --truth truth.json           Score per-turn speaker accuracy against ground truth
          --no-analysis                Skip live per-line analysis (the report is still written)
          --no-auto-language           Keep the Apple preview on --locale
      record [--seconds 30] [--kind in-person|online] [--out report.md] [options]
                                       Record a live meeting: the microphone plus the computer's audio
                                       (Core Audio process tap, independent of output volume and mute),
                                       then print each channel's transcript and write the report.
          --app bundle-id              The meeting runs in this app (tap its whole process family)
          --detect                     Become an online meeting when a meeting app starts using the mic
          --no-computer-audio          In person: record the microphone only
          --engine, --intelligence, --locale, --title, --json, --meetings, --profiles, --no-analysis
                                       As for `process`; the meeting and its audio are kept in --meetings
                                       (default: a temporary directory)
      system-audio [--seconds 5] [--app bundle-id] [--out capture.wav]
                                       Capture system audio through a Core Audio process tap (all apps, or
                                       one meeting app's processes), report its level, optionally record it.
      report <transcript.json> [--intelligence apple|claude|outline] [--title text] [--out report.md]
                                       Write the report for a transcript: a JSON array of lines
                                       {"speaker", "start", "end"?, "text"} (as in .fixtures/meeting.truth.json).
      doa --preset name --angle deg [--snr dB] [--reverb gain] [--source file.wav]
                                       Simulate a source around a microphone array and estimate its
                                       direction with GCC-PHAT. Presets: \(ArrayPresetIDs.all.map(\.id).joined(separator: ", "))

    Default profile store: \(AppPaths.default.profiles.path)
    """

// MARK: - Commands

func devices(_ a: inout Arguments) throws {
    try a.checkUnused()
    let defaultID = AudioDevices.defaultInputDevice()?.id
    let list = AudioDevices.inputDevices()
    print("Input devices:")
    if list.isEmpty { print("  (none)") }
    for d in list {
        print("  \(d.id == defaultID ? "*" : " ") \(pad(d.name, 36)) \(d.channelCount) ch   \(d.id)")
    }
    print("\nApps using the microphone:")
    printMicrophoneUsers()
}

func printMicrophoneUsers() {
    let users = MeetingDetector.processesUsingMicrophone()
    if users.isEmpty { print("  (none)") }
    for u in users {
        let app = MeetingAppCatalog.app(forBundleID: u.bundleID)
        let label = app.map { "\($0.displayName) [meeting app]" } ?? u.bundleID
        print("  \(pad(label, 40)) pid \(u.pid)")
    }
}

func detect(_ a: inout Arguments) async throws {
    let watch = a.flag("watch")
    try a.checkUnused()
    printMicrophoneUsers()
    guard watch else { return }
    print("\nWatching for meetings (Ctrl-C to stop)…")
    let detector = MeetingDetector()
    for await event in detector.events() {
        let time = Date().formatted(date: .omitted, time: .standard)
        switch event {
        case .meetingStarted(let m):
            print("[\(time)] meeting started: \(m.app.displayName) (pids \(m.processIDs.map(String.init).joined(separator: ", ")))")
        case .meetingEnded(let m):
            print("[\(time)] meeting ended: \(m.app.displayName)")
        case .conversationDetected:
            print("[\(time)] conversation detected")
        }
    }
}

func enroll(_ a: inout Arguments) async throws {
    let name = try a.positional(0, "<name>")
    let url = try fileURL(try a.positional(1, "<wav>"))
    let store = SpeakerProfileStore(directory: directoryURL(a.option("store"), default: AppPaths.default.profiles))
    let accent = try a.option("accent").map(region)
    let lives = try a.option("lives").map(region)
    let language = a.option("language")
    let manualEngine = try a.option("engine").map(engine)
    let expected = try readingText(&a, name: nil, region: nil, required: false)
    try a.checkUnused()
    eprint("Preparing speaker models…")
    try await SpeakerModels.prepare()
    let samples = try AudioResampler.load16kMono(url: url)
    let existing = await store.all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    var voice = existing?.voice ?? VoiceSettings()
    if let accent { voice.accentRegionID = accent.id }
    if let lives { voice.residenceRegionID = lives.id }
    if let language { voice.languageCode = language }
    var replacing = existing
    replacing?.voice = voice
    var transcribers: [any AccurateTranscriber] = []
    if expected != nil {
        eprint("Loading voice models for calibration…")
        transcribers = await EnrollmentService.calibrationTranscribers()
    }
    let outcome = try await EnrollmentService.enroll(
        name: name, samples16k: samples, store: store, replacing: replacing, voice: voice, calibrationText: expected,
        transcribers: transcribers)
    var p = outcome.profile
    if let manualEngine, p.voice.preferredEngine != manualEngine {
        p.voice.preferredEngine = manualEngine
        try await store.upsert(p)
    }
    print("\(existing == nil ? "Enrolled" : "Re-enrolled") \(p.name) (\(p.id.uuidString)) with \(p.embeddings.count) voice sample(s).")
    if expected != nil { printCalibration(outcome.calibration, suggestions: outcome.suggestedReplacements) }
    print("Engine: \(p.voice.preferredEngine.map { SpeechModelLibrary.info($0).displayName } ?? "meeting default")")
}

func profiles(_ a: inout Arguments) async throws {
    let store = SpeakerProfileStore(directory: directoryURL(a.option("store"), default: AppPaths.default.profiles))
    try a.checkUnused()
    let all = await store.all().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    if all.isEmpty { print("No enrolled voices.") }
    for p in all {
        let v = p.voice
        let engine = (v.preferredEngine?.rawValue ?? "default") + (v.deepgramModel.map { "/\($0)" } ?? "")
        let wer = v.calibration?.best.map { " (WER \(percent($0.wordErrorRate)))" } ?? ""
        print(
            "\(pad(p.name, 20)) accent \(pad(v.accentRegionID ?? "—", 3)) lives \(pad(v.residenceRegionID ?? "—", 3)) language \(pad(v.languageCode, 3)) engine \(pad(engine + wer, 22)) samples \(p.embeddings.count)  \(p.id.uuidString)"
        )
    }
}

func models(_ a: inout Arguments) async throws {
    let library = SpeechModelLibrary.shared
    switch a.positional.first {
    case nil:
        try a.checkUnused()
        for info in SpeechModelLibrary.allInfo {
            if info.isCloud, await library.status(info.kind) == .downloaded { try? await library.prewarm(info.kind) }
            let status = describe(await library.status(info.kind))
            let size =
                info.isCloud
                ? "cloud" : info.downloadBytes > 0 ? ByteCountFormatter.string(fromByteCount: info.downloadBytes, countStyle: .file) : "built in"
            let wer = info.africanWordErrorRate.map { "African-accent WER \(percent($0))" } ?? ""
            print(
                "\(pad(info.kind.rawValue, 8)) \(pad(info.displayName, 24)) \(pad(status, 16)) \(pad(size, 9)) \(pad("\(info.languageCodes.count) languages", 13)) \(wer)"
            )
            print("         \(info.summary)")
        }
    case "download":
        let kind = try engine(try a.positional(1, "<engine>"))
        try a.checkUnused()
        guard kind != .apple else {
            print("Apple Speech is built in; its language assets download on first use.")
            return
        }
        guard !SpeechModelLibrary.info(kind).isCloud else { throw UsageError(cloudKeyHint) }
        try await download(kind)
        let status = describe(await library.status(kind))
        print("\(SpeechModelLibrary.info(kind).displayName): \(status)")
    case "delete":
        let kind = try engine(try a.positional(1, "<engine>"))
        try a.checkUnused()
        guard kind != .apple else { throw UsageError("Apple Speech is built in and can't be deleted") }
        guard !SpeechModelLibrary.info(kind).isCloud else { throw UsageError(cloudKeyHint) }
        try await library.delete(kind)
        print("Deleted \(SpeechModelLibrary.info(kind).displayName).")
    case "deepgram":
        let language = a.option("language")
        let refresh = a.flag("refresh")
        try a.checkUnused()
        try await listDeepgramModels(language: language, refresh: refresh)
    case let action?:
        throw UsageError("unknown models action “\(action)” (use download, delete or deepgram)")
    }
}

/// `models deepgram`: one line per model, newest families first.
func listDeepgramModels(language: String?, refresh: Bool) async throws {
    eprint("Fetching the Deepgram models your key can use…")
    let catalog = try await SpeechModelLibrary.shared.deepgramModels(refresh: refresh)
    let models = language.map { catalog.models(transcribing: $0) } ?? catalog.models
    let source = catalog.source == .project ? "your project" : "Deepgram's public list (the key can't read its project's models)"
    print("\(models.count) speech-to-text model(s) from \(source):")
    for model in models {
        let modes = model.canStream ? (model.batchLanguages.isEmpty ? "live only" : "live + files") : "files only"
        var line = "\(pad(model.name, 26)) \(pad(model.displayName, 30)) \(pad(model.architecture, 8)) \(pad(model.version, 18)) \(pad(modes, 12))"
        line += " \(model.languageCodes.count) language(s)"
        if let language {
            let live = model.transcribes(language, live: true)
            line += live ? "  \(language): live + files" : "  \(language): files only"
        }
        print(line)
        print("    \(model.languageCodes.joined(separator: " "))")
    }
}

func transcribe(_ a: inout Arguments) async throws {
    let url = try fileURL(try a.positional(0, "<file>"))
    let kind = try a.option("engine").map(engine) ?? PlatformCapabilities.current().defaultSpeechEngine
    let truth = try a.option("truth").map(fileURL)
    let maximumWER = try a.option("max-wer").map { raw in
        guard let value = Double(raw) else { throw UsageError("--max-wer must be a number, got “\(raw)”") }
        return value
    }
    if maximumWER != nil, truth == nil { throw UsageError("--max-wer needs --truth") }
    let language = a.option("language") ?? SessionVoices.languageCode(ofLocale: AppSettings.systemLocaleID)
    let deepgramModel = a.option("deepgram-model")
    try a.checkUnused()
    let started = ContinuousClock.now
    let updates: [TranscriptUpdate]
    if kind == .apple, AppleSpeech.isAvailable {
        // Apple's recognizer needs a locale: the system's region when it speaks this language.
        let system = AppSettings.systemLocaleID
        let locale = SessionVoices.languageCode(ofLocale: system) == language ? system : language
        try await SpeechAssets.ensureInstalled(localeIDs: [locale])
        updates = try await FileTranscriber.transcribe(url: url, localeID: locale)
    } else {
        try await ensureDownloaded(kind)
        let cloud = SpeechModelLibrary.info(kind).isCloud
        eprint(cloud ? "Checking the Deepgram API key…" : "Loading \(SpeechModelLibrary.info(kind).displayName)…")
        try await SpeechModelLibrary.shared.prewarm(kind)
        eprint("\(cloud ? "Checked" : "Loaded") in \(seconds(since: started)).")
        if kind == .deepgram {
            let choice = await SpeechModelLibrary.shared.deepgramModelChoice(deepgramModel, languageCode: language, live: false)
            eprint("Deepgram model: \(choice.model)\(choice.fallbackReason.map { " (\($0))" } ?? "")")
        }
        updates = try await FileTranscriber.transcribe(
            url: url, engine: kind, languageCode: language, prompt: [], customization: nil, deepgramModel: deepgramModel)
    }
    for u in updates {
        let conf = u.confidence.map { String(format: " (%.2f)", $0) } ?? ""
        print("[\(ReportRenderer.timestamp(u.range.start))–\(ReportRenderer.timestamp(u.range.end))]\(conf) \(u.text)")
    }
    eprint("\(updates.count) line(s) by \(engineSummary(updates.map(\.engine))) in \(seconds(since: started)).")
    if let truth {
        let wer = WordErrorRate.compute(reference: try referenceText(truth), hypothesis: updates.map(\.text).joined(separator: " "))
        print("WER \(percent(wer))")
        if let maximumWER, wer > maximumWER {
            eprint("error: word error rate \(percent(wer)) is above --max-wer \(percent(maximumWER))")
            exit(1)
        }
    }
}

/// Reference transcript: a JSON array of objects with "text" (lines joined), else the file's text.
func referenceText(_ url: URL) throws -> String {
    struct Line: Decodable { let text: String }
    let data = try Data(contentsOf: url)
    if let lines = try? JSONDecoder().decode([Line].self, from: data) { return lines.map(\.text).joined(separator: " ") }
    return String(decoding: data, as: UTF8.self)
}

func capabilities(_ a: inout Arguments) throws {
    let json = a.flag("json")
    try a.checkUnused()
    let caps = PlatformCapabilities.current()
    let library = SpeechModelLibrary.shared
    struct Engine: Encodable {
        let engine: SpeechEngineKind
        let supported: Bool
        let reason: String?
        let downloaded: Bool
    }
    struct Report: Encodable {
        let summary: String
        let tier: String
        let minimumMacOS: String
        let machine: MachineInfo
        let hasNeuralEngine: Bool
        let appleSpeechAvailable: Bool
        let appleIntelligence: AppleIntelligenceStatus
        let appleIntelligenceReason: String?
        let hasClaudeKey: Bool
        let defaultSpeechEngine: SpeechEngineKind
        let defaultIntelligence: IntelligenceEngineKind
        let speechEngines: [Engine]
        let features: [PlatformCapabilities.Feature]
    }
    let engines = SpeechEngineKind.allCases.map { kind in
        let reason = caps.speechUnavailableReason(kind)
        return Engine(engine: kind, supported: reason == nil, reason: reason, downloaded: library.isDownloaded(kind))
    }
    if json {
        let report = Report(
            summary: caps.summary, tier: caps.tierName, minimumMacOS: PlatformCapabilities.minimumMacOS,
            machine: caps.machine, hasNeuralEngine: caps.machine.hasNeuralEngine,
            appleSpeechAvailable: caps.appleSpeechAvailable, appleIntelligence: caps.appleIntelligence,
            appleIntelligenceReason: caps.appleIntelligence.reason, hasClaudeKey: caps.hasClaudeKey,
            defaultSpeechEngine: caps.defaultSpeechEngine, defaultIntelligence: caps.defaultIntelligence,
            speechEngines: engines, features: caps.features)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        return
    }
    print(caps.summary)
    print("CPU: \(caps.machine.cpuName) (\(caps.machine.modelIdentifier)), process \(caps.machine.processArchitecture)")
    print("Tier: \(caps.tierName)")
    print("Default voice model: \(caps.defaultSpeechEngine.rawValue); intelligence: \(caps.defaultIntelligence.rawValue)")
    print("")
    for feature in caps.features {
        print("\(feature.isAvailable ? "✓" : "–") \(feature.name)\(feature.reason.map { " — \($0)" } ?? "")")
    }
}

func calibrate(_ a: inout Arguments) async throws {
    if a.flag("regions") {
        try a.checkUnused()
        for r in AccentRegions.all {
            print("\(pad(r.id, 4)) \(pad(r.name, 26)) \(pad(r.continent, 14)) \(r.englishName)  (\(r.vocabulary.count) names/places)")
        }
        return
    }
    let url = try fileURL(try a.positional(0, "<wav>"))
    let name = a.option("name")
    let area = try a.option("region").map(region)
    let language = a.option("language") ?? "en"
    let engineList = try a.option("engines").map { list in
        try list.split(separator: ",").map { try engine($0.trimmingCharacters(in: .whitespaces)) }
    }
    let deepgramModels = a.option("deepgram-model").map { list in
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    } ?? [Deepgram.defaultModel]
    guard (1...3).contains(deepgramModels.count) else { throw UsageError("--deepgram-model takes one to three models") }
    guard let expected = try readingText(&a, name: name, region: area, required: true) else { return }
    try a.checkUnused()

    let samples = try AudioResampler.load16kMono(url: url)
    eprint("Loading voice models…")
    let loadStarted = ContinuousClock.now
    let transcribers: [any AccurateTranscriber]
    if let engineList {
        var loaded: [any AccurateTranscriber] = []
        for kind in engineList {
            try await ensureDownloaded(kind)
            for model in kind == .deepgram ? deepgramModels.map(Optional.some) : [nil] {
                loaded.append(try await SpeechModelLibrary.shared.transcriber(kind, deepgramModel: model))
            }
        }
        transcribers = loaded
    } else {
        transcribers = await EnrollmentService.calibrationTranscribers(languageCode: language, deepgramModels: deepgramModels)
    }
    eprint("Loaded \(transcribers.map { $0.model.map { "deepgram/\($0)" } ?? $0.kind.rawValue }.joined(separator: ", ")) in \(seconds(since: loadStarted)); transcribing…")
    let profile = SpeakerProfile(name: name ?? "", embeddings: [], voice: VoiceSettings(accentRegionID: area?.id))
    let started = ContinuousClock.now
    let result = await EnrollmentService.calibrate(
        samples16k: samples, expected: expected, transcribers: transcribers, languageCode: language,
        vocabulary: EnrollmentService.calibrationVocabulary(for: profile))
    eprint("Scored in \(seconds(since: started)).")
    printCalibration(result.calibration, suggestions: result.suggestedReplacements)
}

/// The text a recording reads: `--text file`, `--standard`, else (with a name) the enrollment passage.
func readingText(_ a: inout Arguments, name: String?, region: AccentRegion?, required: Bool) throws -> String? {
    let standard = a.flag("standard")
    if let path = a.option("text") {
        guard !standard else { throw UsageError("pass either --standard or --text") }
        return try String(contentsOf: fileURL(path), encoding: .utf8)
    }
    if standard { return CalibrationPassages.standard }
    if let name { return EnrollmentService.passage(name: name, region: region) }
    if required { throw UsageError("say what the recording reads: --standard, --text <file>, or --name <name>") }
    return nil
}

func printCalibration(_ calibration: VoiceCalibration, suggestions: [TextReplacement]) {
    guard let best = calibration.best else {
        print("Calibration: no voice model could transcribe the recording.")
        return
    }
    print("Calibration (word error rate, best first):")
    for (i, s) in calibration.scores.enumerated() {
        print("  \(i + 1). \(pad(scoreName(s), 24)) \(pad(percent(s.wordErrorRate), 6))  “\(s.transcript)”")
    }
    print("Best: \(scoreName(best))")
    if !suggestions.isEmpty {
        print("Suggested corrections:")
        for r in suggestions { print("  heard “\(r.heard)” → “\(r.meant)”") }
    }
}

/// "Cohere Transcribe", "Deepgram Nova-2 Meeting".
func scoreName(_ score: EngineScore) -> String {
    guard score.engine == .deepgram, let model = score.model else { return SpeechModelLibrary.info(score.engine).displayName }
    return "Deepgram \(Deepgram.modelDisplayName(model))"
}

func engine(_ raw: String) throws -> SpeechEngineKind {
    guard let kind = SpeechEngineKind(rawValue: raw.lowercased()) else {
        throw UsageError("unknown engine “\(raw)” (use \(SpeechEngineKind.allCases.map(\.rawValue).joined(separator: ", ")))")
    }
    return kind
}

func region(_ raw: String) throws -> AccentRegion {
    guard let r = AccentRegions.region(raw.lowercased()) else {
        throw UsageError("unknown region “\(raw)” (list them with `calibrate --regions`)")
    }
    return r
}

func describe(_ status: ModelStatus) -> String {
    switch status {
    case .notDownloaded: "not downloaded"
    case .downloading(let f): "downloading \(Int(f * 100))%"
    case .downloaded: "downloaded"
    case .loading: "loading"
    case .ready: "ready"
    case .failed(let reason): "failed: \(reason)"
    }
}

func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

func seconds(since start: ContinuousClock.Instant) -> String {
    (ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
}

/// "cohere 24, apple 1" — how many lines each engine produced.
func engineSummary(_ engines: [SpeechEngineKind?]) -> String {
    var counts: [String: Int] = [:]
    for e in engines { counts[e?.rawValue ?? "unknown", default: 0] += 1 }
    return counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
}

let cloudKeyHint =
    "Deepgram runs in the cloud: nothing to download. Give it your API key in Settings › Voice Models, DEEPGRAM_API_KEY or ~/.deepgram_secret."

/// Downloads `kind` unless it's already on this Mac (or in the cloud), printing progress.
func ensureDownloaded(_ kind: SpeechEngineKind) async throws {
    guard kind != .apple, !SpeechModelLibrary.info(kind).isCloud else { return }
    let status = await SpeechModelLibrary.shared.status(kind)
    if SessionVoices.availableEngines([kind: status]).contains(kind) { return }
    try await download(kind)
}

func download(_ kind: SpeechEngineKind) async throws {
    let info = SpeechModelLibrary.info(kind)
    eprint("Downloading \(info.displayName) (\(ByteCountFormatter.string(fromByteCount: info.downloadBytes, countStyle: .file)))…")
    let updates = SpeechModelLibrary.shared.statusUpdates
    let progress = Task {
        var shown = -1
        for await (k, status) in updates where k == kind {
            guard case .downloading(let fraction) = status else { continue }
            let pct = Int(fraction * 100)
            if pct / 10 > shown / 10 {
                shown = pct
                eprint("  \(pct)%")
            }
        }
    }
    defer { progress.cancel() }
    try await SpeechModelLibrary.shared.download(kind)
}

@MainActor
func process(_ a: inout Arguments) async throws {
    let url = try fileURL(try a.positional(0, "<file>"))
    let profileStore = SpeakerProfileStore(directory: directoryURL(a.option("profiles"), default: AppPaths.default.profiles))
    let speechEngine = try a.option("engine").map(engine) ?? PlatformCapabilities.current().defaultSpeechEngine
    let deepgramModel = a.option("deepgram-model") ?? Deepgram.defaultModel
    let intelligence = try intelligenceKind(a.option("intelligence"))
    let spelling = try a.option("spelling").map { raw in
        guard let s = SpellingVariant(rawValue: raw.lowercased()) else {
            throw UsageError("--spelling must be british, american or unchanged")
        }
        return s
    } ?? .unchanged
    let locale = a.option("locale") ?? AppSettings.systemLocaleID
    let title = a.option("title")
    let out = a.option("out")
    let json = a.option("json")
    let truth = try a.option("truth").map(fileURL)
    let meetingsDir = directoryURL(
        a.option("meetings"),
        default: FileManager.default.temporaryDirectory.appending(path: "voiccenger-cli", directoryHint: .isDirectory))
    let analysis = !a.flag("no-analysis")
    let autoLanguage = !a.flag("no-auto-language")
    try a.checkUnused()

    try await ensureDownloaded(speechEngine)
    let profiles = await profileStore.all()
    eprint("Processing \(url.lastPathComponent) with \(SpeechModelLibrary.info(speechEngine).displayName) and \(profiles.count) enrolled voice(s)…")
    let config = MeetingSession.Config(
        title: title, kind: .inPerson, localeID: locale, autoLanguage: autoLanguage, engineKind: intelligence,
        speechEngine: speechEngine, deepgramModel: deepgramModel, spelling: spelling, recordAudio: false,
        meetingsDirectory: meetingsDir,
        liveAnalysis: analysis)
    let started = ContinuousClock.now
    let meeting = try await MeetingSession.processFile(url: url, config: config, profiles: profiles)
    eprint(
        "Done in \(seconds(since: started)): \(meeting.segments.count) lines, \(meeting.participants.count) participant(s); saved to \(meetingsDir.appending(path: meeting.id.uuidString).path)"
    )
    eprint("Lines by engine: \(engineSummary(meeting.segments.map(\.engine)))")
    if meeting.report == nil { eprint("No report was written (the intelligence engine failed).") }

    let markdown = ReportRenderer.markdown(meeting)
    if let out {
        try markdown.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), atomically: true, encoding: .utf8)
        eprint("Report written to \(out)")
    } else {
        print(markdown)
    }
    if let json {
        try MeetingStore.encoder.encode(meeting).write(to: URL(fileURLWithPath: (json as NSString).expandingTildeInPath))
        eprint("Meeting JSON written to \(json)")
    }
    if let truth { try scoreSpeakers(meeting, truth: truth) }
}

/// `apple`, `claude` or `outline` (the transcript outline without AI); nil is `apple`.
func intelligenceKind(_ raw: String?) throws -> IntelligenceEngineKind {
    switch raw?.lowercased() {
    case nil, "apple": .apple
    case "claude": .claude
    case "outline", "transcriptoutline", "none": .transcriptOutline
    default: throw UsageError("--intelligence must be apple, claude or outline")
    }
}

/// Writes the report for a transcript file, timing it.
@MainActor
func report(_ a: inout Arguments) async throws {
    struct Line: Decodable {
        var speaker: String
        var start: Double
        var end: Double?
        var text: String
    }
    let url = try fileURL(try a.positional(0, "<transcript.json>"))
    let kind = try intelligenceKind(a.option("intelligence"))
    let title = a.option("title")
    let out = a.option("out")
    try a.checkUnused()

    let lines = try JSONDecoder().decode([Line].self, from: Data(contentsOf: url))
    var participants: [Participant] = []
    for (i, name) in lines.map(\.speaker).enumerated() where !participants.contains(where: { $0.id == name }) {
        participants.append(Participant(id: name, displayName: name, channel: .microphone, colorIndex: i))
    }
    for i in participants.indices {
        participants[i].speakingTime = lines.filter { $0.speaker == participants[i].id }.reduce(0) { $0 + max(0, ($1.end ?? $1.start) - $1.start) }
    }
    let segments = lines.map { line in
        TranscriptSegment(
            channel: .microphone, speakerKey: line.speaker, range: TimeRange(start: line.start, end: line.end ?? line.start),
            text: line.text, confidence: nil, localeID: "en")
    }
    let start = Date()
    var meeting = Meeting(
        title: title ?? url.deletingPathExtension().lastPathComponent, kind: .inPerson, startedAt: start,
        endedAt: start.addingTimeInterval(lines.map { $0.end ?? $0.start }.max() ?? 0), participants: participants,
        segments: segments, localeIDs: ["en"])
    let choice = ReportWriter.engine(preferring: kind)
    if choice.isFallback { eprint("The requested engine is unavailable; using \(choice.engine.engineName).") }
    eprint("Writing the report for \(lines.count) lines with \(choice.engine.engineName)…")
    let started = ContinuousClock.now
    meeting.report = try await ReportWriter.report(for: meeting, engine: choice.engine, title: title)
    eprint("Report written in \(seconds(since: started)).")
    let markdown = ReportRenderer.markdown(meeting)
    if let out {
        try markdown.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), atomically: true, encoding: .utf8)
        eprint("Report written to \(out)")
    } else {
        print(markdown)
    }
}

/// One ground-truth turn from `MakeFixtures.swift`.
struct TruthTurn: Decodable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

/// For each true turn, the speaker credited with most of the transcript time inside it.
func scoreSpeakers(_ meeting: Meeting, truth url: URL) throws {
    let turns = try JSONDecoder().decode([TruthTurn].self, from: Data(contentsOf: url))
    var correct = 0
    print("\nPer-turn speaker accuracy:")
    for (i, turn) in turns.enumerated() {
        let range = TimeRange(start: turn.start, end: turn.end)
        var credit: [String: Double] = [:]
        for s in meeting.segments {
            let overlap = s.range.overlap(with: range)
            if overlap > 0 { credit[ReportRenderer.displayName(for: s.speakerKey, in: meeting), default: 0] += overlap }
        }
        let predicted = credit.max { $0.value < $1.value }?.key ?? "—"
        let ok = predicted.caseInsensitiveCompare(turn.speaker) == .orderedSame
        if ok { correct += 1 }
        print(
            "  \(pad("\(i + 1).", 4)) \(ReportRenderer.timestamp(turn.start)) \(pad(turn.speaker, 10)) → \(pad(predicted, 12)) \(ok ? "✓" : "✗")"
        )
    }
    let pct = turns.isEmpty ? 0 : Double(correct) / Double(turns.count) * 100
    print("Speaker accuracy: \(correct)/\(turns.count) turns (\(String(format: "%.0f", pct))%)")
}

/// Short command-line names for the array presets.
enum ArrayPresetIDs {
    static let all: [(id: String, geometry: MicArrayGeometry)] = [
        ("respeaker4", ArrayPresets.respeaker4), ("respeaker6", ArrayPresets.respeaker6), ("uma8", ArrayPresets.uma8),
    ]
}

func systemAudio(_ a: inout Arguments) async throws {
    let seconds = try a.double("seconds", default: 5)
    let app = try a.option("app").map { id in
        guard let app = MeetingAppCatalog.app(forBundleID: id) else {
            throw UsageError("“\(id)” isn't a known meeting app (e.g. us.zoom.xos, com.microsoft.teams2)")
        }
        return app
    }
    let out = a.option("out")
    try a.checkUnused()

    let target = SystemAudioTarget(meetingApp: app)
    if case .app(let app) = target {
        let family = AudioProcesses.family(of: app, in: AudioProcesses.current())
        eprint("\(app.displayName) processes: \(family.map { "\($0.bundleID) (\($0.pid))" }.joined(separator: ", "))")
    }
    let source = SystemAudioSource(target: target, clock: SessionClock())
    let events = Task {
        for await event in source.events {
            switch event {
            case .tapping(let target, let pids):
                eprint("Tapping \(target)\(pids.isEmpty ? "" : " (pids \(pids.map(String.init).joined(separator: ",")))")")
            case .fellBackToGlobal(let app, let reason): eprint("Recording all computer audio instead of \(app.displayName): \(reason)")
            case .failed(let reason): eprint("Capture failed: \(reason)")
            }
        }
    }
    let stream = try await source.start()
    eprint("Capturing \(target) for \(seconds) s…")
    let stopper = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await source.stop()
    }
    var recorder: AudioRecorder?
    var chunks = 0, frames = 0
    var sumSquares = 0.0, peak: Float = 0
    var sampleRate = 0.0
    for await chunk in stream {
        if recorder == nil, let out {
            recorder = try AudioRecorder(url: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), sampleRate: chunk.sampleRate)
        }
        recorder?.append(chunk)
        chunks += 1
        frames += chunk.samples.count
        sampleRate = chunk.sampleRate
        for s in chunk.samples {
            sumSquares += Double(s * s)
            peak = max(peak, abs(s))
        }
    }
    stopper.cancel()
    await events.value
    recorder?.close()
    let rms = frames > 0 ? (sumSquares / Double(frames)).squareRoot() : 0
    print("Chunks: \(chunks), frames: \(frames) at \(sampleRate) Hz (\(String(format: "%.2f", sampleRate > 0 ? Double(frames) / sampleRate : 0)) s)")
    print("Level: RMS \(String(format: "%.1f", 20 * log10(max(rms, 1e-10)))) dBFS, peak \(String(format: "%.1f", 20 * log10(max(Double(peak), 1e-10)))) dBFS")
    if frames > 0 && peak == 0 {
        print("All samples were silent: nothing was playing, or this app lacks “Screen & System Audio Recording” permission.")
    }
    if let out, recorder != nil { print("Recorded to \(out)") }
}

/// `record`: a live meeting through the full pipeline (microphone + computer audio), then its transcript per
/// channel and the report.
@MainActor
func record(_ a: inout Arguments) async throws {
    let seconds = try a.double("seconds", default: 30)
    let kind: MeetingKind =
        switch a.option("kind")?.lowercased() {
        case nil, "in-person", "inperson": .inPerson
        case "online": .online
        case let other?: throw UsageError("--kind must be in-person or online, got “\(other)”")
        }
    let app = try a.option("app").map { id in
        guard let app = MeetingAppCatalog.app(forBundleID: id) else { throw UsageError("“\(id)” isn't a known meeting app") }
        return app
    }
    let profileStore = SpeakerProfileStore(directory: directoryURL(a.option("profiles"), default: AppPaths.default.profiles))
    let speechEngine = try a.option("engine").map(engine) ?? PlatformCapabilities.current().defaultSpeechEngine
    let intelligence = try intelligenceKind(a.option("intelligence"))
    let locale = a.option("locale") ?? AppSettings.systemLocaleID
    let title = a.option("title")
    let out = a.option("out")
    let json = a.option("json")
    let meetingsDir = directoryURL(
        a.option("meetings"),
        default: FileManager.default.temporaryDirectory.appending(path: "voiccenger-cli", directoryHint: .isDirectory))
    let computerAudio = !a.flag("no-computer-audio")
    let detect = a.flag("detect")
    let analysis = !a.flag("no-analysis")
    try a.checkUnused()

    try await ensureDownloaded(speechEngine)
    let profiles = await profileStore.all()
    let detected = app.map { app in
        DetectedMeeting(
            app: app, processIDs: AudioProcesses.family(of: app, in: AudioProcesses.current()).map(\.pid), startedAt: Date())
    }
    let config = MeetingSession.Config(
        title: title, kind: detected == nil ? kind : .online, detectedMeeting: detected, localeID: locale,
        engineKind: intelligence, speechEngine: speechEngine, recordComputerAudio: computerAudio,
        meetingsDirectory: meetingsDir, liveAnalysis: analysis)
    let session = MeetingSession(config: config, profiles: profiles)
    try await session.start()
    let channels = config.kind == .online || computerAudio ? "microphone + computer audio" : "microphone"
    eprint("Recording a\(config.kind == .online ? "n online" : "n in-person") meeting for \(seconds) s (\(channels))…")
    let detector = detect ? MeetingDetector() : nil
    let upgrades = Task { @MainActor in
        guard let detector else { return }
        for await event in detector.events() {
            guard case .meetingStarted(let meeting) = event, session.detectedMeeting == nil else { continue }
            eprint("\(meeting.app.displayName) started using the microphone: the meeting is now online.")
            await session.upgradeToOnline(meeting)
        }
    }
    try await Task.sleep(for: .seconds(seconds))
    detector?.stop()
    upgrades.cancel()
    eprint("Finishing…")
    let meeting = try await session.stop()

    for channel in AudioChannel.allCases {
        let lines = meeting.segments.filter { $0.channel == channel }.sorted { $0.range.start < $1.range.start }
        print("\n\(channel == .microphone ? "Microphone" : "Computer audio") (\(lines.count) line\(lines.count == 1 ? "" : "s")):")
        for line in lines {
            let speaker = meeting.participant(line.speakerKey)?.displayName ?? line.speakerKey
            print(String(format: "  [%6.1f–%6.1f] ", line.range.start, line.range.end) + "\(speaker): \(line.text)")
        }
    }
    print("\nType: \(meeting.kind == .online ? "online" + (meeting.appName.map { " (\($0))" } ?? "") : "in person")")
    print("Audio files: \(meeting.audioFiles.joined(separator: ", ")) in \(meetingsDir.appending(path: meeting.id.uuidString).path)")
    if session.bleedLinesRemoved > 0 {
        print("Microphone lines removed as speaker bleed: \(session.bleedLinesRemoved)")
    }
    for warning in meeting.captureWarnings { print(String(format: "Capture warning at %.0f s: ", warning.time) + warning.message) }
    for warning in session.warnings { print("Warning: \(warning)") }

    if let out {
        try ReportRenderer.markdown(meeting)
            .write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), atomically: true, encoding: .utf8)
        eprint("Report written to \(out)")
    }
    if let json {
        try MeetingStore.encoder.encode(meeting).write(to: URL(fileURLWithPath: (json as NSString).expandingTildeInPath))
        eprint("Meeting JSON written to \(json)")
    }
}

func doa(_ a: inout Arguments) throws {
    let presetName = a.option("preset") ?? "respeaker4"
    guard
        let geometry = ArrayPresetIDs.all.first(where: { $0.id == presetName.lowercased() })?.geometry
            ?? ArrayPresets.all.first(where: { $0.name.caseInsensitiveCompare(presetName) == .orderedSame })
    else {
        throw UsageError("unknown preset “\(presetName)”; choose one of \(ArrayPresetIDs.all.map(\.id).joined(separator: ", "))")
    }
    let angle = try a.double("angle", default: 0)
    let snr = try a.double("snr", default: 20)
    let reverb = try a.double("reverb", default: 0)
    let sourcePath = a.option("source")
    try a.checkUnused()

    let sampleRate = 16_000.0
    let source: [Float] = try sourcePath.map { Array(try AudioResampler.load16kMono(url: try fileURL($0)).prefix(Int(sampleRate * 2))) }
        ?? speechShapedNoise(seconds: 1, sampleRate: sampleRate)
    let simulator = ArraySimulator(geometry: geometry, sampleRate: sampleRate)
    let perMic = simulator.render(source: source, azimuthDegrees: angle, snrDB: snr, reverb: reverb)

    // Place microphone signals at their device channel indices, as captured from the hardware.
    let channelCount = (geometry.channelMap.max() ?? -1) + 1
    var channels = [[Float]](repeating: [Float](repeating: 0, count: source.count), count: channelCount)
    for (mic, channel) in geometry.channelMap.enumerated() where mic < perMic.count { channels[channel] = perMic[mic] }
    var mono = [Float](repeating: 0, count: source.count)
    for signal in perMic { for i in mono.indices { mono[i] += signal[i] / Float(perMic.count) } }
    let chunk = AudioChunk(channel: .microphone, startTime: 0, sampleRate: sampleRate, samples: mono, channelSamples: channels)

    let estimator = DirectionEstimator(geometry: geometry)
    print("Array: \(geometry.name), \(geometry.mics.count) mics, aperture \(String(format: "%.1f", geometry.aperture * 100)) cm")
    print("Source: \(sourcePath ?? "speech-shaped noise"), true azimuth \(String(format: "%.1f", angle))°, SNR \(snr) dB, reverb \(reverb)")
    guard let estimate = estimator.estimate(chunk) else {
        print("No estimate (signal below the energy gate).")
        return
    }
    var error = abs(estimate.azimuthDegrees - angle).truncatingRemainder(dividingBy: 360)
    if error > 180 { error = 360 - error }
    print("Estimated azimuth \(String(format: "%.1f", estimate.azimuthDegrees))° (error \(String(format: "%.1f", error))°), confidence \(String(format: "%.2f", estimate.confidence))")
    let aliasing = ArraySimulator.spatialAliasingFrequency(micSpacing: geometry.aperture)
    print("Spatial aliasing above \(String(format: "%.0f", aliasing)) Hz for the widest pair")

    let response = estimator.response(chunk)
    if response.count == 360, let peak = response.max(), peak > 0 {
        print("\nSteered response power (10° bins):")
        for bin in stride(from: 0, to: 360, by: 10) {
            let value = response[bin..<bin + 10].max() ?? 0
            let bar = String(repeating: "█", count: max(0, Int((value / peak) * 40)))
            print("  \(pad("\(bin)°", 5)) \(bar)")
        }
    }
}

/// Deterministic noise shaped like speech's spectrum (low-passed, ~syllabic amplitude modulation).
func speechShapedNoise(seconds: Double, sampleRate: Double) -> [Float] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var lowPassed: Float = 0
    let count = Int(seconds * sampleRate)
    return (0..<count).map { i in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let white = Float(Int64(bitPattern: state >> 1) % 2_000_001) / 1_000_000 - 1
        lowPassed = 0.7 * lowPassed + 0.3 * white
        let envelope = Float(0.6 + 0.4 * sin(2 * Double.pi * 4 * Double(i) / sampleRate))
        return 0.5 * lowPassed * envelope
    }
}

// MARK: - Entry point

let commandFlags: [String: Set<String>] = [
    "detect": ["watch"],
    "enroll": ["standard"],
    "calibrate": ["standard", "regions"],
    "process": ["no-analysis", "no-auto-language"],
    "record": ["no-computer-audio", "detect", "no-analysis"],
    "models": ["refresh"],
    "capabilities": ["json"],
]

let argv = CommandLine.arguments.dropFirst()
guard let command = argv.first, command != "-h", command != "--help", command != "help" else {
    print(usage)
    exit(argv.isEmpty ? 64 : 0)
}

do {
    var args = try Arguments(argv.dropFirst(), flags: commandFlags[command] ?? [])
    if args.wantsHelp {
        print(usage)
        exit(0)
    }
    switch command {
    case "capabilities": try capabilities(&args)
    case "devices": try devices(&args)
    case "detect": try await detect(&args)
    case "enroll": try await enroll(&args)
    case "profiles": try await profiles(&args)
    case "models": try await models(&args)
    case "transcribe": try await transcribe(&args)
    case "calibrate": try await calibrate(&args)
    case "process": try await process(&args)
    case "report": try await report(&args)
    case "record": try await record(&args)
    case "doa": try doa(&args)
    case "system-audio": try await systemAudio(&args)
    default: throw UsageError("unknown command “\(command)”")
    }
} catch let error as UsageError {
    eprint("error: \(error.description)\nRun `voiccenger-cli --help` for usage.")
    exit(64)
} catch {
    eprint("error: \(error.localizedDescription)")
    exit(1)
}
