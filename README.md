# Watch Tuner

A standalone Apple Watch app for tuning a single voice or instrument, playing a reference tone, and keeping time. Built with SwiftUI; no companion iPhone app or external packages are required.

- **Tuner:** live frequency, nearest note, and cents from equal temperament (A4 = 440 Hz). Choose Vocals, Piano, or Guitar in Settings.
- **Tone:** a sine wave from 20–8,000 Hz, with Digital Crown control, 1 Hz buttons, and frequency presets.
- **Metronome:** 30–240 BPM, 1–8 beats per bar, an optional first-beat accent, and a visual beat indicator.

Only one mode runs at a time. Tap **Start** to begin and **Stop** to finish. Profiles are remembered; audio starts stopped when the app launches.

## Build and run

Use a Mac with Xcode supporting Swift 6 and Icon Composer assets. The app targets **watchOS 11 or later**; host DSP tests require **macOS 15 or later**.

1. Open `WatchTuner.xcodeproj`.
2. Select the shared `WatchTuner` scheme and a Watch simulator or device.
3. Build and run. For a physical Watch, select your own signing team in Xcode; none is stored in the project.

Simulator tone and metronome output is intentionally silent. Use a physical Watch, optionally with Bluetooth audio, to check audibility.

## Microphone and playback

Microphone permission is requested when you start the tuner. A started tuner keeps listening with your wrist down until you stop it or an interruption ends the session. Tone and metronome stop when the app becomes inactive. Audio is processed on the Watch, with no saved recordings, accounts, analytics, or network requests.

Playback follows the system audio route. Watch speaker support varies by model and charging state; low tones may be weak or inaudible. Bluetooth can provide a more useful output range.

## Known limitations

Use one voice, piano key, or guitar string at a time. The tuner can confidently report the wrong note or octave, especially with bright vocals or background hum. Piano overtones can pull readings sharp; there is no stretch-tuning curve. This is a tuning aid, not a calibrated meter or professional piano-tuning tool.

## Development

```sh
swift test --configuration release --jobs 2
python3 Scripts/check-watch-production.py
python3 Scripts/audit-pitch-dependencies.py
```

The host suite has three known failing vocal regression cases; see [validation notes](VALIDATION.md) for their names, build commands, and coverage limits. Regression and simulator tests are retained in `Tests/` and `UITests/`.

Pitch detection uses a native adaptation of **Pitchy 4.1.0**. See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution and icon provenance.

## License

First-party material is available under the [Apache License, Version 2.0](LICENSE). The Pitchy adaptation retains its MIT terms.
