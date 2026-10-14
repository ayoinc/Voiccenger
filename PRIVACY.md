# Voiccenger privacy policy

_Last updated: 14 October 2026_

Voiccenger records and transcribes meetings on your Mac. It is built to keep your conversations on your device; the only exceptions are the optional cloud services below, which you turn on with your own API keys.

## What Voiccenger processes
- **Audio** from your microphone and from your Mac's own sound output: during online meetings, the meeting app you're using (for example Zoom, Teams or a browser); during in-person recordings, everything your Mac plays (you can turn this off in Settings › Audio). The microphone is recorded even while you're muted inside the meeting app, because Voiccenger reads the microphone directly. Audio is captured only while a recording is running, or briefly analysed on-device to detect that a meeting has started.
- **Transcripts, speaker names, voice profiles** (mathematical voice signatures used to recognise enrolled people), accent and vocabulary settings, and meeting reports.

## Where it is processed
- **On your Mac.** Speech recognition (Apple Speech, Cohere Transcribe, Whisper), speaker recognition and, by default, meeting analysis (Apple Intelligence) all run on-device. Recordings, transcripts and voice profiles are stored in Voiccenger's folder on your Mac and are never uploaded by Voiccenger, except to the optional services below.
- **Model downloads.** The first time you use a speech or speaker model, Voiccenger downloads it from Hugging Face. Only the model files are requested; no audio or text is sent.
- **Optional: Deepgram.** If you enter your own Deepgram API key, audio is sent to Deepgram for transcription: streamed live while you record when Deepgram Nova-3 is the meeting's voice model; uploaded for lines of people whose voice model is Deepgram, for files you transcribe with it, and for calibration readings (to compare it with the on-device models). Requests carry Deepgram's `mip_opt_out=true` option, so Deepgram doesn't use your audio for model training (its Model Improvement Program). Deepgram handles the audio under [Deepgram's privacy policy](https://deepgram.com/privacy). Recordings and transcripts are still saved only on your Mac. Without a key nothing is sent; Voiccenger's recording reminder says when audio will be sent to Deepgram.
- **Optional: Claude.** If you choose Claude for meeting analysis and enter your own Anthropic API key, transcript text (not audio) is sent to Anthropic to produce insights and reports, under [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy). With a key entered, Claude also writes a meeting's report when Apple Intelligence can't (it is unavailable, or its safety filter declines the whole meeting); the report says so. This is off unless you turn it on: without a key nothing is sent.
- **Updates.** The version downloaded from GitHub checks GitHub for updates. The Mac App Store version is updated by the App Store.

## What Voiccenger does not do
- No accounts, analytics, advertising or tracking.
- No audio, transcripts or voice profiles are sent to the developer.

## Consent
Recording laws differ by country and state. Tell participants when you record a meeting and get their consent where the law requires it. Before your first recording, Voiccenger asks you to confirm you'll tell people (you can keep this reminder on for every recording in Settings › General), and shows a red recording indicator while it records.

## Your control
Delete any meeting, recording or voice profile in the app, or remove `~/Library/Containers/com.voiccenger.app` (App Store version) or `~/Library/Application Support/Voiccenger` (GitHub version) to erase everything. Your Claude and Deepgram API keys are stored in your macOS Keychain; remove them in Settings › Intelligence and Settings › Voice Models.

## Contact
Questions: open an issue at https://github.com/ayoinc/Voiccenger/issues.
