![Voiccenger](docs/banner.png)

# Voiccenger

macOS 26 meeting transcriber. Detects meetings, records, transcribes live, identifies who is speaking (enrolled voices, including similar ones), estimates seat direction with a mic array, detects language/accent, flags speech slips with proposed corrections and suggestions, and writes a post-meeting report.

## Install
Download the latest `Voiccenger-x.y.z.dmg` from [Releases](https://github.com/ayoinc/Voiccenger/releases/latest), open it and drag Voiccenger to Applications. Builds are signed with Developer ID and notarized by Apple. Installed copies update themselves (**Voiccenger › Check for Updates…**, or automatically from Settings › General › Updates).

## Requirements
- macOS 26 on Apple silicon, Apple Intelligence enabled (on-device engine).
- Swift 6.2+ (Command Line Tools are enough; Xcode not required).
- Optional: Anthropic API key (Claude engine), USB mic array (ReSpeaker 4/6-mic, miniDSP UMA-8) for seat direction.

## Build, test, run
```sh
swift scripts/MakeFixtures.swift          # synthetic test audio → .fixtures/
scripts/test.sh                           # all suites (adds swift-testing plugin path for CLT)
VOICCENGER_INTEGRATION=1 scripts/test.sh --filter VCPipelineTests.FixturePipelineTests   # end-to-end
scripts/bundle.sh && open dist/Voiccenger.app
```
First run downloads FluidAudio speaker models from Hugging Face and may download Speech locale assets.

CLI (`swift run voiccenger-cli --help`): `devices`, `detect [--watch]`, `enroll`, `profiles`, `transcribe`, `accent`, `process <file> [--truth json] [--out report.md]`, `doa`, `system-audio`.

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
6. tags the commit and publishes a GitHub Release with the DMG, its SHA-256 and the appcast.

Installed apps read `releases/latest/download/appcast.xml`, so only the newest non-pre-release is offered as an update.

Repository secrets:

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_TEAM_ID` | Developer ID Application certificate (base64 .p12) |
| `NOTARY_API_KEY_P8`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | App Store Connect API key for `notarytool` |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle update-signing key; the public half is `SUPublicEDKey` in `Resources/Info.plist` |

Without the certificate/notary secrets the workflow still releases, ad-hoc signed. Losing the Sparkle private key means installed copies can no longer verify updates; a backup lives in the maintainer's login Keychain (`generate_keys --account voiccenger -x <file>` exports it).

Local equivalent of the pipeline:
```sh
export SIGN_IDENTITY="Developer ID Application: Ayodele Ajayi (T8242XY72S)" VERSION=1.2.0
scripts/bundle.sh && scripts/make-dmg.sh dist/Voiccenger.app dist/Voiccenger-$VERSION.dmg
NOTARY_KEYCHAIN_PROFILE=voiccenger-notary scripts/notarize.sh dist/Voiccenger-$VERSION.dmg
```

## How it works
| Capability | Implementation |
|---|---|
| Online meeting detection | Core Audio process list: a known conferencing app/browser using the mic for ≥2 s starts, ≥5 s absent ends (`VCAudio.MeetingDetector`) |
| In-person detection | Energy VAD, ~30 s speech in 60 s (`ConversationDetector`), opt-in |
| Capture | Mic via AVAudioEngine; remote voices via Core Audio process tap on the meeting app — separate channels |
| Transcription | `SpeechAnalyzer` + `SpeechTranscriber`, volatile + final results, word timings and confidence |
| Language/accent | Re-scores recent audio across installed locales when confidence drops; switches recognizer |
| Speakers | FluidAudio diarization + WeSpeaker embeddings; enrolled people matched by cosine with multi-sample profiles, ambiguity margin and per-cluster voting |
| Seat direction | GCC-PHAT steered response power over all mic pairs, per-speaker circular mean |
| Intent, corrections, suggestions | Apple Foundation Models (default) or Claude, per utterance |
| Report | Topics, decisions, action items (owner/due), notes, things that could have been said, open questions, corrections, per-person points; Markdown export |

Data: `~/Library/Application Support/Voiccenger/`. Claude key stored in the Keychain.

## Measured (synthetic `say` voices — not real recordings)
- Speaker attribution, 4 enrolled voices, 10-turn meeting: 10/10.
- Transcription word error rate: 3.3%. French auto-detected and switched in ~1.7 s.
- DOA error at 20 dB SNR: ≤1° on presets.

## Limitations
- Accent ranking within one language is weak (scores ~0.01 apart); automatic switching reliably catches language changes, not accents.
- Unenrolled similar voices can merge at the default clustering threshold (0.7); enroll people for reliable naming.
- Speaker labels lag ~10 s behind live text (diarization windows).
- Seat direction needs a multi-channel array; the built-in Mac mic can't localize.
- If system-audio permission is denied the tap yields silence, not an error.
- With CLT only, SwiftUI's `@State` macro is unavailable; views use a `ViewState = SwiftUI.State` alias.

## Artwork
Icon and banner are rendered in code: `swift scripts/MakeArtwork.swift` regenerates `Resources/AppIcon.icns`, `docs/icon.png` and `docs/banner.png`. The mark is a meeting table seen from above: waveform bars form the ring of seats, each speaker has a colour, and the beam points at whoever is talking.

## License
MIT — see [LICENSE](LICENSE). Uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).
