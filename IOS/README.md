# Watch Tuner for iOS

A native SwiftUI iPhone and iPad app for iOS 18 or later. Open `WatchTunerIOS.xcodeproj` and select the shared **WatchTunerIOS** scheme.

## Use

- **Tuner:** tap **Listen**, allow microphone access, and play one isolated voice/string/key. Shows detected Hz, nearest equal-tempered note, reference Hz and −50…+50 cents. Settings selects persisted Vocals (default), Piano or Guitar. Concert reference remains fixed at A4 = 440 Hz. Uncertain/silent/clipped input has explicit feedback and clears the note; the app never displays demo readings as live measurements.
- **Tone:** enter 20–8,000 Hz, use the logarithmic slider, 1 Hz stepper or presets, then tap **Play tone**. A route unable to represent the requested frequency is refused without changing the selected Hz. Speaker/headphone response is not a calibrated acoustic range.
- **Metronome:** set 30–240 BPM, 1–8 beats per bar and optional first-beat accent. Tap **Start metronome**. The shared oscillator schedules clicks per audio sample; the visual indicator follows its beat events. No beat haptics are promised.

Only one mode runs. Stop/Cancel, switching mode, entering the background, audio interruptions, actual route/format changes or media-service loss stop the session. Temporary foreground inactivity (for example, opening Control Center) preserves an engaged session, including a pending start or fade. New starts still require an active scene; pending starts wait for it to become active again. Background/Cancel cancels pending intent. Starts wait for prior fade/engine shutdown/session deactivation. Nothing resumes automatically. After denial, the tuner offers **Open microphone settings**; Tone and Metronome remain usable without microphone permission.

Audio is processed locally without saved recordings, accounts, analytics or networking. The app has no background-audio entitlement. If media services are lost, Start remains unavailable until a reset notification arrives. Reset discards orphaned engine/tap state without querying or stopping those objects, including deferred fade cleanup; the next explicit Start configures a fresh engine and session. Tap-timing recovery retains a validated input format before stopping the engine. Simulator tone/metronome output is intentionally muted at the final render boundary; the real oscillators, engine and visual clock still run. The simulator tuner uses actual microphone permission/input, never synthetic live values.

## Reused core and limitations

Both apps compile the same `Sources/TunerDSP` files directly: the native Pitchy 4.1.0 McLeod adaptation, production profile policy, input leveling, bounded contiguous capture worker, tracker, vocal display averaging, equal-tempered note conversion, tone and metronome. No DSP equation, clarity threshold, profile range, calibration offset or output amplitude was changed. The iOS adapter uses iOS `AVAudioSession.setActive`, its actual stream sample rate, and the existing cancellation/shutdown policy with foreground-only activity handling. Minimum iOS 18 is needed for `Synchronization.Atomic`.

The [known production pitch limitations](../VALIDATION.md#known-failing-tests) apply. Confident wrong vocal notes/octaves, periodic hum and piano bias are known; a clear reading does not establish acoustic accuracy. Input leveling is software normalization, not microphone gain control or calibrated dB SPL. Synthetic tests do not establish real-device tuning accuracy, clock accuracy or latency.

Pitchy’s complete MIT notice remains available under Settings → Open-source licenses and is bundled as `Pitchy-4.1.0-LICENSE.txt`. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). The iOS icon reuses the [Watch asset-catalog artwork](../THIRD_PARTY_NOTICES.md#app-icon).

## Build and checks

Use Xcode 16 or later with an installed iOS 18+ SDK. Select a simulator in Xcode and run the shared scheme. For a device build, select your signing team in Xcode.

Run from the repository root on a Mac:

```sh
python3 Scripts/generate-ios-project.py
xcodebuild -project WatchTunerIOS.xcodeproj -scheme WatchTunerIOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/IOSSimulator -jobs 2 CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WatchTunerIOS.xcodeproj -scheme WatchTunerIOS -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build/IOSDevice -jobs 2 CODE_SIGNING_ALLOWED=NO build
swift test --scratch-path .build/DSPBuild --configuration release --jobs 2
```

Linux checks (Swift 6 is required for Swift checks):

```sh
python3 Scripts/check-ios-project.py --swiftc /path/to/swiftc
python3 Scripts/check-portable-core.py --swift /path/to/swift
```

See [validation coverage and device checks](VALIDATION.md).
