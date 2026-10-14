# App Store text: requirements

Paste into App Store Connect. The build is universal (Apple silicon + Intel) with `LSMinimumSystemVersion` 14.4, so the App Store itself hides it from Macs on macOS 14.3 or earlier.

## Description (requirements paragraph)

Voiccenger runs on any Mac with macOS Sonoma 14.4 or later, Apple silicon or Intel. What you get depends on your Mac:

• macOS Tahoe 26 on Apple silicon with Apple Intelligence turned on: everything — on-device voice models on the Neural Engine, instant live text with Apple Speech, and detailed meeting summaries and live insights from Apple Intelligence, all on your Mac.
• macOS 26 on Apple silicon without Apple Intelligence: the same, with summaries from Claude (your own Anthropic API key) or a transcript outline built on your Mac without AI.
• macOS 14.4 to 15 on Apple silicon: on-device voice models (Cohere Transcribe, Whisper) refine live text from Apple's built-in speech recognition, shown every couple of seconds; summaries from Claude or the transcript outline.
• Intel Macs: Apple's built-in speech recognition (less accurate than the voice models, which need Apple silicon) or Deepgram with your own key, with live text every couple of seconds; summaries from Claude or the transcript outline. Apple Intelligence needs Apple silicon.

On first launch, "What this Mac can do" lists every feature and why any is unavailable; it's always in Settings › General.

## Review notes

- Universal binary, minimum macOS 14.4. Tested tiers: macOS 26 Apple silicon (full); in CI, macOS 14 Apple silicon and macOS 15/26 Intel run `voiccenger-cli capabilities --json` and an Apple Speech transcription (plus Whisper on Apple silicon).
- Before macOS 26 and on Intel, Apple Speech is the classic recognizer (SFSpeechRecognizer); it runs on the Mac where the language supports it, otherwise on Apple's servers, which the recording consent sheet then says.
- Features that need newer hardware or software are disabled with the reason shown, never hidden silently: Apple Speech's instant live text ("Needs macOS 26"), Apple Intelligence ("Needs macOS 26", "Needs Apple silicon" or "Turn on Apple Intelligence in System Settings").
- Voice models (Cohere Transcribe 2.2 GB, Whisper Large v3 Turbo 1.7 GB) are downloaded from Hugging Face on first use; audio stays on the Mac. Claude and Deepgram are optional and need the user's own API keys; with Deepgram selected, meeting audio is sent to Deepgram, and with Claude, transcript text is sent to Anthropic.
- To review without keys or downloads: Settings › General › What This Mac Can Do; start a recording from the Live tab (the first recording asks the user to confirm participants are told).
