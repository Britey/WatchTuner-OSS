import SwiftUI
import AVFAudio
import UIKit
import Synchronization

/// Only the render callback touches oscillator. UI communicates through lock-free atomics.
private final class IOSToneRenderer: @unchecked Sendable {
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
                // through the host's speakers. Physical iPhone/iPad output is unchanged.
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
private final class IOSMetronomeRenderer: @unchecked Sendable {
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

@MainActor final class IOSAudioController: ObservableObject {
    enum Mode: String, CaseIterable { case tuner = "Tuner", tone = "Tone", metronome = "Metro" }
    @Published var mode: Mode = .tuner
    @Published private(set) var profile: TunerProfile
    private var pitchProcessor: PitchCaptureProcessor?
    private var vocalDisplay = VocalDisplaySmoother()
    private var captureSerial: UInt64 = 0
    @Published var frequency = 440.0
    @Published private(set) var toneExternalOutput = false
    @Published private(set) var microphonePermissionDenied = false
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
    private var renderer: IOSToneRenderer?
    private var metronomeRenderer: IOSMetronomeRenderer?
    private var playbackSampleRate: Double?
    private var beatUpdates: Task<Void, Never>?
    private var inputTapped = false
    private var sessionActive = false
    private let lifecycle = AudioLifecycle()
    private var generation: Int { lifecycle.generation }
    private var activation: Task<Bool, Error>?
    private var retiringEngine: AVAudioEngine?
    private var activeRoute: AudioRouteState?
    private let observers = IOSAudioObservers()
    private var audioObjects = IOSAudioObjectLifetime()
    private var mediaServicesAvailable = true

    init() {
        profile = TunerProfile.load(from: .standard)
        let center = NotificationCenter.default
        observers.tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.running || self.starting else { return }
                self.stop(message: "Audio interrupted. Tap Start to resume.", immediately: true)
            }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // queue.main is synchronous: invalidate before any queued fade,
                // activation continuation or graph-recovery task can run again.
                MainActor.assumeIsolated {
                    self?.mediaServicesChanged(available: name == AVAudioSession.mediaServicesWereResetNotification)
                }
            })
        }
        observers.tokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            let changedEngine = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, self.audioObjects.isValid, self.running || self.starting,
                      let engine = self.engine, changedEngine == ObjectIdentifier(engine),
                      !engine.isRunning else { return }
                self.stop(message: "Audio configuration changed. Tap Start to resume.", immediately: true)
            }
        })
        observers.tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.mediaServicesAvailable, self.audioObjects.isValid else { return }
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

    /// Inactive includes Control Center and transient overlays. Only background
    /// ends engaged audio; a pending start still waits until the scene is active.
    func sceneChanged(_ activity: AudioActivity) {
        let engaged = running || starting || engine != nil || retiringEngine != nil
        let preserve = IOSAudioScenePolicy.preservesEngagedAudio(isBackground: activity == .background, engaged: engaged)
        if lifecycle.updateActivity(activity, runningCapture: preserve), engaged {
            stop(immediately: true)
        }
    }
    private func mediaServicesChanged(available: Bool) {
        audioObjects.invalidate()
        mediaServicesAvailable = available
        route = ""
        toneExternalOutput = false
        // Stop clears state and fences pending session calls. Its invalid lease
        // prevents all access to the now-orphaned engine, including retiring ones.
        stop(message: available ? "Audio services reset. Tap Start to resume."
                                : "Audio services unavailable. Wait, then tap Start.", immediately: true)
        if available { audioObjects = IOSAudioObjectLifetime() }
    }
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
        if let rate = playbackSampleRate, frequency > rate * 0.45 {
            stop(message: AudioFailure.unsupportedToneForRoute.localizedDescription, immediately: true)
            return
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
        guard mediaServicesAvailable, audioObjects.isValid else {
            status = "Audio services unavailable. Wait, then tap Start."
            return
        }
        guard lifecycle.activity == .active else {
            status = "Open the app to start audio."
            return
        }
        starting = true
        let token = lifecycle.beginStart()
        let selectedMode = mode
        let objects = audioObjects
        status = selectedMode == .tuner ? "Requesting microphone…" : "Selecting audio route…"
        Task { [self] in
            await lifecycle.waitForShutdown()
            guard await lifecycle.waitForForeground(token: token), token == generation, objects.isValid else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                if selectedMode == .tuner {
                    lifecycle.beginPrompt(token: token)
                    let permitted = await AVAudioApplication.requestRecordPermission()
                    switch lifecycle.finishPermission(token: token, granted: permitted) {
                    case .cancelled: return
                    case .denied:
                        starting = false
                        microphonePermissionDenied = true
                        status = "Microphone access is off. Open Settings and allow Microphone, then tap Start."
                        return
                    case .granted:
                        microphonePermissionDenied = false
                    }
                    guard await lifecycle.waitForForeground(token: token), token == generation, objects.isValid else { return }
                    try session.setCategory(.record, mode: .measurement, options: [])
                } else {
                    try session.setCategory(.playback, mode: .default, options: [])
                }
                // Audio calls can synchronously deliver a main-queue reset.
                guard token == generation, objects.isValid else { return }
                lifecycle.beginPrompt(token: token)
                let request = Task { try await Self.activateSession(lifetime: objects) }
                activation = request
                let activated = try await request.value
                lifecycle.endPrompt(token: token)
                guard token == generation, objects.isValid else { return } // Stop owns the pending activation's cleanup.
                activation = nil
                guard activated else { throw AudioFailure.noRoute }
                sessionActive = true
                guard await lifecycle.waitForForeground(token: token), token == generation, objects.isValid else { return }
                if selectedMode == .tone {
                    let external = hasExternalToneOutput(session)
                    guard token == generation, objects.isValid else { return }
                    toneExternalOutput = external
                    guard ToneOutputPolicy.permits(frequency) else {
                        throw AudioFailure.invalidToneFrequency
                    }
                }
                let audio = AVAudioEngine()
                guard token == generation, objects.isValid else { return }
                engine = audio
                if selectedMode == .tuner {
                    let format = try liveInputFormat(audio)
                    guard token == generation, objects.isValid else { return }
                    try installTunerTap(audio, format: format, token: token, largerTapAttempted: false)
                } else {
                    let outputNode = audio.outputNode
                    guard token == generation, objects.isValid else { return }
                    let output = outputNode.inputFormat(forBus: 0)
                    guard token == generation, objects.isValid else { return }
                    guard output.sampleRate.isFinite, (8000...192000).contains(output.sampleRate), output.channelCount > 0,
                          !session.currentRoute.outputs.isEmpty else { throw AudioFailure.noRoute }
                    guard token == generation, objects.isValid else { return }
                    guard let mono = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1) else { throw AudioFailure.noRoute }
                    guard token == generation, objects.isValid else { return }
                    let rate = mono.sampleRate
                    if selectedMode == .tone, frequency > rate * 0.45 {
                        // The shared oscillator bounds frequencies near Nyquist.
                        // Refuse this route rather than silently changing requested Hz.
                        throw AudioFailure.unsupportedToneForRoute
                    }
                    playbackSampleRate = rate
                    let source: AVAudioSourceNode
                    if selectedMode == .metronome {
                        let render = IOSMetronomeRenderer()
                        metronomeRenderer = render
                        updateMetronome()
                        source = AVAudioSourceNode(format: mono) { @Sendable [render, rate] _, _, frameCount, list in
                            render.render(frames: Int(frameCount), rate: rate,
                                          buffers: UnsafeMutableAudioBufferListPointer(list))
                            return noErr
                        }
                    } else {
                        let render = IOSToneRenderer()
                        render.frequency.store(frequency.bitPattern, ordering: .relaxed)
                        renderer = render
                        source = AVAudioSourceNode(format: mono) { @Sendable [render, rate] _, _, frameCount, list in
                            render.render(frames: Int(frameCount), rate: rate,
                                          buffers: UnsafeMutableAudioBufferListPointer(list))
                            return noErr
                        }
                    }
                    guard token == generation, objects.isValid else { return }
                    audio.attach(source)
                    guard token == generation, objects.isValid else { return }
                    let mixer = audio.mainMixerNode
                    guard token == generation, objects.isValid else { return }
                    audio.connect(source, to: mixer, format: mono)
                }
                guard token == generation, objects.isValid else { return }
                audio.prepare()
                guard token == generation, objects.isValid else { return }
                try audio.start()
                guard token == generation, objects.isValid else { return }
                running = true
                starting = false
                status = selectedMode == .tuner ? "Listening" : "Playing"
                updateRoute()
                guard token == generation, objects.isValid else { return }
                let currentRoute = routeState()
                guard token == generation, objects.isValid else { return }
                activeRoute = currentRoute
                if let metronomeRenderer { followBeats(metronomeRenderer, token: token) }
            } catch {
                guard token == generation, objects.isValid else { return }
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
        let objects = audioObjects
        if !objects.isValid { retiringEngine = nil }
        // A second stop during a fade may stop only a still-valid engine.
        if immediately { objects.performIfValid { retiringEngine?.stop() } }
        let audio = engine
        engine = nil
        playbackSampleRate = nil
        pitchProcessor = nil
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
        if inputTapped {
            if let audio, let input = objects.performIfValid({ audio.inputNode }) {
                objects.performIfValid { input.removeTap(onBus: 0) }
            }
            inputTapped = false
        }
        guard audio != nil || wasActive || pendingActivation != nil else { return }
        retiringEngine = objects.isValid ? audio : nil
        if immediately || (tone == nil && metronome == nil) {
            objects.performIfValid { audio?.stop() }
        }
        lifecycle.enqueueShutdown { [self] in
            await objects.finishShutdown(
                wasActive: wasActive,
                isRunning: { audio?.isRunning == true },
                isQuiet: { tone?.quiet.load(ordering: .acquiring) ?? metronome?.quiet.load(ordering: .acquiring) ?? true },
                stop: { audio?.stop() },
                awaitActivation: { (try? await pendingActivation?.value) ?? false },
                deactivate: { await self.deactivateSessionNow(lifetime: objects) })
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
    private func liveInputFormat(_ audio: AVAudioEngine) throws -> AVAudioFormat {
        let objects = audioObjects
        guard objects.isValid else { throw CancellationError() }
        let input = audio.inputNode
        guard objects.isValid else { throw CancellationError() }
        let format = input.outputFormat(forBus: 0)
        guard objects.isValid else { throw CancellationError() }
        guard format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate), format.channelCount > 0 else { throw AudioFailure.noMicrophone }
        return format
    }
    private func installTunerTap(_ audio: AVAudioEngine, format: AVAudioFormat, token: Int, largerTapAttempted: Bool) throws {
        let objects = audioObjects
        guard token == generation, objects.isValid else { throw CancellationError() }
        let input = audio.inputNode
        guard token == generation, objects.isValid else { throw CancellationError() }
        let processor = makePitchProcessor(token: token, largerTapAttempted: largerTapAttempted)
        pitchProcessor = processor
        let size = largerTapAttempted ? CaptureTimingRecovery.windowFrames(sampleRate: format.sampleRate)
                                      : CaptureTimingRecovery.initialTapFrames(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(size), format: format) { @Sendable [weak self] buffer, time in
            guard objects.isValid else { return }
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
        guard token == generation, objects.isValid else { throw CancellationError() }
        inputTapped = true
    }
    private func recoverCaptureTiming(_ action: CaptureTimingAction, token: Int, serial: UInt64) {
        guard generation == token, captureSerial == serial, running, mode == .tuner, audioObjects.isValid else { return }
        guard case .retryLargerTap = action else {
            stop(message: "Microphone timing unavailable. Tap Start to retry.", immediately: true)
            return
        }
        vocalDisplay.reset()
        reading = .unclear
        let objects = audioObjects
        let currentRoute = routeState()
        guard token == generation, objects.isValid else { return }
        guard let audio = engine, activeRoute == currentRoute else {
            stop(message: "Microphone route changed. Tap Start to resume.", immediately: true)
            return
        }
        // Snapshot and validate while hardware is live. A stopped input-node
        // format may be unavailable; replacement uses this captured format.
        // Check again after each audio call in case it delivers a reset itself.
        do {
            guard token == generation, objects.isValid else { return }
            let format = try liveInputFormat(audio)
            guard token == generation, objects.isValid else { return }
            audio.stop()
            guard token == generation, objects.isValid else { return }
            if inputTapped {
                let input = audio.inputNode
                guard token == generation, objects.isValid else { return }
                input.removeTap(onBus: 0)
                guard token == generation, objects.isValid else { return }
                inputTapped = false
            }
            pitchProcessor = nil
            try installTunerTap(audio, format: format, token: token, largerTapAttempted: true)
            guard token == generation, objects.isValid else { return }
            audio.prepare()
            guard token == generation, objects.isValid else { return }
            try audio.start()
            guard token == generation, objects.isValid else { return }
            status = "Listening • slower updates"
        } catch {
            guard token == generation, objects.isValid else { return }
            stop(message: error.localizedDescription, immediately: true)
        }
    }
    /// Display polling only; beat scheduling stays exclusively on the audio sample clock.
    private func followBeats(_ render: IOSMetronomeRenderer, token: Int) {
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
    // iOS setActive is synchronous and can block on system audio arbitration.
    // Keep it off the main actor, retain its result, and let ordered Stop cleanup
    // await a late activation before any subsequent Start configures the session.
    nonisolated private static func activateSession(lifetime: IOSAudioObjectLifetime) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let activated = try lifetime.performIfValid {
                        try AVAudioSession.sharedInstance().setActive(true)
                        return true
                    } ?? false
                    continuation.resume(returning: activated)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func deactivateSessionNow(lifetime: IOSAudioObjectLifetime) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                lifetime.performIfValid {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                continuation.resume()
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
            return "Simulator output (muted)"
            #else
            return UIDevice.current.userInterfaceIdiom == .pad ? "iPad speaker" : "iPhone speaker"
            #endif
        }.joined(separator: ", ")
    }
    private func hasExternalToneOutput(_ session: AVAudioSession) -> Bool {
        return !session.currentRoute.outputs.isEmpty && session.currentRoute.outputs.allSatisfy { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
    }
    private enum AudioFailure: LocalizedError {
        case noRoute, noMicrophone, invalidToneFrequency, unsupportedToneForRoute
        var errorDescription: String? {
            switch self {
            case .noRoute: "No audio output available. Check the audio route, then tap Start."
            case .noMicrophone: "Microphone unavailable. Try again when other audio has stopped."
            case .invalidToneFrequency: ToneOutputPolicy.frequencyGuidance
            case .unsupportedToneForRoute: "This audio route cannot generate the selected frequency. Choose a lower frequency or another output."
            }
        }
    }
}

/// Tokens are owned by the controller and removed together if its view is released.
private final class IOSAudioObservers {
    var tokens: [NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
