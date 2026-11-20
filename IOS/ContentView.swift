import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var audio = IOSAudioController()
    @State private var settingsPresented = false
    @State private var frequencyText = "440"
    @State private var frequencyError: String?
    @FocusState private var frequencyFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var readingSize = 76.0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Picker("Mode", selection: $audio.mode) {
                        ForEach(IOSAudioController.Mode.allCases, id: \.self) { mode in
                            Text(mode == .metronome ? "Metronome" : mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mode-picker")

                    switch audio.mode {
                    case .tuner: tuner
                    case .tone: toneGenerator
                    case .metronome: metronome
                    }

                    audioStatus
                }
                .frame(maxWidth: 620)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Watch Tuner")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settingsPresented = true }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("profile-settings")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Apply") { _ = applyFrequency() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { transport }
            .sheet(isPresented: $settingsPresented) { settings }
        }
        .onChange(of: audio.mode) {
            frequencyFocused = false
            frequencyError = nil
            audio.changeMode()
        }
        .onChange(of: audio.frequency) {
            audio.updateFrequency()
            if !frequencyFocused { syncFrequencyText() }
        }
        .onChange(of: frequencyFocused) {
            if !frequencyFocused { _ = applyFrequency() }
        }
        .onChange(of: audio.bpm) { audio.updateMetronome() }
        .onChange(of: audio.beatsPerBar) { audio.updateMetronome() }
        .onChange(of: audio.accentFirstBeat) { audio.updateMetronome() }
        .onAppear { updateActivity() }
        .onChange(of: scenePhase) { updateActivity() }
    }

    private var tuner: some View {
        VStack(spacing: 20) {
            HStack {
                Label(audio.profile.rawValue, systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Button("Change") { settingsPresented = true }
                    .font(.subheadline)
            }

            VStack(spacing: 8) {
                Text(currentNote?.name ?? "—")
                    .font(.system(size: readingSize, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(.mint)
                Text(currentHz.map { String(format: "%.1f Hz", $0) } ?? "— Hz")
                    .font(.title2.monospacedDigit())
                Text(currentNote.map { String(format: "Reference %.2f Hz", $0.referenceHz) } ?? signalLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tuner reading")
            .accessibilityValue(pitchAccessibilityValue)
            .accessibilityIdentifier("tuner-reading")

            IOSCentsMeter(cents: currentNote?.cents)
            Text(currentNote.map { String(format: "%+.0f cents", $0.cents) } ?? "Waiting for a clear pitch")
                .font(.headline.monospacedDigit())
                .foregroundStyle(currentNote.map { abs($0.cents) < 5 ? Color.mint : .primary } ?? .secondary)
            Text("A4 = 440 Hz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("tuner-panel")
        .followedByGuidance(audio.profile.guidance)
    }

    private var currentHz: Double? {
        guard audio.running, case let .pitch(hz, _) = audio.reading else { return nil }
        return hz
    }

    private var currentNote: MusicalNote? { currentHz.flatMap(MusicalNote.init(frequency:)) }

    private var pitchAccessibilityValue: String {
        guard let hz = currentHz, let note = currentNote else { return signalLabel }
        return String(format: "%@, %.1f hertz, %+.0f cents, reference %.2f hertz", note.name, hz, note.cents, note.referenceHz)
    }

    private var signalLabel: String {
        if audio.starting { return "Preparing microphone…" }
        guard audio.running else { return "Tap Listen to begin" }
        switch audio.reading {
        case .silence: return "No signal"
        case .unclear: return "No clear pitch"
        case .clipped: return "Input overload — move farther away"
        case .pitch: return "Listening"
        }
    }

    private var toneGenerator: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Tone generator", systemImage: "waveform.path")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Frequency").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TextField("Frequency", text: $frequencyText)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                        .keyboardType(.decimalPad)
                        .focused($frequencyFocused)
                        .submitLabel(.done)
                        .onSubmit { _ = applyFrequency() }
                        .accessibilityLabel("Tone frequency in hertz")
                        .accessibilityIdentifier("frequency-input")
                    Text("Hz").font(.title2).foregroundStyle(.secondary)
                    if frequencyFocused {
                        Button("Apply") { _ = applyFrequency() }.font(.body)
                    }
                }
                if let frequencyError {
                    Text(frequencyError).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("frequency-error")
                }
            }

            VStack(spacing: 6) {
                Slider(value: logarithmicFrequency, in: log2(20)...log2(8000))
                    .accessibilityLabel("Tone frequency")
                    .accessibilityValue("\(Int(audio.frequency)) hertz")
                    .accessibilityIdentifier("frequency-slider")
                HStack {
                    Text("20 Hz")
                    Spacer()
                    Text("8,000 Hz")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Adjust by 1 Hz", value: toneFrequency, in: 20...8000, step: 1)
                .accessibilityValue("\(Int(audio.frequency)) hertz")
                .accessibilityIdentifier("frequency-stepper")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { frequencyPresets }
                VStack(alignment: .leading, spacing: 10) { frequencyPresets }
            }

            Text(audio.toneExternalOutput
                 ? "Audibility depends on your connected audio device."
                 : "Low tones may be weak on the \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") speaker. Try headphones or an external speaker.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24))
    }

    private var frequencyPresets: some View {
        ForEach([220.0, 440, 880, 1000], id: \.self) { hz in
            Button("\(Int(hz)) Hz") { setFrequency(hz) }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("preset-\(Int(hz))")
        }
    }

    private var toneFrequency: Binding<Double> {
        Binding(get: { audio.frequency }, set: { setFrequency($0) })
    }

    private var logarithmicFrequency: Binding<Double> {
        Binding(get: { log2(audio.frequency) }, set: { setFrequency(pow(2, $0).rounded()) })
    }

    private func setFrequency(_ value: Double) {
        frequencyFocused = false
        frequencyError = nil
        audio.frequency = min(8000, max(20, value))
        syncFrequencyText()
    }

    @discardableResult private func applyFrequency() -> Bool {
        guard let value = ToneFrequencyInput.frequency(from: frequencyText) else {
            frequencyError = ToneOutputPolicy.frequencyGuidance
            return false
        }
        frequencyError = nil
        audio.frequency = value
        frequencyFocused = false
        syncFrequencyText()
        return true
    }

    private func syncFrequencyText() {
        frequencyText = ToneFrequencyInput.text(for: audio.frequency)
    }

    private var metronome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Metronome", systemImage: "metronome")
                .font(.headline)
            VStack(spacing: 4) {
                Text("\(Int(audio.bpm))")
                    .font(.system(size: readingSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.mint)
                Text("beats per minute").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tempo")
            .accessibilityValue("\(Int(audio.bpm)) beats per minute")
            .accessibilityIdentifier("bpm-value")

            Slider(value: $audio.bpm, in: 30...240, step: 1)
                .accessibilityLabel("Tempo")
                .accessibilityValue("\(Int(audio.bpm)) beats per minute")
            Stepper("Adjust by 1 BPM", value: $audio.bpm, in: 30...240, step: 1)
                .accessibilityIdentifier("tempo-stepper")
            Divider()
            Stepper(value: $audio.beatsPerBar, in: 1...8) {
                LabeledContent("Beats per bar", value: "\(audio.beatsPerBar)")
            }
            .accessibilityIdentifier("bar-stepper")
            Toggle("Accent first beat", isOn: $audio.accentFirstBeat)
                .accessibilityIdentifier("accent-toggle")

            HStack(spacing: 12) {
                ForEach(0..<audio.displayedBeatsPerBar, id: \.self) { beat in
                    Circle()
                        .fill(beatColor(beat))
                        .frame(maxWidth: 28)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Text("\(beat + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(audio.beatIndex == beat && audio.beatFlash ? .black : .secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Beat")
            .accessibilityValue(audio.beatIndex.map { "\($0 + 1) of \(audio.displayedBeatsPerBar)" } ?? "Ready")
            .accessibilityIdentifier("beat-value")
        }
        .padding(24)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24))
    }

    private func beatColor(_ beat: Int) -> Color {
        guard audio.beatIndex == beat, audio.beatFlash else { return .secondary.opacity(0.2) }
        return beat == 0 && audio.accentFirstBeat ? .orange : .mint
    }

    private var audioStatus: some View {
        VStack(spacing: 10) {
            Text(audio.status)
                .font(.subheadline)
                .accessibilityIdentifier("audio-status")
            if !audio.route.isEmpty {
                Label(audio.route, systemImage: audio.mode == .tuner ? "mic" : "speaker.wave.2")
                    .font(.caption)
            }
            if audio.mode == .tuner {
                if audio.microphonePermissionDenied {
                    Button("Open microphone settings") { audio.openSettings() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("microphone-settings")
                } else if !audio.running && !audio.starting {
                    Text("The tuner uses your microphone to measure one voice or instrument at a time.")
                        .font(.footnote)
                }
            }
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        Button {
            if audio.running || audio.starting {
                audio.stop()
            } else {
                if audio.mode == .tone && !applyFrequency() { return }
                frequencyFocused = false
                audio.start()
            }
        } label: {
            Label(transportTitle, systemImage: audio.running || audio.starting ? "stop.fill" : audio.mode == .tuner ? "mic.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(audio.running || audio.starting ? .red : .mint)
        .foregroundStyle(audio.running || audio.starting ? .white : .black)
        .accessibilityIdentifier("audio-toggle")
        .frame(maxWidth: 620)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var transportTitle: String {
        if audio.starting { return "Cancel" }
        if audio.running { return "Stop" }
        return audio.mode == .tuner ? "Listen" : audio.mode == .tone ? "Play tone" : "Start metronome"
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Tuner profile") {
                    ForEach(TunerProfile.allCases, id: \.self) { profile in
                        Button { audio.selectProfile(profile) } label: {
                            HStack {
                                Text(profile.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if audio.profile == profile { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("profile-\(profile.rawValue)")
                        .accessibilityAddTraits(audio.profile == profile ? .isSelected : [])
                    }
                    Text(audio.profile.guidance).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Reference") {
                    LabeledContent("Concert pitch", value: "A4 = 440 Hz")
                    Text("Equal-tempered note references. Your profile is saved automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Text("Audio stops when this app moves into the background.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Open-source licenses") {
                        ScrollView {
                            Text(PitchAlgorithm.licenseNotice)
                                .font(.footnote)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                        .navigationTitle("Licenses")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { settingsPresented = false }
                        .accessibilityIdentifier("profiles-done")
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var cardBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private func updateActivity() {
        switch scenePhase {
        case .active: audio.sceneChanged(.active)
        case .inactive: audio.sceneChanged(.inactive)
        case .background: audio.sceneChanged(.background)
        @unknown default: audio.sceneChanged(.background)
        }
    }
}

private struct IOSCentsMeter: View {
    let cents: Double?

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    Rectangle().fill(.mint.opacity(0.3))
                        .frame(width: geometry.size.width * 0.1)
                        .offset(x: geometry.size.width * 0.45)
                    Rectangle().fill(.mint).frame(width: 2)
                        .offset(x: geometry.size.width / 2 - 1)
                    if let cents {
                        Circle()
                            .fill(abs(cents) < 5 ? Color.mint : .orange)
                            .frame(width: 16, height: 16)
                            .offset(x: (min(50, max(-50, cents)) + 50) / 100 * (geometry.size.width - 16))
                    }
                }
            }
            .frame(height: 16)
            HStack {
                Text("♭ −50")
                Spacer()
                Text("0")
                Spacer()
                Text("+50 ♯")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cents meter")
        .accessibilityValue(cents.map { String(format: "%+.0f cents from nearest note", $0) } ?? "No pitch")
    }
}

private extension View {
    func followedByGuidance(_ guidance: String) -> some View {
        VStack(spacing: 16) {
            self
            Text(guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }
}
