import SwiftUI
import AVFAudio
import Synchronization

/// Only the render callback touches oscillator. UI communicates through lock-free atomics.
private final class ToneRenderer: @unchecked Sendable {
    let frequency = Atomic<UInt64>(440.0.bitPattern)
    let enabled = Atomic<Bool>(true)
    let quiet = Atomic<Bool>(false)
    private var oscillator = SineOscillator()
    func render(frames: Int, rate: Double, buffers: UnsafeMutableAudioBufferListPointer) {
        let hz = Double(bitPattern: frequency.load(ordering: .relaxed))
        let gain = enabled.load(ordering: .relaxed) ? 0.10 : 0
        for frame in 0..<frames {
            let value = oscillator.next(sampleRate: rate, targetHz: hz, targetAmplitude: gain)
            for buffer in buffers {
                #if targetEnvironment(simulator)
                // Exercise oscillator/engine/lifecycle without playing test tones
                // through the Mac's speakers. Physical Watch output is unchanged.
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = 0
                #else
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                #endif
            }
        }
        quiet.store(gain == 0 && oscillator.amplitude < 0.00001, ordering: .releasing)
    }
}

/// UI sends targets through atomics; audio publishes one packed beat snapshot.
private final class MetronomeRenderer: @unchecked Sendable {
    let bpm = Atomic<UInt64>(120.0.bitPattern)
    let beatsPerBar = Atomic<Int>(4)
    let accentFirst = Atomic<Bool>(true)
    let enabled = Atomic<Bool>(true)
    let quiet = Atomic<Bool>(false)
    let beatState = Atomic<UInt64>(0)
    private var sequence: UInt64 = 0
    private var oscillator = MetronomeOscillator()

    func render(frames: Int, rate: Double, buffers: UnsafeMutableAudioBufferListPointer) {
        let tempo = Double(bitPattern: bpm.load(ordering: .relaxed))
        let bar = beatsPerBar.load(ordering: .relaxed)
        let accent = accentFirst.load(ordering: .relaxed)
        let playing = enabled.load(ordering: .relaxed)
        for frame in 0..<frames {
            let sample = oscillator.next(sampleRate: rate, bpm: tempo, beatsPerBar: bar,
                                         accentFirst: accent, enabled: playing)
            if let beat = sample.beat {
                sequence &+= 1
                beatState.store((sequence << 16) | (UInt64(sample.beatsPerBar) << 8) | UInt64(beat + 1), ordering: .releasing)
            }
            for buffer in buffers {
                #if targetEnvironment(simulator)
                // Keep the real beat clock and visual events, mute speaker output.
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = 0
                #else
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample.value
                #endif
            }
        }
        quiet.store(!playing && oscillator.isSilent, ordering: .releasing)
    }
}

@MainActor final class AudioController: ObservableObject {
    enum Mode: String, CaseIterable { case tuner = "Tuner", tone = "Tone", metronome = "Metro" }
    @Published var mode: Mode = .tuner
    @Published private(set) var profile: TunerProfile
    #if targetEnvironment(simulator)
    private var syntheticInput: Task<Void, Never>?
    private var syntheticBufferSize = 1024
    #endif
    private var pitchProcessor: PitchCaptureProcessor?
    private var vocalDisplay = VocalDisplaySmoother()
    private var captureSerial: UInt64 = 0
    @Published var frequency = 440.0
    @Published private(set) var toneExternalOutput = false
    @Published var bpm = 120.0
    @Published var beatsPerBar = 4
    @Published var accentFirstBeat = true
    @Published private(set) var beatIndex: Int?
    @Published private(set) var beatFlash = false
    @Published private(set) var displayedBeatsPerBar = 4
    @Published private(set) var reading: PitchReading = .silence
    @Published private(set) var status = "Ready"
    @Published private(set) var route = ""
    @Published private(set) var running = false
    @Published private(set) var starting = false
    private var engine: AVAudioEngine?
    private var renderer: ToneRenderer?
    private var metronomeRenderer: MetronomeRenderer?
    private var beatUpdates: Task<Void, Never>?
    private var inputTapped = false
    private var sessionActive = false
    private let lifecycle = AudioLifecycle()
    private var generation: Int { lifecycle.generation }
    private var activation: Task<Bool, Error>?
    private var retiringEngine: AVAudioEngine?
    private var activeRoute: AudioRouteState?
    private var observers: [NSObjectProtocol] = []

    init() {
        profile = TunerProfile.load(from: .standard)
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-low-watch-tone") { frequency = 220 }
        #endif
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.running || self.starting else { return }
                    self.stop(message: "Audio interrupted. Tap Start to resume.", immediately: true)
                }
            })
        }
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.engine?.isRunning == false else { return }
                self.stop(message: "Audio configuration changed. Tap Start to resume.", immediately: true)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                self.updateRoute()
                guard self.running else { return }
                let event: AudioRouteEvent
                switch reason {
                case AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue: event = .lostDevice
                case AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue: event = .noSuitableRoute
                default: event = .changed
                }
                if AudioRoutePolicy.shouldStop(previous: self.activeRoute, current: self.routeState(), event: event) {
                    self.stop(message: "Audio route changed. Tap Start to resume.", immediately: true)
                }
            }
        })
    }

    func sceneChanged(_ activity: AudioActivity) {
        if lifecycle.updateActivity(activity, runningCapture: running && mode == .tuner), running || starting || engine != nil || retiringEngine != nil {
            stop(immediately: true)
        }
    }
    func selectProfile(_ selected: TunerProfile) {
        guard selected != profile else { return }
        profile = selected
        selected.save(to: .standard)
        vocalDisplay.reset()
        reading = .silence
        pitchProcessor?.setConfiguration(.production(profile: selected))
    }
    func changeMode() { stop(); status = "Ready"; route = "" }
    func updateFrequency() {
        guard mode == .tone else { return }
        guard ToneOutputPolicy.permits(frequency) else {
            if running { stop(message: ToneOutputPolicy.frequencyGuidance) }
            return // Preserve the requested Hz; never substitute a higher note.
        }
        renderer?.frequency.store(frequency.bitPattern, ordering: .relaxed)
    }
    func updateMetronome() {
        if !running { displayedBeatsPerBar = beatsPerBar }
        metronomeRenderer?.bpm.store(bpm.bitPattern, ordering: .relaxed)
        metronomeRenderer?.beatsPerBar.store(beatsPerBar, ordering: .relaxed)
        metronomeRenderer?.accentFirst.store(accentFirstBeat, ordering: .relaxed)
    }
    func start() {
        guard !starting, !running else { return }
        starting = true
        let token = lifecycle.beginStart()
        let selectedMode = mode
        status = selectedMode == .tuner ? "Requesting microphone…" : "Selecting audio route…"
        #if targetEnvironment(simulator)
        if selectedMode == .tuner, ProcessInfo.processInfo.arguments.contains("--synthetic-tuner") {
            startSyntheticTuner(token: token)
            return
        }
        #endif
        Task { [self] in
            await lifecycle.waitForShutdown()
            guard await lifecycle.waitForForeground(token: token), token == generation else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                if selectedMode == .tuner {
                    lifecycle.beginPrompt(token: token)
                    let permitted = await AVAudioApplication.requestRecordPermission()
                    switch lifecycle.finishPermission(token: token, granted: permitted) {
                    case .cancelled: return
                    case .denied:
                        starting = false
                        status = "Microphone denied. Allow access in Watch Settings → Privacy & Security → Microphone."
                        return
                    case .granted: break
                    }
                    guard await lifecycle.waitForForeground(token: token), token == generation else { return }
                    try session.setCategory(.record, mode: .measurement, policy: .default, options: [])
                } else {
                    try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                }
                lifecycle.beginPrompt(token: token)
                let request = Task { try await session.activate(options: []) }
                activation = request
                let activated = try await request.value
                lifecycle.endPrompt(token: token)
                guard token == generation else { return } // Stop owns the pending activation's cleanup.
                activation = nil
                guard activated else { throw AudioFailure.noRoute }
                sessionActive = true
                guard await lifecycle.waitForForeground(token: token), token == generation else { return }
                if selectedMode == .tone {
                    toneExternalOutput = hasExternalToneOutput(session)
                    guard ToneOutputPolicy.permits(frequency) else {
                        throw AudioFailure.invalidToneFrequency
                    }
                }
                let audio = AVAudioEngine()
                engine = audio
                if selectedMode == .tuner {
                    try installTunerTap(audio, token: token, largerTapAttempted: false)
                } else {
                    let output = audio.outputNode.inputFormat(forBus: 0)
                    guard output.sampleRate > 0, output.channelCount > 0,
                          !session.currentRoute.outputs.isEmpty else { throw AudioFailure.noRoute }
                    guard let mono = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1) else { throw AudioFailure.noRoute }
                    let rate = mono.sampleRate
                    let source: AVAudioSourceNode
                    if selectedMode == .metronome {
                        let render = MetronomeRenderer()
                        metronomeRenderer = render
                        updateMetronome()
                        source = AVAudioSourceNode(format: mono) { @Sendable [render, rate] _, _, frameCount, list in
                            render.render(frames: Int(frameCount), rate: rate,
                                          buffers: UnsafeMutableAudioBufferListPointer(list))
                            return noErr
                        }
                    } else {
                        let render = ToneRenderer()
                        render.frequency.store(frequency.bitPattern, ordering: .relaxed)
                        renderer = render
                        source = AVAudioSourceNode(format: mono) { @Sendable [render, rate] _, _, frameCount, list in
                            render.render(frames: Int(frameCount), rate: rate,
                                          buffers: UnsafeMutableAudioBufferListPointer(list))
                            return noErr
                        }
                    }
                    audio.attach(source)
                    audio.connect(source, to: audio.mainMixerNode, format: mono)
                }
                audio.prepare()
                try audio.start()
                running = true
                starting = false
                status = selectedMode == .tuner ? "Listening" : "Playing"
                updateRoute()
                activeRoute = routeState()
                if let metronomeRenderer { followBeats(metronomeRenderer, token: token) }
            } catch {
                guard token == generation else { return }
                stop(message: error.localizedDescription, immediately: true)
                starting = false
            }
        }
    }

    func stop(message: String = "Stopped", immediately: Bool = false) {
        lifecycle.cancelStart()
        starting = false
        running = false
        vocalDisplay.reset()
        reading = .silence
        beatUpdates?.cancel()
        beatUpdates = nil
        beatIndex = nil
        beatFlash = false
        displayedBeatsPerBar = beatsPerBar
        status = message
        activeRoute = nil
        // A second stop (for example wrist-down during the fade) stops the retiring engine now.
        if immediately { retiringEngine?.stop() }
        let audio = engine
        engine = nil
        pitchProcessor = nil
        #if targetEnvironment(simulator)
        syntheticInput?.cancel()
        syntheticInput = nil
        #endif
        let tone = renderer
        renderer = nil
        let metronome = metronomeRenderer
        metronomeRenderer = nil
        let wasActive = sessionActive
        sessionActive = false
        let pendingActivation = activation
        activation = nil
        tone?.enabled.store(false, ordering: .releasing)
        metronome?.enabled.store(false, ordering: .releasing)
        if inputTapped { audio?.inputNode.removeTap(onBus: 0); inputTapped = false }
        guard audio != nil || wasActive || pendingActivation != nil else { return }
        retiringEngine = audio
        if immediately || (tone == nil && metronome == nil) { audio?.stop() }
        lifecycle.enqueueShutdown { [self] in
            // A render acknowledgement ends the fade. The bounded fallback handles a stalled route.
            let deadline = ContinuousClock.now + .milliseconds(250)
            while audio?.isRunning == true,
                  !(tone?.quiet.load(ordering: .acquiring) ?? metronome?.quiet.load(ordering: .acquiring) ?? true),
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            audio?.stop()
            let didActivate = (try? await pendingActivation?.value) ?? false
            if wasActive || didActivate { await deactivateSessionNow() }
            if retiringEngine === audio { retiringEngine = nil }
        }
    }
    private func makePitchProcessor(token: Int, largerTapAttempted: Bool) -> PitchCaptureProcessor {
        captureSerial &+= 1
        let serial = captureSerial
        return PitchCaptureProcessor(configuration: .production(profile: profile), largerTapAttempted: largerTapAttempted) { [weak self] action in
            Task { @MainActor [weak self] in
                self?.recoverCaptureTiming(action, token: token, serial: serial)
            }
        }
    }
    private func installTunerTap(_ audio: AVAudioEngine, token: Int, largerTapAttempted: Bool) throws {
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate), format.channelCount > 0 else { throw AudioFailure.noMicrophone }
        let processor = makePitchProcessor(token: token, largerTapAttempted: largerTapAttempted)
        pitchProcessor = processor
        let size = largerTapAttempted ? CaptureTimingRecovery.windowFrames(sampleRate: format.sampleRate)
                                      : CaptureTimingRecovery.initialTapFrames(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(size), format: format) { @Sendable [weak self] buffer, time in
            processor.consumeVersioned(sampleRate: buffer.format.sampleRate,
                sampleTime: time.isSampleTimeValid && time.sampleRate == buffer.format.sampleRate ? time.sampleTime : nil,
                copySamples: {
                    guard let channel = buffer.floatChannelData?[0] else { return nil }
                    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                }) { [weak self] reading, revision in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.running,
                              self.pitchProcessor === processor, processor.revision == revision else { return }
                        self.reading = self.vocalDisplay.accept(reading, profile: self.profile,
                                                               at: ProcessInfo.processInfo.systemUptime)
                    }
                }
        }
        inputTapped = true
    }
    private func recoverCaptureTiming(_ action: CaptureTimingAction, token: Int, serial: UInt64) {
        guard generation == token, captureSerial == serial, running, mode == .tuner else { return }
        guard case .retryLargerTap = action else {
            stop(message: "Microphone timing unavailable. Tap Start to retry.", immediately: true)
            return
        }
        vocalDisplay.reset()
        reading = .unclear
        #if targetEnvironment(simulator)
        if syntheticInput != nil {
            pitchProcessor = makePitchProcessor(token: token, largerTapAttempted: true)
            if !ProcessInfo.processInfo.arguments.contains("--synthetic-ignore-larger-tap") {
                syntheticBufferSize = CaptureTimingRecovery.windowFrames(sampleRate: 48000)
            }
            status = "Listening • slower updates"
            return
        }
        #endif
        guard let audio = engine, activeRoute == routeState() else {
            stop(message: "Microphone route changed. Tap Start to resume.", immediately: true)
            return
        }
        // Synchronous main-actor transaction: no intervening Start/Stop, route task,
        // or profile edit can race the graph replacement. Only one tap exists.
        audio.stop()
        if inputTapped { audio.inputNode.removeTap(onBus: 0); inputTapped = false }
        pitchProcessor = nil
        do {
            try installTunerTap(audio, token: token, largerTapAttempted: true)
            audio.prepare()
            try audio.start()
            status = "Listening • slower updates"
        } catch { stop(message: error.localizedDescription, immediately: true) }
    }
    #if targetEnvironment(simulator)
    /// Explicit UI-test fixture. Compiled out of physical Watch builds; never opens
    /// the Mac microphone or changes permission. Uses the real shared pipeline.
    private func startSyntheticTuner(token: Int) {
        pitchProcessor = makePitchProcessor(token: token, largerTapAttempted: false)
        syntheticBufferSize = 1024
        syntheticInput = Task { [weak self] in
            guard let self else { return }
            await lifecycle.waitForShutdown()
            guard await lifecycle.waitForForeground(token: token), generation == token else { return }
            running = true; starting = false; status = "Listening"; route = "Synthetic test input"
            var position = 0, wristStage = 0
            let wristCycle = ProcessInfo.processInfo.arguments.contains("--synthetic-wrist-cycle")
            let unknownTimes = ProcessInfo.processInfo.arguments.contains("--synthetic-invalid-timestamps")
            let quietInput = ProcessInfo.processInfo.arguments.contains("--synthetic-quiet-input")
            while !Task.isCancelled, running, generation == token, let processor = pitchProcessor {
                let start = position, count = syntheticBufferSize
                let amplitude = quietInput ? 0.00003 : 0.3
                let hz = quietInput ? 440.0 : 220.0
                let samples: [Float] = (start..<start+count).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / 48000)) }
                processor.consumeVersioned(sampleRate: 48000, sampleTime: unknownTimes ? nil : Int64(start), copySamples: { samples }) { [weak self] result, revision in
                    Task { @MainActor [weak self] in
                        guard let self, self.running, self.generation == token,
                              self.pitchProcessor === processor, processor.revision == revision else { return }
                        self.reading = self.vocalDisplay.accept(result, profile: self.profile,
                                                               at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                position += count
                if wristCycle {
                    if wristStage == 0 && position >= 24000 { wristStage = 1; sceneChanged(.inactive) }
                    else if wristStage == 1 && position >= 48000 { wristStage = 2; sceneChanged(.background) }
                    else if wristStage == 2 && position >= 72000 {
                        wristStage = 3; sceneChanged(.active); status = "Listening • wrist cycle verified"
                    }
                }
                try? await Task.sleep(for: .milliseconds(Double(count) / 48))
            }
        }
    }
    #endif

    /// Display polling only; beat scheduling stays exclusively on the audio sample clock.
    private func followBeats(_ render: MetronomeRenderer, token: Int) {
        beatUpdates = Task { [weak self] in
            var lastSnapshot: UInt64 = 0
            var lastBeatTime: UInt64 = 0
            while !Task.isCancelled {
                guard let self, self.running, self.generation == token else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let snapshot = render.beatState.load(ordering: .acquiring)
                if snapshot != 0 && snapshot != lastSnapshot {
                    lastSnapshot = snapshot
                    lastBeatTime = now
                    self.displayedBeatsPerBar = Int((snapshot >> 8) & 255)
                    self.beatIndex = Int(snapshot & 255) - 1
                }
                self.beatFlash = lastSnapshot != 0 && now - lastBeatTime < 120_000_000
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
    private func deactivateSessionNow() async {
        let session = AVAudioSession.sharedInstance()
        if #available(watchOS 27.0, *) {
            _ = try? await session.deactivate(options: [])
        } else {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    try? session.setActive(false)
                    continuation.resume()
                }
            }
        }
    }
    private func routeState() -> AudioRouteState {
        let session = AVAudioSession.sharedInstance()
        return AudioRouteState(inputIDs: session.currentRoute.inputs.map(\.uid),
                               outputIDs: session.currentRoute.outputs.map(\.uid),
                               sampleRate: session.sampleRate,
                               inputChannels: session.inputNumberOfChannels,
                               outputChannels: session.outputNumberOfChannels)
    }
    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        if mode == .tone { toneExternalOutput = hasExternalToneOutput(session) }
        let ports = mode == .tuner ? session.currentRoute.inputs : session.currentRoute.outputs
        route = ports.map {
            guard $0.portType == .builtInSpeaker else { return $0.portName }
            #if targetEnvironment(simulator)
            return "Simulator output (Mac)"
            #else
            return "Watch speaker"
            #endif
        }.joined(separator: ", ")
    }
    private func hasExternalToneOutput(_ session: AVAudioSession) -> Bool {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-low-watch-tone") { return false }
        #endif
        return !session.currentRoute.outputs.isEmpty && session.currentRoute.outputs.allSatisfy { $0.portType != .builtInSpeaker }
    }
    private enum AudioFailure: LocalizedError {
        case noRoute, noMicrophone, invalidToneFrequency
        var errorDescription: String? {
            switch self {
            case .noRoute: "No audio output. Off charger, try Watch speaker or connect Bluetooth audio."
            case .noMicrophone: "Microphone unavailable. Try again when other audio has stopped."
            case .invalidToneFrequency: ToneOutputPolicy.frequencyGuidance
            }
        }
    }
}
