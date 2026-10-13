# Voiccenger privacy policy

_Last updated: 13 October 2026_

Voiccenger records and transcribes meetings on your Mac. It is built to keep your conversations on your device.

## What Voiccenger processes
- **Audio** from your microphone and, during online meetings, from the meeting app you're using (for example Zoom, Teams or a browser). Audio is captured only while a recording is running, or briefly analysed on-device to detect that a meeting has started.
- **Transcripts, speaker names, voice profiles** (mathematical voice signatures used to recognise enrolled people), accent and vocabulary settings, and meeting reports.

## Where it is processed
- **On your Mac.** Speech recognition (Apple Speech, Cohere Transcribe, Whisper), speaker recognition and, by default, meeting analysis (Apple Intelligence) all run on-device. Recordings, transcripts and voice profiles are stored in Voiccenger's folder on your Mac and are never uploaded by Voiccenger.
- **Model downloads.** The first time you use a speech or speaker model, Voiccenger downloads it from Hugging Face. Only the model files are requested; no audio or text is sent.
- **Optional: Claude.** If you choose Claude for meeting analysis and enter your own Anthropic API key, transcript text (not audio) is sent to Anthropic to produce insights and reports, under [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy). This is off unless you turn it on.
- **Updates.** The version downloaded from GitHub checks GitHub for updates. The Mac App Store version is updated by the App Store.

## What Voiccenger does not do
- No accounts, analytics, advertising or tracking.
- No audio, transcripts or voice profiles are sent to the developer.

## Consent
Recording laws differ by country and state. Tell participants when you record a meeting and get their consent where the law requires it. Before your first recording, Voiccenger asks you to confirm you'll tell people (you can keep this reminder on for every recording in Settings › General), and shows a red recording indicator while it records.

## Your control
Delete any meeting, recording or voice profile in the app, or remove `~/Library/Containers/com.voiccenger.app` (App Store version) or `~/Library/Application Support/Voiccenger` (GitHub version) to erase everything. Your Claude API key is stored in your macOS Keychain.

## Contact
Questions: open an issue at https://github.com/ayoinc/Voiccenger/issues.
