import FluidAudio
import Foundation
import VCModels

/// Live "who spoke when" for one channel, attributing speech to enrolled people when possible.
///
/// Audio of any sample rate is resampled to 16 kHz mono and buffered; every `windowSeconds` the
/// window goes through FluidAudio's `DiarizerManager` (pyannote segmentation + WeSpeaker
/// embeddings). Its `SpeakerManager` keeps cluster ids consistent across windows, so an unknown
/// voice keeps one key (`"mic:S2"`) for the whole meeting.
///
/// ## Telling similar voices apart
/// Three layers decide which enrolled person a segment belongs to:
/// 1. **Multiple enrollment embeddings.** Each profile carries one embedding per 5 s enrollment
///    window; a segment's score for a person is the maximum cosine over them, so the closest
///    phonetic context counts rather than a blurred average.
/// 2. **Margin test.** A segment is only called confidently when its best profile beats the
///    runner-up by `ambiguityMargin`; otherwise it is ambiguous.
/// 3. **Cluster voting.** Every confident segment votes (duration × similarity) for its profile
///    within its diarizer cluster. Once one profile holds ≥ 60 % of a cluster's votes (and
///    enough evidence), ambiguous or slightly-below-threshold segments of that cluster resolve to
///    it — the cluster has been consistently that person. A confident per-segment match always
///    wins over the cluster vote, because the diarizer itself can merge two similar voices.
/// Optionally (`seedDiarizerWithProfiles`) enrolled profiles are also seeded into FluidAudio's
/// `SpeakerManager` as permanent speakers.
public actor SpeakerIdentifier {
    public nonisolated let channel: AudioChannel
    public nonisolated let config: SpeakerIDConfig

    private let queue: DispatchSerialQueue
    /// CoreML inference is synchronous; running the actor on its own queue keeps it off the
    /// cooperative thread pool.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    static let sampleRate = 16_000
    /// Gaps up to this long are bridged with silence; longer ones close the current window.
    static let maxBridgedGap: TimeInterval = 1.0
    /// Below this, input is treated as clock jitter rather than a gap.
    static let jitterTolerance: TimeInterval = 0.05
    /// Shorter leftovers carry no attributable speech (FluidAudio's minimum segment is 1 s).
    static let minimumWindowSeconds: TimeInterval = 1.0
    /// A cluster's lead profile needs this share of the cluster's confident votes...
    static let clusterLeadShare = 0.6
    /// ...and at least this much vote weight (seconds × similarity).
    static let clusterLeadMinimumWeight = 1.5
    /// How far below `matchThreshold` a segment may score and still inherit its cluster's lead.
    static let clusterThresholdRelaxation = 0.1

    private var diarizer: DiarizerManager?
    private var profiles: [SpeakerProfile] = []
    private var resampler: StreamingResampler?
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var hasTimeline = false
    /// Diarizer cluster id → profile id → accumulated confident vote weight.
    private var clusterVotes: [String: [UUID: Double]] = [:]
    /// FluidAudio speaker ids that are seeded enrolled profiles.
    private var seededSpeakerIDs: Set<String> = []

    public init(channel: AudioChannel, config: SpeakerIDConfig = .init()) {
        self.channel = channel
        self.config = config
        self.queue = DispatchSerialQueue(label: "VCSpeakers.SpeakerIdentifier.\(channel.rawValue)", qos: .userInitiated)
    }

    /// Loads the shared models (downloading on first use). Called implicitly by `process`.
    public func prepare() async throws {
        guard diarizer == nil else { return }
        let models = try await SpeakerModels.loaded()
        guard diarizer == nil else { return }
        let manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: config.clusteringThreshold))
        manager.initialize(models: models)
        diarizer = manager
        seedDiarizer()
    }

    /// Replaces the enrolled people to match against. Takes effect from the next window.
    public func setProfiles(_ profiles: [SpeakerProfile]) {
        self.profiles = profiles.filter { !$0.embeddings.isEmpty }
        let ids = Set(self.profiles.map(\.id))
        for cluster in clusterVotes.keys {
            clusterVotes[cluster] = clusterVotes[cluster]?.filter { ids.contains($0.key) }
        }
        seedDiarizer()
    }

    /// Buffers `chunk` and returns turns for every window it completes.
    public func process(_ chunk: AudioChunk) async throws -> [SpeakerTurn] {
        try await prepare()
        let samples = try resample(chunk)
        var turns: [SpeakerTurn] = []

        if !hasTimeline {
            pendingStart = chunk.startTime
            hasTimeline = true
        } else {
            let pendingEnd = pendingStart + Double(pending.count) / Double(Self.sampleRate)
            let gap = chunk.startTime - pendingEnd
            if gap > Self.maxBridgedGap {
                turns += try diarizePending()
                pendingStart = chunk.startTime
            } else if gap > Self.jitterTolerance {
                pending.append(contentsOf: repeatElement(0, count: Int(gap * Double(Self.sampleRate))))
            }
        }
        pending.append(contentsOf: samples)

        let windowSamples = max(Self.sampleRate, Int(config.windowSeconds * Double(Self.sampleRate)))
        while pending.count >= windowSamples {
            turns += try diarize(Array(pending[0..<windowSamples]), start: pendingStart)
            pending.removeFirst(windowSamples)
            pendingStart += Double(windowSamples) / Double(Self.sampleRate)
        }
        return turns
    }

    /// Diarizes whatever is buffered (end of meeting / pause). Cluster identities are kept, so
    /// later `process` calls continue with the same keys.
    public func flush() async throws -> [SpeakerTurn] {
        guard diarizer != nil else { return [] }
        if let resampler {
            pending.append(contentsOf: try resampler.finish())
        }
        let turns = try diarizePending()
        hasTimeline = false
        return turns
    }

    // MARK: - Windows

    private func diarizePending() throws -> [SpeakerTurn] {
        defer {
            pendingStart += Double(pending.count) / Double(Self.sampleRate)
            pending.removeAll(keepingCapacity: true)
        }
        guard Double(pending.count) / Double(Self.sampleRate) >= Self.minimumWindowSeconds else { return [] }
        return try diarize(pending, start: pendingStart)
    }

    private func diarize(_ window: [Float], start: TimeInterval) throws -> [SpeakerTurn] {
        guard let diarizer else { return [] }
        let result = try diarizer.performCompleteDiarization(window, sampleRate: Self.sampleRate, atTime: start)
        let windowEnd = start + Double(window.count) / Double(Self.sampleRate)
        return result.segments.compactMap { turn(for: $0, windowEnd: windowEnd) }
    }

    private func resample(_ chunk: AudioChunk) throws -> [Float] {
        if chunk.sampleRate == Double(Self.sampleRate) { return chunk.samples }
        if resampler?.inputRate != chunk.sampleRate {
            if let previous = resampler {
                pending.append(contentsOf: try previous.finish())
            }
            resampler = StreamingResampler(from: chunk.sampleRate, to: Double(Self.sampleRate))
        }
        guard let resampler else { return [] }
        return try resampler.process(chunk.samples)
    }

    // MARK: - Attribution

    private func turn(for segment: TimedSpeakerSegment, windowEnd: TimeInterval) -> SpeakerTurn? {
        let start = Double(segment.startTimeSeconds)
        let end = min(Double(segment.endTimeSeconds), windowEnd)
        guard end > start else { return nil }
        let range = TimeRange(start: start, end: end)
        let cluster = segment.speakerId

        let ranked = SpeakerMatcher.scores(for: segment.embedding, in: profiles)
        let match = SpeakerMatcher.match(ranked: ranked, threshold: config.matchThreshold, margin: config.ambiguityMargin)
        if let match, !match.isAmbiguous {
            clusterVotes[cluster, default: [:]][match.profileID, default: 0] += range.duration * match.similarity
        }

        func enrolled(_ id: UUID, similarity: Double, ambiguous: Bool) -> SpeakerTurn {
            SpeakerTurn(
                channel: channel, range: range, speakerKey: SpeakerTurn.profileKey(id), profileID: id,
                confidence: min(1, max(0, similarity)), isAmbiguous: ambiguous)
        }
        let lead = clusterLead(cluster)
        let leadSimilarity = lead.flatMap { id in ranked.first { $0.profileID == id }?.similarity }

        if let match {
            if !match.isAmbiguous {
                return enrolled(match.profileID, similarity: match.similarity, ambiguous: false)
            }
            // Ambiguous between the top two: the cluster's history breaks the tie when it names one of them.
            let contenders = ranked.prefix(2).map(\.profileID)
            if let lead, let leadSimilarity, contenders.contains(lead) {
                return enrolled(lead, similarity: leadSimilarity, ambiguous: false)
            }
            return enrolled(match.profileID, similarity: match.similarity, ambiguous: true)
        }
        if let lead, let leadSimilarity,
            leadSimilarity >= config.matchThreshold - Self.clusterThresholdRelaxation,
            ranked.first?.profileID == lead
        {
            return enrolled(lead, similarity: leadSimilarity, ambiguous: false)
        }
        return SpeakerTurn(
            channel: channel, range: range, speakerKey: unknownKey(for: cluster), profileID: nil,
            confidence: Double(min(1, max(0, segment.qualityScore))), isAmbiguous: false)
    }

    /// The profile a cluster has consistently matched, if any.
    private func clusterLead(_ cluster: String) -> UUID? {
        guard let votes = clusterVotes[cluster], let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        let total = votes.values.reduce(0, +)
        guard best.value >= Self.clusterLeadMinimumWeight, best.value >= Self.clusterLeadShare * total else { return nil }
        return best.key
    }

    private func unknownKey(for cluster: String) -> String {
        if seededSpeakerIDs.contains(cluster) {
            // A seeded enrolled cluster whose audio did not match that person: keep it stable but distinct.
            return "\(channel.keyPrefix):E\(cluster.prefix(8))"
        }
        return "\(channel.keyPrefix):S\(cluster)"
    }

    // MARK: - Seeding

    private func seedDiarizer() {
        guard let diarizer, config.seedDiarizerWithProfiles else { return }
        for id in seededSpeakerIDs {
            diarizer.speakerManager.removeSpeaker(id, keepIfPermanent: false)
        }
        let seeds: [Speaker] = profiles.compactMap { profile in
            let dimension = SpeakerManager.embeddingSize
            let usable = profile.embeddings.filter { $0.count == dimension }
            guard !usable.isEmpty else { return nil }
            var sum = [Float](repeating: 0, count: dimension)
            for embedding in usable {
                for i in 0..<dimension { sum[i] += embedding[i] }
            }
            guard let centroid = SpeakerMatcher.normalized(sum) else { return nil }
            var speaker = Speaker(
                id: profile.id.uuidString, name: profile.name, currentEmbedding: centroid, isPermanent: true)
            // Raw embeddings anchor FluidAudio's running average to the enrollment, instead of
            // letting the first live segment replace the centroid.
            speaker.rawEmbeddings = usable.map { RawEmbedding(embedding: $0) }
            return speaker
        }
        // Re-passing existing clusters keeps FluidAudio's next numeric id past the ones in use.
        let existing = diarizer.speakerManager.getSpeakerList()
        diarizer.speakerManager.initializeKnownSpeakers(existing + seeds, mode: .overwrite, preserveIfPermanent: false)
        seededSpeakerIDs = Set(seeds.map(\.id))
    }
}
