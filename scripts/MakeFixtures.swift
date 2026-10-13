// Generates synthetic test audio with macOS `say` voices.
// Usage: swift scripts/MakeFixtures.swift [outputDir]   (default: .fixtures)
//
// Output (16 kHz mono Float32 WAV):
//   enroll_<Name>.wav   ~15 s reading passage per voice (enrollment + accent detection)
//   meeting.wav         scripted multi-speaker meeting with slips, decisions and action items
//   meeting.truth.json  ground truth: [{speaker, voice, locale, start, end, text}]
//   french.wav          French speech (language-switch detection)
import AVFoundation
import Foundation

struct Voice {
    let name: String
    let voice: String
    let locale: String
}

let voices = [
    Voice(name: "Daniel", voice: "Daniel", locale: "en-GB"),
    Voice(name: "Samantha", voice: "Samantha", locale: "en-US"),
    Voice(name: "Rishi", voice: "Rishi", locale: "en-IN"),
    Voice(name: "Karen", voice: "Karen", locale: "en-AU"),
]

let passage = """
    When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. \
    The rainbow is a division of white light into many beautiful colours. These take the shape \
    of a long round arch, with its path high above, and its two ends apparently beyond the horizon. \
    There is, according to legend, a boiling pot of gold at one end.
    """

let script: [(String, String)] = [
    ("Daniel", "Good morning everyone. Let's get started with the quarterly planning review."),
    ("Samantha", "Thanks Daniel. The main item today is the launch date for the mobile app."),
    ("Rishi", "Engineering is on track. We finished the payment integration last week."),
    ("Karen", "Marketing needs at least three weeks of notice before any launch."),
    ("Daniel", "So let's target the launch for Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth."),
    ("Samantha", "Wednesday works. I propose we freeze features by the end of this month."),
    ("Rishi", "Agreed. I will send the updated budget to everyone by Friday."),
    ("Karen", "Samantha, can you share the press kit with my team before the freeze?"),
    ("Samantha", "Yes, I will share the press kit on Monday."),
    ("Daniel", "Great. Decision made, we launch on Wednesday the fifteenth. Thanks all."),
]

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".fixtures")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

func synthesize(_ text: String, voice: String) throws -> [Float] {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", tmp.path, text]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "say", code: Int(p.terminationStatus)) }
    let file = try AVAudioFile(forReading: tmp)
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let ratio = target.sampleRate / file.processingFormat.sampleRate
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)!
    var fed = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        if fed {
            status.pointee = .endOfStream
            return nil
        }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let err { throw err }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func write(_ samples: [Float], to name: String) throws {
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: target.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buf)
    print("wrote \(url.path) (\(String(format: "%.1f", Double(samples.count) / 16_000)) s)")
}

for v in voices {
    try write(try synthesize(passage, voice: v.voice), to: "enroll_\(v.name).wav")
}

struct Truth: Codable {
    let speaker: String
    let voice: String
    let locale: String
    let start: Double
    let end: Double
    let text: String
}

var meeting = [Float](repeating: 0, count: 8_000)
var truth: [Truth] = []
for (speaker, line) in script {
    let v = voices.first { $0.name == speaker }!
    let s = try synthesize(line, voice: v.voice)
    let start = Double(meeting.count) / 16_000
    meeting += s
    truth.append(Truth(speaker: speaker, voice: v.voice, locale: v.locale, start: start, end: Double(meeting.count) / 16_000, text: line))
    meeting += [Float](repeating: 0, count: 9_600)  // 0.6 s turn gap
}
try write(meeting, to: "meeting.wav")
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(truth).write(to: outDir.appendingPathComponent("meeting.truth.json"))

try write(
    try synthesize(
        "Bonjour à tous. Nous allons parler du budget de l'année prochaine et des priorités de l'équipe. Je pense que nous devons recruter deux ingénieurs avant l'été.",
        voice: "Thomas"), to: "french.wav")
