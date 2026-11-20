import SwiftUI
import WatchKit

@main struct WatchTunerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var audio = AudioController()
    @State private var settingsPresented = false
    @State private var licensesVisible = false
    @State private var toneCrownPosition = 0.0
    @State private var toneCrownFilter = ToneCrownFilter()
    @FocusState private var toneFrequencyFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(spacing: audio.mode == .metronome ? 0 : 5) {
                HStack(spacing: 4) {
                    ForEach(AudioController.Mode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { audio.mode = mode }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(audio.mode == mode ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.15), in: Capsule())
                            .accessibilityAddTraits(audio.mode == mode ? .isSelected : [])
                            .accessibilityLabel(mode == .metronome ? "Metronome" : mode.rawValue)
                    }
                }
                switch audio.mode {
                case .tuner:
                    ZStack(alignment: .topTrailing) {
                        tuner
                            .contentShape(Rectangle())
                            .onLongPressGesture { settingsPresented = true }
                            .accessibilityAction(named: "Tuner settings") { settingsPresented = true }
                        Button { settingsPresented = true } label: {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(audio.profile.rawValue).font(.system(size: 11, weight: .medium))
                                HStack(spacing: 3) {
                                    Text("Settings")
                                    Image(systemName: "gearshape")
                                }.font(.system(size: 8))
                            }.padding(.horizontal, 5)
                        }
                        .buttonStyle(.plain).frame(width: 108, height: 32)
                        .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityIdentifier("profile-settings")
                        .accessibilityLabel("Tuner settings")
                        .accessibilityValue(audio.profile.rawValue)
                    }
                case .tone: generator
                case .metronome: metronome
                }
                Text(audio.status).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("audio-status")
                if !audio.route.isEmpty {
                    Text(audio.route).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(audio.starting ? "Cancel" : audio.running ? "Stop" : "Start") {
                if audio.running || audio.starting { audio.stop() } else { audio.start() }
                if audio.mode == .tone { resetToneCrown(); toneFrequencyFocused = true }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 32)
            .frame(maxWidth: 140)
            .accessibilityIdentifier("audio-toggle")
            .background(audio.running ? Color.red.opacity(0.5) : Color.green.opacity(0.4), in: Capsule())
            .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(.black)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("Watch Tuner")
        .sheet(isPresented: $settingsPresented) { profileSettings }
        .onChange(of: audio.mode) {
            audio.changeMode()
            resetToneCrown()
            toneFrequencyFocused = audio.mode == .tone
        }
        .onChange(of: audio.frequency) { audio.updateFrequency() }
        .onChange(of: audio.bpm) { audio.updateMetronome() }
        .onChange(of: audio.beatsPerBar) { audio.updateMetronome() }
        .onChange(of: audio.accentFirstBeat) { audio.updateMetronome() }
        .onAppear { updateActivity() }
        .onChange(of: scenePhase) { updateActivity() }
    }
    private func updateActivity() {
        switch scenePhase {
        case .active:
            audio.sceneChanged(.active)
            if audio.mode == .tone { resetToneCrown(); toneFrequencyFocused = true }
        case .inactive: audio.sceneChanged(.inactive)
        case .background: audio.sceneChanged(.background)
        @unknown default: audio.sceneChanged(.background)
        }
    }

    private var profileSettings: some View {
        ScrollView {
            VStack(spacing: 7) {
                Text("Instrument").font(.headline)
                ForEach(TunerProfile.allCases, id: \.self) { profile in
                    Button {
                        audio.selectProfile(profile)
                    } label: {
                        HStack {
                            Text(profile.rawValue)
                            Spacer()
                            if audio.profile == profile { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("profile-\(profile.rawValue)")
                    .accessibilityLabel(profile.rawValue)
                    .accessibilityValue(audio.profile == profile ? "Selected" : "Not selected")
                }
                Text("Pitchy")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("detector-build")
                Text(audio.profile.guidance).font(.caption2).multilineTextAlignment(.center)
                Text("One source at a time. Octave ambiguity remains possible.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Done") { settingsPresented = false }.accessibilityIdentifier("profiles-done")
                Button("Open-source licenses") { licensesVisible.toggle() }
                if licensesVisible {
                    Text(PitchAlgorithm.licenseNotice).font(.caption2)
                }
            }.padding(.horizontal, 6)
        }
    }

    private var compactWatch: Bool { WKInterfaceDevice.current().screenBounds.height < 250 }
    private var tuner: some View {
        VStack(spacing: compactWatch ? 0 : 2) {
            if case let .pitch(hz, _) = audio.reading, let note = MusicalNote(frequency: hz) {
                Text(note.name).font(.system(size: compactWatch ? 20 : 26, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                (Text(hz, format: .number.precision(.fractionLength(1))) + Text(" Hz")).font(.system(size: compactWatch ? 16 : 18))
                CentsMeter(cents: note.cents)
                Text(String(format: "%+.0f cents", note.cents)).font(.system(size: 12))
                Text(String(format: "Reference %.2f Hz", note.referenceHz)).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: compactWatch ? 20 : 26, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                Text("— Hz").font(.system(size: compactWatch ? 16 : 18))
                CentsMeter(cents: nil)
                Text(signalLabel).font(.system(size: 12))
                Text("A4 = 440 Hz • \(audio.profile.minimumHz, specifier: "%g")–\(audio.profile.maximumHz, specifier: "%g") Hz").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
            .accessibilityIdentifier("tuner-reading")
            .accessibilityValue({
                if case let .pitch(hz, _) = audio.reading { return String(format: "%.1f Hz", hz) }
                return signalLabel
            }())
    }
    private var signalLabel: String {
        guard audio.running else { return "Tap Start to listen" }
        switch audio.reading {
        case .silence: return "No signal"
        case .unclear: return "No clear pitch"
        case .clipped: return "Input overload — move away"
        case .pitch: return "Listening"
        }
    }
    private var generator: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Button { changeToneFrequency(by: -1) } label: {
                    Image(systemName: "minus").font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44).background(.gray.opacity(0.2), in: Circle())
                }.accessibilityLabel("Decrease frequency")
                Text("\(Int(audio.frequency)) Hz").font(.system(size: 18).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("frequency-value")
                    .accessibilityValue(String(Int(audio.frequency)))
                    .focusable()
                    .focused($toneFrequencyFocused)
                    .digitalCrownRotation(toneCrownBinding, onChange: { _ in },
                                          onIdle: { resetToneCrown() })
                    .onAppear { resetToneCrown(); toneFrequencyFocused = true }
                    .onTapGesture { resetToneCrown(); toneFrequencyFocused = true }
                Button { changeToneFrequency(by: 1) } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44).background(.gray.opacity(0.2), in: Circle())
                }.accessibilityLabel("Increase frequency")
            }.buttonStyle(.plain).frame(height: 44)
            HStack {
                ForEach([440.0, 880.0, 1000.0], id: \.self) { hz in
                    Button("\(Int(hz))") { resetToneCrown(); audio.frequency = hz; toneFrequencyFocused = true }.font(.caption2)
                        .accessibilityIdentifier("preset-\(Int(hz))")
                }
            }.buttonStyle(.plain).frame(height: 28)
            Text("Crown: 10 Hz • Buttons: ±1 Hz").font(.system(size: 9)).foregroundStyle(.secondary)
            Text(audio.toneExternalOutput
                 ? "20–8000 Hz. Audibility depends on the connected device."
                 : "20–8000 Hz. " + ToneOutputPolicy.speakerGuidance)
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .accessibilityIdentifier("tone-output-guidance")
        }
        .defaultFocus($toneFrequencyFocused, true, priority: .userInitiated)
    }
    private var toneCrownBinding: Binding<Double> {
        Binding(get: { toneCrownPosition }, set: { position in
            // The unbounded modifier reports a much larger native axis than the
            // old bounded/low-sensitivity control. Normalize before filtering.
            let delta = (position - toneCrownPosition) / 1280
            toneCrownPosition = position
            if let frequency = toneCrownFilter.turn(delta: delta, frequency: audio.frequency,
                                                     at: ProcessInfo.processInfo.systemUptime) {
                audio.frequency = frequency
            }
        })
    }
    // Keep the unbounded native axis intact. Re-centering it introduces a reverse
    // delta when SwiftUI next delivers Crown input.
    private func resetToneCrown() { toneCrownFilter.reset() }
    private func changeToneFrequency(by hz: Double) {
        resetToneCrown()
        audio.frequency = min(8000, max(20, audio.frequency + hz))
        toneFrequencyFocused = true
    }
    private func adjustmentIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 22, weight: .semibold))
            .frame(width: 44, height: 44).background(.gray.opacity(0.2), in: Circle())
    }
    private var metronome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button { audio.bpm = max(30, audio.bpm - 1) } label: { adjustmentIcon("minus") }
                    .accessibilityLabel("Decrease tempo")
                Text("\(Int(audio.bpm)) BPM").font(.system(size: 18).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("bpm-value")
                    .accessibilityValue(String(Int(audio.bpm)))
                    .focusable()
                    .digitalCrownRotation($audio.bpm, from: 30, through: 240, by: 1,
                                          sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: false)
                Button { audio.bpm = min(240, audio.bpm + 1) } label: { adjustmentIcon("plus") }
                    .accessibilityLabel("Increase tempo")
            }.buttonStyle(.plain).frame(height: 44)
            HStack(spacing: 5) {
                Button { audio.beatsPerBar = max(1, audio.beatsPerBar - 1) } label: { adjustmentIcon("minus") }
                    .accessibilityLabel("Fewer beats per bar")
                Text("\(audio.beatsPerBar) beats/bar").font(.caption2)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("bar-value")
                    .accessibilityValue(String(audio.beatsPerBar))
                Button { audio.beatsPerBar = min(8, audio.beatsPerBar + 1) } label: { adjustmentIcon("plus") }
                    .accessibilityLabel("More beats per bar")
            }.buttonStyle(.plain).frame(height: 44)
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(0..<audio.displayedBeatsPerBar, id: \.self) { beat in
                        Circle().fill(audio.beatIndex == beat && audio.beatFlash
                                      ? (beat == 0 && audio.accentFirstBeat ? Color.orange : Color.green)
                                      : Color.gray.opacity(0.35))
                            .frame(width: 12, height: 12)
                    }
                }.accessibilityHidden(true)
                Text(audio.beatIndex.map { "Beat \($0 + 1)" } ?? "Ready")
                    .font(.system(size: 10)).accessibilityIdentifier("beat-value")
                    .accessibilityLabel(audio.beatIndex.map { "Beat \($0 + 1) of \(audio.displayedBeatsPerBar)" } ?? "Ready")
                    .accessibilityValue(String((audio.beatIndex ?? -1) + 1))
            }.frame(height: 12)
            Toggle("Accent first beat", isOn: $audio.accentFirstBeat).font(.caption2)
                .accessibilityIdentifier("accent-toggle")
            Text("Turn Crown • 30–240 BPM").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct CentsMeter: View {
    let cents: Double?
    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.gray.opacity(0.3))
                    Rectangle().fill(.secondary).frame(width: 1).offset(x: geometry.size.width / 2)
                    if let cents {
                        Circle().fill(abs(cents) < 5 ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                            .offset(x: (max(-50, min(50, cents)) + 50) / 100 * (geometry.size.width - 10))
                    }
                }
            }.frame(height: 10)
            HStack { Text("♭ −50"); Spacer(); Text("0"); Spacer(); Text("+50 ♯") }.font(.system(size: 10))
        }
        .accessibilityLabel(cents.map { String(format: "%+.0f cents from nearest note", $0) } ?? "No pitch")
    }
}
