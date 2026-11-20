# Watch Tuner

A tiny, native, standalone SwiftUI Apple Watch app with three mutually exclusive modes:

- **Tuner:** detected Hz, nearest equal-tempered note/reference Hz, and a −50…+50 cents bar (A4 = 440 Hz). **Vocals is the default**. Long-press the tuner reading, or tap its visible profile/settings control, to choose persisted Vocals, Piano or Guitar settings. These are profiles within Tuner; Tone and Metronome stay separate.
- **Tone:** choose Hz with a deliberate Digital Crown turn (10 Hz steps after a movement dead zone), larger 1 Hz buttons or 440/880/1000 Hz shortcuts, then explicitly Start/Stop. The full 20–8000 Hz oscillator range remains selectable on every output. The Hz control receives explicit Crown focus on opening Tone, returning from a system prompt and after tone actions, so Crown rotations adjust frequency while touch scrolling remains available. Weak-bass/Bluetooth guidance explains the Watch speaker’s limitations without blocking playback or changing the requested frequency. A sine oscillator preserves phase while ramping gain/frequency; output gain is capped at 0.15 and starts at 0.10.

- **Metronome:** 30–240 BPM via Crown or 1 BPM buttons, 1–8 beats per bar, optional first-beat accent, visual beat indicator, and explicit Start/Stop. Clicks are scheduled per rendered audio sample; live tempo changes retain fractional beat progress.

Open `WatchTuner.xcodeproj` in Xcode. Select the shared `WatchTuner` scheme and a Watch simulator. No external packages. `Package.swift` builds only the platform-independent DSP/capture core and its host tests (macOS 15+ for Synchronization atomics). `Scripts/generate-project.py` recreates the checked-in Xcode project without installing a generator.

The app targets watchOS 11 or later. Use Xcode with Swift 6 and Icon Composer support. A physical Watch requires your own signing team.

The tone generator and metronome use `.playback` / `.default` / `.longFormAudio` and async session activation. The system chooses a route; the app shows that route and does not force the speaker. On supported models, speaker output is unavailable for long-form audio while charging. Bluetooth may take priority. The 20–8000 Hz range describes generated samples, **not** the usable acoustic range of the tiny Watch speaker. This is a tuning aid, not a calibrated frequency/level meter.

Only one mode runs at a time. An explicitly started tuner continues through wrist-down/inactive/background transitions using the supported `UIBackgroundModes = [audio]` declaration. Stop, mode changes, actual audio route/format loss, interruptions and media-service failure still stop capture; it never restarts automatically. A pending permission/route prompt preserves Start intent through inactivity but still waits for foreground before activating; background or Cancel cancels a pending start. Tone/Metronome retain their existing inactive/background stop behavior. Restarts await the entire fade, engine stop and session deactivation. No workout workaround, extended-runtime session, saved recordings, network, analytics or account. Permission is requested only when starting the tuner. Denial leaves the tone generator and metronome available.

Simulator builds render tone/metronome samples to silence at the output boundary, while exercising the same oscillator, beat clock, engine and lifecycle. Tests therefore never play through Mac speakers. Physical Watch builds retain normal audio output; simulator checks do not validate audibility.

See [development and validation](VALIDATION.md) for build commands, known failing tests, and hardware checks.

## Commands

From the repository root:

```sh
swift test --scratch-path .build/DSPBuild --configuration release --jobs 2
python3 Scripts/check-watch-production.py
xcodebuild -project WatchTuner.xcodeproj -scheme WatchTuner -sdk watchos -destination 'generic/platform=watchOS' -derivedDataPath .build/DerivedData -jobs 2 CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WatchTuner.xcodeproj -scheme WatchTuner -sdk watchsimulator -destination 'generic/platform=watchOS Simulator' -derivedDataPath .build/DerivedData -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

In restricted execution, Xcode/Swift build tools need normal macOS compiler/cache access; no host security setting is changed. Builds are run serially with bounded top-level job counts.

The production smoke check compiles the generated Watch DSP source inventory with `WATCHTUNER_APP` and verifies algorithm availability and configuration codes without audio input. Offline SwiftPM tests retain the historical estimators.

## Pitch detection

The app uses the native **McLeod · Pitchy 4.1.0** adaptation for all three instrument profiles. Historical harmonic implementations are available to offline regression tests and comparison tools.

Pitchy receives the shared microphone capture and automatic linear level adjustment, with a 0.8 clarity threshold, selected profile range and at least four cycles. This is a bounded native adaptation, not a JS runtime or verbatim upstream deployment. Instrument selection changes range, capture cadence, confirmation and vocal display averaging; it does not change the captured samples, microphone gain or EQ. Open-source notices remain available in Settings and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Input sensitivity and speaker guidance

The tuner no longer requires RMS ≥0.003 or a peak ≥0.006 before attempting pitch detection. Each complete analysis window has DC removed and receives a single linear gain targeting RMS 0.12, capped at 4096× and peak 0.8. Quiet windows are raised and loud windows attenuated; one gain preserves waveform shape and within-window dynamics. The remaining 1e-9 RMS numerical-zero floor is not an ambient-noise gate. Pitchy’s normalized periodicity/clarity test decides whether a pitch is meaningful at any input level. Gain cannot improve signal-to-noise ratio or recover already clipped samples.

Near-full-scale samples alone no longer trigger “Input overload.” The heuristic requires more than 1% near-rail samples and a repeated flat plateau of at least three samples. It is a digital-input heuristic, not a calibrated dB SPL measurement or proof of microphone saturation. The watchOS SDK marks `AVAudioSession.setInputGain`, `inputGain` and `isInputGainSettable` unavailable on watchOS, so this is software analysis normalization, not microphone preamplifier control. No raw microphone audio is stored or exported.

Low tones may be weak or inaudible on the Watch speaker. Bluetooth can provide a more useful output range. Frequency edits preserve the selected Hz, phase continuity and gain ramps.

## Metronome timing

A fractional phase accumulator advances using the active audio sample rate. Tempo and accent changes are consumed at audio-buffer boundaries; changing tempo preserves progress through the current beat. New Start begins at beat one. A bar-length edit begins a new bar on the next actual beat, including its accent; the display follows the active bar published by the renderer. The click has a short attack/release, with digital peak bounded below 0.16. A packed atomic beat event drives the visual indicator; its display polling is not the audio timebase. Display/render latency and hardware clock accuracy still need physical Watch validation. No metronome beat haptics are generated or promised.

## Capture continuity and harmonic pitch

**Capture timing and recovery:** the installed watchOS 27 `AVAudioNode.h` specifies a supported tap-request range of 100–400 ms; the OS may deliver a different size. Start requests `max(2048, ceil(rate × 0.10))` frames. Three consecutive admitted, valid buffers with missing/mismatched timestamps and less than one complete analysis window trigger one stopped-engine tap replacement, requesting `max(2048, ceil(rate × 0.18))` frames. The UI shows “Listening • slower updates”. If three more undersized unknown-timestamp buffers arrive, capture stops with an explicit timing-unavailable message; Start permits a new attempt. Valid timing or an independently complete buffer resets the consecutive count. Profile edits do not replenish the retry budget.

The microphone adapter passes timestamps in the buffer's sample-rate domain to a bounded worker. Only consecutive samples accumulate across buffers; unknown timing permits an independent full buffer, never splicing. Dropped/gapped/invalid input clears partial frames and invalidates old results. Capture assembly and analysis have separate one-deep queues. Each admitted sample copy keeps the configuration revision captured before copying. A queued buffer made obsolete by a profile/detector edit is discarded before timing recovery or frame assembly, including edits that return to the same profile. Voice/piano keep a 180 ms history with a nominal 20 ms overlap hop, but a callback produces at most one estimate. The supported 100 ms request therefore cannot guarantee 50 Hz display updates or fully resolve 6 Hz vibrato in time. At 48 kHz, synthetic 4800-frame input acquires after 300 ms; full 8640-frame unknown-timestamp input after 360 ms. These are sample-time observations excluding actual device/CPU/UI delays. A lower-latency sink-node capture path is a separate unresolved implementation/validation item. Real Watch timestamp validity, delivered sizes and retry success remain hardware checks; the simulator fixture does not prove them.

The active Pitchy adaptation uses a normalized square difference function, selects the first key maximum at least 0.9 of the strongest, and refines its lag parabolically. It retains the application’s 0.8 clarity floor. A clear periodic result can still represent an unintended note or octave, including a stable wrong reading: bright vocals can lock an octave or roughly 19 semitones high. This occurs outside the three accepted bright-vocal regression groups too; those fixtures do not define a safe accuracy boundary. Very quiet periodic hum may be reported as a note, and stronger hum can change a source’s note/octave. Use one isolated source at a time; neither the clarity score nor level adjustment separates simultaneous sources. The legacy harmonic estimators remain for regression coverage and are not selectable in the app. Pitchy’s complete MIT attribution remains in Settings.

## Tuner profiles

| Profile | Signal policy | Supported analysis range |
| --- | --- | --- |
| **Vocals (default)** | Shared Pitchy estimator; two-frame acquisition/isolated-octave confirmation. Display averages log-frequency with a 220 ms time constant (60 ms for movements above 150 cents). Uncertainty clears immediately; no note snapping. | 40–2000 Hz. |
| **Piano** | Shared Pitchy estimator; two-frame acquisition/isolated-octave confirmation. Play one key after its attack, pedal released. Equal-tempered reference A4 = 440 Hz; no stretch-tuning curve. | 27.5–4200 Hz. |
| **Guitar** | Shared Pitchy estimator; direct readings without vocal averaging. Play one string and mute the others. | 55–2000 Hz. |

Changing profile while listening immediately clears the reading and invalidates accumulated samples, temporal history and pending results. Profiles persist across launches; audio always launches stopped. Neither Piano nor Vocals is a chord/polyphonic tuner. Piano does not calculate a professional piano stretch-tuning curve or separate beating unison strings.

Synthetic tests exercise the analysis ranges and confirmation policies. Microphone accuracy, device latency, and power use require hardware validation.

Piano inharmonicity can bias pitch readings sharp. The piano profile uses equal temperament and provides no stretch-tuning curve.

## Watch controls

The common Start/Stop/Cancel footer is capped at 140 points, inset at least 24 points horizontally and given a 12-point bottom inset. Tone's ± buttons are 44×44-point targets with exact 1 Hz edits. Presets sit immediately below the frequency controls so larger buttons do not push them into the footer.

Tone receives Crown input on an unbounded native axis that is never programmatically re-centered. This removes the short range end and reset-induced reverse delta. The higher-sensitivity native axis is divided by 1280 before filtering. A gesture must first travel 0.4 normalized units in one direction; subsequent 0.1-unit travel produces 10 Hz steps. These are SwiftUI axis units, not calibrated physical angles. Idle, a >250 ms input gap, reversal, explicit button/preset/start action, mode change and foreground return reset only the gesture dead zone. Separate small bumps do not accumulate. Frequency stays bounded to 20–8000 Hz. Both metronome tempo and bar-length ± controls use 44×44-point targets; metronome timing/amplitude are unchanged.

## App icon

The production icon is an Icon Composer document with three overlaid mint sine waves. See [icon provenance](THIRD_PARTY_NOTICES.md#app-icon).

## License

First-party material is available under the [Apache License, Version 2.0](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for Pitchy’s MIT license and attribution.
