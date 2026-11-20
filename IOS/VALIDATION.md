# iOS validation

## Portable checks

`python3 Scripts/check-ios-project.py` checks the project object graph, source inventory, resources, Info.plist, shared scheme, icon, bundled Pitchy license, and deterministic regeneration. It verifies that the iOS generator leaves Watch build files alone. If Swift 6 is available, the script also parses iOS Swift syntax and runs standalone tone-input and audio-lifetime checks. Tone-input cases cover locales and frequency bounds. Audio-lifetime scenarios use offline spy closures to detect access to invalidated audio objects during shutdown.

`python3 Scripts/check-portable-core.py` runs applicable shared-core tests using a test-only scalar dot-product shim on Linux. It excludes the AVFAudio-dependent `ProductionPipelineTests.swift`. The new integration tests generate synthetic PCM to cover profiles, sample rates, tap sizes, and resets between sessions. The activity tests exercise cancelled permission requests and shutdown ordering.

## Xcode and device checks

- Build and run the shared iOS scheme with Xcode. Verify icon appearance, portrait and landscape layouts, large Dynamic Type, and VoiceOver.
- Exercise microphone permission, foreground inactivity, app backgrounding, rapid start/stop, interruptions, media-services reset, and route changes.
- Check pitch accuracy, audio and visual metronome timing, playback frequency and audibility, latency, and battery and thermal behavior on representative devices.

The portable checks do not typecheck Apple APIs or exercise an Apple audio engine, microphone, speaker, or accelerator.
