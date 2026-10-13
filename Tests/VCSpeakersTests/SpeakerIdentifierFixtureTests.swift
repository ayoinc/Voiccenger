import Foundation
import Testing
import VCModels
@testable import VCSpeakers

/// End-to-end attribution on the synthetic four-voice meeting (Daniel en-GB, Samantha en-US,
/// Rishi en-IN, Karen en-AU). Downloads the FluidAudio models on first run.
@Suite("SpeakerIdentifier fixtures", .serialized, .enabled { await Fixtures.modelsAndFixturesAvailable() })
struct SpeakerIdentifierFixtureTests {
    struct Run {
        var turns: [SpeakerTurn]
        var elapsed: Duration
        var audioSeconds: Double
        var elapsedSeconds: Double {
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        var runtimeFactor: Double { elapsedSeconds / audioSeconds }
    }

    static func enrolledProfiles() async throws -> [SpeakerProfile] {
        var profiles: [SpeakerProfile] = []
        for (index, name) in Fixtures.enrolledNames.enumerated() {
            let clip = try Fixtures.load("enroll_\(name).wav")
            let embeddings = try await SpeakerEnrollment.embeddings(samples16k: clip.samples)
            profiles.append(SpeakerProfile(name: name, embeddings: embeddings, colorIndex: index))
        }
        return profiles
    }

    /// Streams `samples` through a fresh identifier in 100 ms chunks, then flushes.
    static func run(
        samples: [Float], sampleRate: Double, profiles: [SpeakerProfile], config: SpeakerIDConfig = .init(),
        channel: AudioChannel = .microphone, startTime: TimeInterval = 0
    ) async throws -> Run {
        let identifier = SpeakerIdentifier(channel: channel, config: config)
        try await identifier.prepare()
        await identifier.setProfiles(profiles)
        let chunk = Int(sampleRate / 10)
        var turns: [SpeakerTurn] = []
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + chunk)
                turns += try await identifier.process(
                    AudioChunk(
                        channel: channel, startTime: startTime + Double(offset) / sampleRate, sampleRate: sampleRate,
                        samples: Array(samples[offset..<end])))
                offset = end
            }
            turns += try await identifier.flush()
        }
        return Run(turns: turns, elapsed: elapsed, audioSeconds: Double(samples.count) / sampleRate)
    }

    /// For each truth line, the label of the turn overlapping it most (nil when nothing overlaps).
    static func predictions(
        _ turns: [SpeakerTurn], truth: [Fixtures.TruthTurn], offset: TimeInterval = 0, label: (SpeakerTurn) -> String
    ) -> [String?] {
        truth.map { line in
            let range = TimeRange(start: line.start + offset, end: line.end + offset)
            let best = turns.max { $0.range.overlap(with: range) < $1.range.overlap(with: range) }
            guard let best, best.range.overlap(with: range) > 0 else { return nil }
            return label(best)
        }
    }

    static func accuracy(_ predicted: [String?], truth: [Fixtures.TruthTurn]) -> Double {
        Double(zip(predicted, truth).filter { $0.0 == $0.1.speaker }.count) / Double(truth.count)
    }

    static func confusionMatrix(_ predicted: [String?], truth: [Fixtures.TruthTurn]) -> String {
        let columns = Fixtures.enrolledNames + ["unknown"]
        var counts: [String: [String: Int]] = [:]
        for (p, t) in zip(predicted, truth) {
            let column = p.flatMap { columns.contains($0) ? $0 : nil } ?? "unknown"
            counts[t.speaker, default: [:]][column, default: 0] += 1
        }
        var lines = ["truth \\ predicted".padding(toLength: 18, withPad: " ", startingAt: 0)
            + columns.map { $0.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined()]
        for row in Fixtures.enrolledNames {
            lines.append(row.padding(toLength: 18, withPad: " ", startingAt: 0)
                + columns.map { String(counts[row]?[$0] ?? 0).padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
        }
        return lines.joined(separator: "\n")
    }

    static func nameLabel(_ profiles: [SpeakerProfile]) -> (SpeakerTurn) -> String {
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        return { turn in turn.profileID.flatMap { names[$0] } ?? turn.speakerKey }
    }

    @Test func enrolledVoicesAreAttributedInTheMeeting() async throws {
        let profiles = try await Self.enrolledProfiles()
        let truth = try Fixtures.truth()
        let meeting = try Fixtures.load("meeting.wav")

        // Pairwise similarity of the enrolled voices (max cosine across their enrollment windows).
        var matrix = "enrolled voice similarity (max cosine)\n" + String(repeating: " ", count: 10)
            + Fixtures.enrolledNames.map { $0.padding(toLength: 10, withPad: " ", startingAt: 0) }.joined()
        for a in profiles {
            matrix += "\n" + a.name.padding(toLength: 10, withPad: " ", startingAt: 0)
            for b in profiles {
                let s = a.id == b.id
                    ? 1.0
                    : a.embeddings.flatMap { x in b.embeddings.map { SpeakerMatcher.cosine(x, $0) } }.max() ?? 0
                matrix += String(format: "%-10.3f", s)
            }
        }
        print(matrix)

        let run = try await Self.run(samples: meeting.samples, sampleRate: meeting.sampleRate, profiles: profiles)
        let predicted = Self.predictions(run.turns, truth: truth, label: Self.nameLabel(profiles))
        let accuracy = Self.accuracy(predicted, truth: truth)
        print("enrolled attribution accuracy: \(Int(accuracy * 100))% (\(run.turns.count) turns)")
        print(Self.confusionMatrix(predicted, truth: truth))
        print(String(format: "runtime factor: %.3f× real time (%.2f s for %.1f s audio)", run.runtimeFactor, run.elapsedSeconds, run.audioSeconds))
        #expect(accuracy >= 0.8)

        for turn in run.turns {
            #expect(turn.channel == .microphone)
            #expect((0...1).contains(turn.confidence))
            #expect(turn.range.start >= 0 && turn.range.end <= run.audioSeconds + 0.01)
            if let id = turn.profileID {
                #expect(turn.speakerKey == SpeakerTurn.profileKey(id))
            } else {
                #expect(turn.speakerKey.hasPrefix("mic:"))
            }
        }

        // Seeding FluidAudio's SpeakerManager with the enrolled voices: measured for comparison.
        var seeded = SpeakerIDConfig()
        seeded.seedDiarizerWithProfiles = true
        let seededRun = try await Self.run(samples: meeting.samples, sampleRate: meeting.sampleRate, profiles: profiles, config: seeded)
        let seededAccuracy = Self.accuracy(
            Self.predictions(seededRun.turns, truth: truth, label: Self.nameLabel(profiles)), truth: truth)
        print("with seeded diarizer: \(Int(seededAccuracy * 100))% accuracy")
    }

    @Test func liveRateAudioIsResampledAndAttributed() async throws {
        let profiles = try await Self.enrolledProfiles()
        let truth = try Fixtures.truth()
        let meeting = try Fixtures.load("meeting.wav")
        let up = try #require(StreamingResampler(from: meeting.sampleRate, to: 48_000))
        let samples48k = try up.process(meeting.samples) + up.finish()

        let run = try await Self.run(samples: samples48k, sampleRate: 48_000, profiles: profiles)
        let accuracy = Self.accuracy(Self.predictions(run.turns, truth: truth, label: Self.nameLabel(profiles)), truth: truth)
        print("48 kHz input attribution accuracy: \(Int(accuracy * 100))%")
        #expect(accuracy >= 0.8)
    }

    @Test func unenrolledSpeakersGetStableChannelScopedKeys() async throws {
        let truth = try Fixtures.truth()
        let meeting = try Fixtures.load("meeting.wav")
        let offset: TimeInterval = 100
        // The fixture's synthetic voices sit closer together than real speakers do, so separate them
        // with a tighter clustering threshold than the real-meeting default (0.7 merges them into 2).
        var config = SpeakerIDConfig()
        config.clusteringThreshold = 0.4
        let run = try await Self.run(
            samples: meeting.samples, sampleRate: meeting.sampleRate, profiles: [], config: config, channel: .system,
            startTime: offset)

        let keys = Set(run.turns.map(\.speakerKey))
        print("unenrolled distinct clusters: \(keys.count) \(keys.sorted())")
        #expect(!run.turns.isEmpty)
        for turn in run.turns {
            #expect(turn.profileID == nil)
            #expect(turn.speakerKey.hasPrefix("sys:"))
            #expect(turn.range.start >= offset && turn.range.end <= offset + run.audioSeconds + 0.01)
        }

        // Each true speaker should map to one dominant key, and different speakers to different keys.
        let predicted = Self.predictions(run.turns, truth: truth, offset: offset) { $0.speakerKey }
        var keyBySpeaker: [String: [String: Int]] = [:]
        for (p, t) in zip(predicted, truth) {
            if let p { keyBySpeaker[t.speaker, default: [:]][p, default: 0] += 1 }
        }
        for name in Fixtures.enrolledNames {
            print("  \(name): \(keyBySpeaker[name] ?? [:])")
        }
        let dominant = Fixtures.enrolledNames.compactMap { keyBySpeaker[$0]?.max { $0.value < $1.value }?.key }
        let consistent = zip(predicted, truth).filter { p, t in
            p != nil && p == keyBySpeaker[t.speaker]?.max { $0.value < $1.value }?.key
        }.count
        print("unenrolled cluster consistency: \(consistent)/\(truth.count), distinct dominant keys: \(Set(dominant).count)")
        #expect(Set(dominant).count == Fixtures.enrolledNames.count)
        #expect(Double(consistent) / Double(truth.count) >= 0.8)
    }
}
