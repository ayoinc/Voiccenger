![Voiccenger](docs/banner.png)

# Voiccenger

Meeting transcriber for macOS 14.4 or later, on Apple silicon and Intel Macs. Detects meetings, records, transcribes live with accent-robust voice models, identifies who is speaking (enrolled voices, including similar ones), estimates seat direction with a mic array, lets each person tune recognition to their accent, flags speech slips with proposed corrections and suggestions, and writes a post-meeting report.

## Install
Download the latest `Voiccenger-x.y.z.dmg` from [Releases](https://github.com/ayoinc/Voiccenger/releases/latest), open it and drag Voiccenger to Applications. Builds are signed with Developer ID and notarized by Apple. Installed copies update themselves (**Voiccenger › Check for Updates…**, or automatically from Settings › General › Updates).

## Requirements
One universal app (Apple silicon + Intel) for macOS 14.4 or later. Features switch on according to what each Mac supports; the first launch shows **What this Mac can do** (also in Settings › General), and `voiccenger-cli capabilities [--json]` prints the same.

| Your Mac | What you get |
|---|---|
| macOS 26, Apple silicon, Apple Intelligence on | Everything: Cohere/Whisper on the Neural Engine, Apple Speech's instant live text, Apple Intelligence summaries and live insights on this Mac |
| macOS 26, Apple silicon, Apple Intelligence off or unsupported | As above, but reports and insights come from Claude (your Anthropic key) or the transcript outline (no AI) |
| macOS 14.4 – 15, Apple silicon | Cohere (default) or Whisper; live text from Apple Speech (classic) every couple of seconds, then refined by the voice model (instant live text needs macOS 26); reports from Claude or the transcript outline |
| Intel Mac, macOS 14.4 or later | Apple Speech (classic), built in, or Deepgram with your key; Cohere and Whisper need Apple silicon. On the 48 s fixture meeting the classic recognizer made 15.1% word errors as an x86_64 build under Rosetta (3.4% native on Apple silicon; macOS 26 Apple Speech 2.5%). Live text every couple of seconds; reports from Claude or the transcript outline (Apple Intelligence needs Apple silicon) |
| macOS 14.3 or earlier | Can't be installed: macOS refuses to open the app (`LSMinimumSystemVersion` 14.4) |

Deepgram Nova-3 (cloud, your key), speaker identification, meeting detection, meeting-app audio capture and seat direction work on every supported Mac.

- Building: Swift 6.2+ (Command Line Tools are enough; Xcode not required). `scripts/bundle.sh` builds arm64 and x86_64 separately and joins them with `lipo`.
- Optional: Anthropic API key (Claude engine), Deepgram API key (cloud voice model), USB mic array (ReSpeaker 4/6-mic, miniDSP UMA-8) for seat direction.
- Disk: Cohere Transcribe 2.2 GB and/or Whisper Large v3 Turbo 1.7 GB, downloaded on first use.

## Voice models and accents
Apple's recogniser has a single English acoustic model: the en-US, en-GB and en-ZA locales gave byte-identical transcripts on every test speaker, and there is no Nigerian, Ghanaian or Kenyan English locale. So, like [Superwhisper](https://superwhisper.com/docs/models/voice), Voiccenger runs dedicated speech models on-device and lets you pick one (Settings › Voice Models):

| Voice model | Role | Size | Languages |
|---|---|---|---|
| Cohere Transcribe (FluidAudio, Neural Engine) | Default: most accurate on accented English | 2.2 GB | 14 |
| Whisper Large v3 Turbo (WhisperKit) | Alternative; languages Cohere lacks (Swahili, Yoruba, Hausa, Amharic, Somali, Afrikaans…) | 1.7 GB | 99 |
| Apple Speech | Instant grey preview while someone talks; fallback while a model downloads | built in | per locale |
| Deepgram Nova-3 (cloud, optional) | Fastest live text, streamed like [Granola](https://granola.ai); less accurate on African accents than Cohere/Whisper, better than Apple. **Sends audio to Deepgram**; needs your own API key | none | 63 + `multi` |

Live, Apple shows words instantly; each finished stretch of speech is re-transcribed by the selected model and replaces the preview. With Deepgram selected, each channel instead streams 16 kHz audio over one WebSocket to Deepgram (`nova-3` or the chosen model, interim results, smart formatting, enrolled names as keyterms, `mip_opt_out=true`): interim results are the grey preview and Deepgram's finals, with its word timings, are the lines. A dropped connection reconnects and resends the audio Deepgram hadn't finalised; if the key is missing or rejected, or Deepgram can't be reached within 5 s, that channel falls back to the on-device path and the live chip says so.

**Deepgram key.** Settings › Voice Models › Deepgram stores the key in the Keychain (service `com.voiccenger.app`, account `deepgram-api-key`) and checks it with Deepgram (`GET /v1/projects`, once per launch). The direct-download app and `voiccenger-cli` also read `DEEPGRAM_API_KEY`, then `~/.deepgram_secret`; the sandboxed App Store build uses the Keychain or the environment only. The key is sent only in the `Authorization` header to Deepgram, never logged. `voiccenger-cli transcribe file.wav --engine deepgram` and `process file.wav --engine deepgram` use it too; `models` shows whether it works. Calibration includes Deepgram once its key is valid.

**Deepgram models.** Once the key is accepted, Voiccenger asks Deepgram which speech-to-text models it can use (`GET /v1/projects` → `GET /v1/projects/{id}/models`, or the public `GET /v1/models` when the key can't read its project) and lists them in Settings › Voice Models › Deepgram Model, grouped by family (Nova-3, Nova-2, Nova, Enhanced, Whisper, Base) with their version, languages and whether each streams live or only transcribes recordings; Refresh fetches the list again. The chosen model (default `nova-3`) streams meetings and transcribes files; each person can have their own in Voice & Accent, limited to models that transcribe their language, and their lines are re-transcribed with it. Calibration scores the chosen model plus up to two more you tick, and the best one becomes that person's Deepgram model unless you picked another. A model that can't stream the meeting's language (or doesn't transcribe it, or that Deepgram refuses) is replaced by Nova-3, and the meeting or file says why. CLI: `voiccenger-cli models deepgram [--language en] [--refresh]`, and `--deepgram-model name` on `transcribe`, `process` and `calibrate` (comma-separated, up to three, to compare).

**Benchmark.** 89 speakers from the [Speech Accent Archive](https://accent.gmu.edu/) (54 African: Yoruba, Igbo, Hausa, Ewe, Ga, Fante, Twi, Krio, Mende, Wolof, Bambara, Swahili, Luganda, Luo, Kikuyu, Somali, Oromo, Amharic, Tigrinya, Shona, Sesotho, Zulu, Tswana, Afrikaans, Lingala…) reading the same paragraph. Word error rate, lower is better:

| Speakers | Apple | Parakeet v3 | Deepgram Nova-3 | Voiccenger + Whisper | Voiccenger + Cohere |
|---|---|---|---|---|---|
| All 89 | 10.2% | 9.1% | 7.4% | 5.7% | **5.1%** |
| African (54) | 10.1% | 8.0% | 7.2% | 5.1% | **4.3%** |
| West African (34) | 9.5% | 6.5% | 6.1% | 4.9% | **3.4%** |
| East/Southern African (20) | 11.1% | 10.5% | 9.3% | **5.5%** | 5.7% |
| Native English (8) | 1.3% | 1.1% | 0.7% | **0.5%** | 0.9% |

"Voiccenger +" columns are measured through the app's own transcription path (`voiccenger-cli transcribe --engine …`). Running the models on whole clips does slightly better (Cohere 4.5% / 3.9% African; Whisper 5.1% / 4.1%), since the app splits audio at pauses. Deepgram was measured through its pre-recorded API with `language=en` (`language=multi` is worse: 8.7% African), so Voiccenger sends the meeting's or person's language.

Parakeet v3 drifted out of English for accented speakers (Dutch words, Greek script), so it isn't offered. No single model wins for everyone, which is why each person can calibrate.

**Make it yours** (People › person › Voice & Accent):
- **Calibrate**: read the Speech Accent Archive paragraph plus a sentence with your own name and a place you know. Every downloaded model transcribes it; the one with the fewest errors becomes yours, and mis-hearings become suggested corrections.
- **Accent background** and **lives in**: e.g. Nigeria and the United Kingdom. Every African country is listed; regional names, cities, institutions and currency (e.g. Olúwaseun, Ikeja, GTBank, naira) are added to the vocabulary.
- **Language** (any your model supports), **spelling** (British/American), **vocabulary** and **replacements** ("heard → meant").
- In meetings, each recognised person's turns are re-transcribed with their model and customised with their settings.

## Build, test, run
```sh
swift scripts/MakeFixtures.swift          # synthetic test audio → .fixtures/
scripts/test.sh                           # all suites (adds swift-testing plugin path for CLT)
VOICCENGER_INTEGRATION=1 scripts/test.sh --filter VCPipelineTests.FixturePipelineTests   # end-to-end
scripts/bundle.sh && open dist/Voiccenger.app
```
First run downloads FluidAudio speaker models from Hugging Face and may download Speech locale assets.

CLI (`swift run voiccenger-cli --help`): `devices`, `detect [--watch]`, `enroll <name> <wav> [--accent ng] [--lives gb] [--engine whisper] [--standard|--text file]`, `profiles`, `models [download|delete <engine>]`, `transcribe <file> [--engine cohere|whisper|apple] [--language en]`, `calibrate <wav> [--standard|--text file|--name N --region ng]`, `process <file> [--engine cohere] [--intelligence apple|claude|outline] [--spelling british] [--truth json] [--out report.md]`, `report <transcript.json> [--intelligence apple|claude|outline] [--title text] [--out report.md]` (report for a transcript of `{"speaker", "start", "end", "text"}` lines, timed), `doa`, `system-audio`.

## Releasing
Every push and pull request runs **CI** (`.github/workflows/ci.yml`): build, tests, and an unsigned DMG artifact.

Releases are cut with the **Release** workflow (`.github/workflows/release.yml`): Actions › Release › Run workflow, pick `patch`/`minor`/`major` (or type an exact version), optionally mark it a pre-release. Same from the terminal:
```sh
gh workflow run release.yml -f bump=minor
```
Pushing a `vX.Y.Z` tag releases that version too. The workflow:
1. picks the version (latest `v*` tag + bump) and build number (commit count, always increasing);
2. runs the tests;
3. builds the app with the version stamped into Info.plist, signs it with Developer ID (hardened runtime);
4. builds the drag-to-install DMG, notarizes and staples it;
5. signs the DMG for Sparkle (EdDSA) and writes `appcast.xml`;
6. tags the commit and publishes a GitHub Release with the DMG, its SHA-256 and the appcast;
7. **App Store** (non-pre-releases): builds the same version sandboxed and without Sparkle (`--disable-default-traits`), signs it with Apple Distribution, packages it with `productbuild` and uploads it to App Store Connect, where it appears in TestFlight. Submitting for review is done in App Store Connect.

The App Store variant differs only in: no Sparkle (the `Sparkle` package trait is off), App Sandbox entitlements (`Resources/Voiccenger-MAS.entitlements`: microphone, network client, user-selected files), an embedded provisioning profile, and a compiled asset-catalog icon (`Resources/Assets.xcassets`, needs Xcode's `actool`). Core Audio process taps and meeting detection work inside the sandbox. Data lives in `~/Library/Containers/com.voiccenger.app`.

Installed apps read `releases/latest/download/appcast.xml`, so only the newest non-pre-release is offered as an update.

Repository secrets:

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_TEAM_ID` | Developer ID Application certificate (base64 .p12) |
| `NOTARY_API_KEY_P8`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | App Store Connect API key for `notarytool` |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle update-signing key; the public half is `SUPublicEDKey` in `Resources/Info.plist` |
| `MAS_APP_CERTIFICATE_P12`, `MAS_APP_CERTIFICATE_PASSWORD` | Apple Distribution certificate (App Store app signing) |
| `MAS_INSTALLER_CERTIFICATE_P12`, `MAS_INSTALLER_CERTIFICATE_PASSWORD` | Mac Installer Distribution certificate (signs the upload package) |
| `MAS_PROVISIONING_PROFILE`, `MAS_APP_APPLE_ID` | "Voiccenger Mac App Store" provisioning profile (base64); App Store Connect app ID 6822325105 |

Without the certificate/notary secrets the workflow still releases, ad-hoc signed. Losing the Sparkle private key means installed copies can no longer verify updates; a backup lives in the maintainer's login Keychain (`generate_keys --account voiccenger -x <file>` exports it).

Local equivalent of the pipeline:
```sh
# Pick the Developer ID identity by SHA-1 (`security find-identity -v -p codesigning`); names can be ambiguous.
export SIGN_IDENTITY=CE6B8B4871E09778C148588B5718F827ABAD63A0 VERSION=1.2.0
scripts/bundle.sh && scripts/make-dmg.sh dist/Voiccenger.app dist/Voiccenger-$VERSION.dmg
NOTARY_KEYCHAIN_PROFILE=voiccenger-notary scripts/notarize.sh dist/Voiccenger-$VERSION.dmg
```

## How it works
| Capability | Implementation |
|---|---|
| Online meeting detection | Core Audio process list: a known conferencing app/browser using the mic for ≥2 s starts, ≥5 s absent ends (`VCAudio.MeetingDetector`) |
| In-person detection | Energy VAD, ~30 s speech in 60 s (`ConversationDetector`), opt-in |
| Capture | Mic via AVAudioEngine; the computer's audio via Core Audio process taps (the meeting app's whole process family, else everything the Mac plays) — separate channels, in every meeting; see [Capturing every party](#capturing-every-party) |
| Transcription | Apple `SpeechAnalyzer` streams a preview; utterances (joined across pauses < 3 s, ≤ 30 s) are re-transcribed by Cohere Transcribe or Whisper; Apple's word timings are transferred to the final text. Or Deepgram Nova-3 streams over a WebSocket per channel, with its word times mapped back to the session clock across gaps and reconnects |
| Language/accent | Per-person calibration picks the best model; accent region seeds vocabulary; language switching (e.g. English ↔ French) on low confidence |
| Speakers | FluidAudio diarization + WeSpeaker embeddings; enrolled people matched by cosine with multi-sample profiles, ambiguity margin and per-cluster voting |
| Seat direction | GCC-PHAT steered response power over all mic pairs, per-speaker circular mean |
| Intent, corrections, suggestions | Apple Foundation Models (default) or Claude, per utterance. A correction is shown only as a self-correction, a contradiction of an earlier line or a likely mishearing, checked against the words spoken; filler or repetition clean-ups are never corrections |
| Report | A detailed overview (paragraphs for meetings with substance), topic summaries (who said what, numbers, outcomes), decisions, action items (owner/due), notes, things that could have been said, open questions, corrections, per-person points, and a **conversation outline**: the whole meeting in order as segments (`[mm:ss–mm:ss]`, heading, points each attributed to a speaker, with timestamps that jump to the transcript in the app); Markdown export with the voice model used. Every item and outline point cites numbered transcript lines and is kept only when those lines support it (shared content words, a commitment/request/decision/question cue, the owner as the committer or the person asked, outline points only from the speaker's own lines); promises are never reported as done; only people with transcript lines appear; meetings with little substance get a brief report. Every substantive line must lie within two lines of a cited one: stretches the model skipped are filled with the speakers' most informative sentences, quoted, inside the surrounding segment (a segment of their own only from six substantive lines). Segments with fewer than three substantive lines, or only quotes, then merge into the neighbour sharing more words, and neighbours merge (most shared words, penalised by size) down to about one segment per three minutes, at most 12. Apple Intelligence (4,096-token window) writes the summary, the lists and the outline in separate requests sized with exact token counts; long meetings are outlined chunk by chunk with every chunk's outline kept as written, and only summary and lists are merged. Without Apple Intelligence or a Claude key, the **Transcript outline (no AI)** splits the transcript at pauses, transition phrases and changes of vocabulary, merges segments the same way and quotes each speaker's most informative sentences (2–6 per segment), with questions asked and *possible* action items found by phrases like “I'll” and “can you”, labelled as not written by AI |

Data: `~/Library/Application Support/Voiccenger/`. Claude and Deepgram keys stored in the Keychain.

## Capturing every party
Every recording has two channels: the **microphone** (you and anyone in the room) and the **computer's audio** (whatever the Mac plays: the other side of a call). In-person recordings capture the computer's audio too (Settings › Audio › *Record computer audio during in-person meetings*, on by default): with headphones on, a call's remote party never reaches the microphone, so a call recorded as an in-person meeting would otherwise lose them.

- **Which audio.** For a native meeting app (Zoom, Teams, Webex, FaceTime, Slack…) the tap covers the app's whole process family: every process whose bundle ID belongs to the app, helpers and companion daemons included, not only the one holding the microphone. Core Audio's process list and each process's output state are watched; when a new family process starts playing, the tap is rebuilt and the timeline continues (the moment of the switch is silence, so the recording stays in sync). For a browser, or with no meeting app, the tap records everything the Mac plays except Voiccenger. If the app's processes stay silent while other audio on the Mac carries speech for over 10 s, Voiccenger switches to all computer audio and says why.
- **Calls that start mid-recording.** When a meeting app starts using the microphone during an in-person recording, the meeting becomes an online meeting in that app and the computer-audio channel narrows to its processes, without restarting the recording.
- **Levels.** Computer audio is normalised before transcription and speaker identification (a slow automatic gain control with a limiter, aiming at about −20 dBFS speech); the recording keeps the raw audio. Voice detection still finds speech at −41 dBFS.
- **Speakers instead of headphones.** The microphone then hears the remote party too, so their words would appear twice. A microphone line is dropped when computer-audio lines cover more than half of its time and contain at least 60% of its words in order; someone in the room talking over the call says different words and is kept. (On the two Teams meetings recorded on the development Mac, 118 of the 144 mic lines that system lines overlapped passed that test; of 320 pairs of different speech, 3 did.) Times when the computer's audio carries speech are also left out when matching microphone voices to enrolled people and when collecting a voice to enroll.
- **Warnings.** The Live view shows, and the meeting keeps, a warning when a meeting app is active but its audio has been silent for more than 20 s, when the microphone sends only digital silence, or when macOS has muted the input or set its volume to 0.

Measured on an M-series Mac with macOS 26 (global process tap, `voiccenger-cli system-audio`):

| Condition | Computer-audio capture |
|---|---|
| Normal volume, built-in speakers | RMS −19.1 dBFS, peak −1.3 dBFS |
| Mac output volume 0 | identical (−19.1 / −1.3) |
| Mac output muted | identical (−19.1 / −1.3) |
| Default output switched mid-capture (as when headphones connect) | capture continued, no gap |
| Started while the output was an LG monitor over HDMI | captured, about 20 dB quieter (RMS −41, peak −20); normalised to about −20 dBFS for transcription |

Taps capture what apps play before the Mac's volume and mute, whatever the output device, so headphones, volume 0 and mute don't stop the recording.

End to end: an in-person `MeetingSession` (Cohere) recording while `say -v Daniel` spoke two sentences with the Mac's output volume at 0 transcribed both, word for word but one ("in" for "and"), as computer-audio lines; `system.wav` held them at −19.2 dBFS RMS. `voiccenger-cli record --seconds N [--kind in-person] [--out report.md]` runs the same check.

**What can't be captured.** If the meeting app itself plays silence (its own speaker volume at 0, "mute incoming audio", or it routes nothing), there is no audio to record. Voiccenger warns "*App* is playing no sound…": turn up the app's own speaker volume (the Mac's volume can stay at 0). Where that isn't possible, use the platform's own captions or transcripts (Zoom, Microsoft Teams and Google Meet each offer them).

**Muted in the meeting app.** Voiccenger reads the microphone device directly, so muting yourself in Zoom, Teams or Meet doesn't stop it: it still records and transcribes your voice while you're muted on the call. Only macOS input mute or volume 0 (or a hardware mute switch) silences it, and Voiccenger warns when that happens. Keep this in mind for side conversations while muted; the recording reminder covers telling people they're being recorded, and you can stop the recording at any time.

## Measured
- Accented English (89 real speakers, see above): 5.1% word error rate with Cohere Transcribe vs 10.2% with Apple; 4.3% vs 10.1% for African speakers.
- Speaker attribution, 4 enrolled synthetic voices, 10-turn meeting: 10/10.
- Cohere warm-up ~11 s per launch on the Neural Engine (0.3 GB memory); Whisper ~1 s.
- Deepgram on the 48 s fixture meeting streamed in real time: first interim 0.6 s after speech starts, finals ~0.5 s after most turns end, 0.8% WER; 10/10 speaker turns with enrolled voices.
- Deepgram models on the same fixture as a file (pre-recorded API, `language=en`): Nova-3 0.0% WER, Nova-2 Meeting 0.0%. A test key that can't read its project's models got Deepgram's public list: 39 speech-to-text models.
- DOA error at 20 dB SNR: ≤1° on presets.
- Reports with Apple Intelligence on an M-series Mac (CLI `report`): 1-minute regression meeting 13 s (stays brief: one overview sentence, one outline point); 10-line fixture 27 s; 40-line meeting 40–100 s (summary, lists and outline requests in parallel); 252-line, 26-minute meeting 4.5–5.5 min (5 parts × 2 notes requests, 6 outline chunks, 2 summary merges; 16 grounded action items). Transcript outline (no AI): 0.1–0.4 s.

## Limitations
- Cohere Transcribe supports 14 languages; for others (most African languages) choose Whisper, whose accuracy on them is lower than on English.
- Very short fragments re-transcribed in isolation can come back empty; the preview text is kept.
- Cohere occasionally completes a very familiar text from memory (seen on the benchmark paragraph); window boundaries are de-duplicated.
- Unenrolled similar voices can merge at the default clustering threshold (0.7); enroll people for reliable naming.
- Speaker labels lag ~10 s behind live text (diarization windows).
- Seat direction needs a multi-channel array; the built-in Mac mic can't localize.
- Deepgram streams at about real time, so `process --engine deepgram` takes roughly as long as the recording. New names enrolled mid-meeting reach Deepgram's keyterms on its next connection.
- If system-audio permission is denied the tap yields silence, not an error; with a meeting app active, the Live view then warns that the app is playing no sound.
- Report grounding is lexical: an item that shares words with its cited lines and has the right cue can still misread them. Overview and topic sentences are only checked, clause by clause, for promises reported as done ("agreed on a budget freeze" for a feature freeze survives there).
- The on-device model mostly copies transcript lines into the outline instead of paraphrasing; copies are shown as quotes. For long meetings the parts' lists are joined without a model, so a decision superseded later in the meeting, or a question answered in a later part, can still appear.
- With CLT only, SwiftUI's `@State` macro is unavailable; views use a `ViewState = SwiftUI.State` alias.

## Artwork
Icon and banner are rendered in code: `swift scripts/MakeArtwork.swift` regenerates `Resources/AppIcon.icns`, the App Store icon catalog `Resources/Assets.xcassets`, the DMG background, `docs/icon.png` and `docs/banner.png`. The mark is a meeting table seen from above: waveform bars form the ring of seats, each speaker has a colour, and the beam points at whoever is talking.

## Privacy
See [PRIVACY.md](PRIVACY.md). Everything runs on-device except model downloads and the optional Claude and Deepgram services.

## License
MIT — see [LICENSE](LICENSE). Uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).
