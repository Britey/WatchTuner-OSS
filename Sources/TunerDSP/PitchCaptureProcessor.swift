import Foundation
import Dispatch
import Synchronization

public struct PitchFrame: Sendable {
    public let samples: [Float]?
    public let discontinuity: Bool
}

/// A frame may span buffers only when their sample timestamps and formats agree.
/// Missing timestamps permit single-buffer frames, but never cross-buffer splicing.
public struct ContiguousPitchFrames: Sendable {
    private var accumulated: [Float] = []
    private var rate: Double?
    private var expectedSampleTime: Int64?
    private let overlapping: Bool
    public init(overlapping: Bool = false) { self.overlapping = overlapping }

    public mutating func append(_ samples: [Float], sampleRate: Double,
                                sampleTime: Int64?, droppedBefore: Bool = false) -> PitchFrame {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite }) else {
            accumulated.removeAll(keepingCapacity: true)
            rate = nil
            expectedSampleTime = nil
            return PitchFrame(samples: nil, discontinuity: true)
        }
        let contiguous = !droppedBefore && rate == sampleRate && sampleTime != nil
            && sampleTime == expectedSampleTime
        let gap = droppedBefore || sampleTime == nil || (rate != nil && !contiguous)
        if !contiguous { accumulated.removeAll(keepingCapacity: true) }
        rate = sampleRate
        if let sampleTime {
            let (end, overflow) = sampleTime.addingReportingOverflow(Int64(samples.count))
            expectedSampleTime = overflow ? nil : end
        } else {
            expectedSampleTime = nil
        }
        accumulated.append(contentsOf: samples)
        let size = CaptureTimingRecovery.windowFrames(sampleRate: sampleRate)
        guard accumulated.count >= size else { return PitchFrame(samples: nil, discontinuity: gap) }
        let frame = Array(accumulated.suffix(size))
        if overlapping && sampleTime != nil {
            accumulated = Array(frame.suffix(max(0, size - Int(sampleRate * 0.02))))
        } else { accumulated.removeAll(keepingCapacity: true) }
        return PitchFrame(samples: frame, discontinuity: gap)
    }
}

/// The app and deterministic host tests use this same bounded admission/worker path.
/// copySamples is called synchronously only after admission. Capture assembly and
/// analysis have separate one-deep gates; a slow analysis cannot block tap admission.
public final class PitchCaptureProcessor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let gate = DispatchSemaphore(value: 1)
    private let dropped = Atomic<Bool>(false)
    private var frames = ContiguousPitchFrames()
    private let analysisQueue: DispatchQueue
    private let analysisGate = DispatchSemaphore(value: 1)
    private let epoch = Atomic<UInt64>(0)
    private var timingRecovery: CaptureTimingRecovery
    private let timingAction: @Sendable (CaptureTimingAction) -> Void
    private var lastSampleRate: Double?
    private let configuration: Atomic<UInt64>
    private let configurationLock = NSLock() // UI/configuration only, never the tap callback.
    private var captureConfiguration: UInt64
    private var trackerEpoch: UInt64 = .max
    private var trackerConfiguration: UInt64 = .max
    private var tracker = PitchTracker(profile: .guitar) // analysis queue only
    public var revision: UInt64 { configuration.load(ordering: .acquiring) }

    public func setConfiguration(_ selected: PitchConfiguration) {
        configurationLock.lock(); defer { configurationLock.unlock() }
        configuration.store(((revision & ~15) &+ 16) | selected.code, ordering: .releasing)
    }

    public func setProfile(_ profile: TunerProfile) {
        configurationLock.lock(); defer { configurationLock.unlock() }
        let next = ((revision & ~15) &+ 16) | (revision & 12) | profile.code
        configuration.store(next, ordering: .releasing)
    }

    public func setAlgorithm(_ algorithm: PitchAlgorithm) {
        configurationLock.lock(); defer { configurationLock.unlock() }
        let next = ((revision & ~15) &+ 16) | (revision & 3) | (algorithm.code << 2)
        configuration.store(next, ordering: .releasing)
    }

    /// Algorithm selection is required: historical tests use `.current`, while the app
    /// and production regressions use `init(configuration: .production(profile:))`.
    public init(profile: TunerProfile = .guitar, algorithm: PitchAlgorithm, largerTapAttempted: Bool = false,
                timingAction: @escaping @Sendable (CaptureTimingAction) -> Void = { _ in }, queue: DispatchQueue = DispatchQueue(label: "WatchTuner.capture", qos: .userInitiated),
                analysisQueue: DispatchQueue = DispatchQueue(label: "WatchTuner.analysis", qos: .userInitiated)) {
        self.queue = queue
        self.timingRecovery = CaptureTimingRecovery(largerTapAttempted: largerTapAttempted)
        self.timingAction = timingAction
        self.analysisQueue = analysisQueue
        configuration = Atomic(profile.code | (algorithm.code << 2))
        captureConfiguration = profile.code | (algorithm.code << 2)
        frames = ContiguousPitchFrames(overlapping: profile != .guitar)
    }

    /// The app and its integration regressions enter through the same named policy.
    public convenience init(configuration: PitchConfiguration, largerTapAttempted: Bool = false,
                timingAction: @escaping @Sendable (CaptureTimingAction) -> Void = { _ in },
                queue: DispatchQueue = DispatchQueue(label: "WatchTuner.capture", qos: .userInitiated),
                analysisQueue: DispatchQueue = DispatchQueue(label: "WatchTuner.analysis", qos: .userInitiated)) {
        self.init(profile: configuration.profile, algorithm: configuration.algorithm,
                  largerTapAttempted: largerTapAttempted, timingAction: timingAction,
                  queue: queue, analysisQueue: analysisQueue)
    }

    public func consume(sampleRate: Double, sampleTime: Int64?, copySamples: () -> [Float]?,
                        report: @escaping @Sendable (PitchReading) -> Void) {
        consumeVersioned(sampleRate: sampleRate, sampleTime: sampleTime, copySamples: copySamples) { reading, _ in report(reading) }
    }
    public func consumeVersioned(sampleRate: Double, sampleTime: Int64?, copySamples: () -> [Float]?,
                                 report: @escaping @Sendable (PitchReading, UInt64) -> Void) {
        guard gate.wait(timeout: .now()) == .success else {
            dropped.store(true, ordering: .releasing)
            return
        }
        // Bind this admitted copy to its configuration before copying samples.
        // A UI edit must never relabel queued old audio with a newer revision.
        let settings = revision
        let gap = dropped.exchange(false, ordering: .acquiringAndReleasing)
        let samples = copySamples()
        if samples == nil { dropped.store(true, ordering: .releasing) }
        queue.async { [self] in
            defer { gate.signal() }
            // Reject before timing recovery or frame assembly can consume it.
            guard revision == settings else { return }
            if let samples, samples.allSatisfy(\.isFinite),
               let action = timingRecovery.observe(sampleRate: sampleRate, frameCount: samples.count, timestampValid: sampleTime != nil) {
                timingAction(action)
            }
            let profile = TunerProfile(code: settings & 3)
            let algorithm = PitchAlgorithm(code: (settings >> 2) & 3)
            if settings != captureConfiguration {
                captureConfiguration = settings
                frames = ContiguousPitchFrames(overlapping: profile != .guitar)
                lastSampleRate = nil
                epoch.store(epoch.load(ordering: .relaxed) &+ 1, ordering: .releasing)
            }
            let frame = frames.append(samples ?? [], sampleRate: sampleRate, sampleTime: sampleTime, droppedBefore: gap || samples == nil)
            let rateChanged = lastSampleRate != nil && lastSampleRate != sampleRate
            lastSampleRate = sampleRate
            let invalidates = frame.discontinuity && (frame.samples == nil || sampleTime != nil || gap || rateChanged)
            if invalidates {
                epoch.store(epoch.load(ordering: .relaxed) &+ 1, ordering: .releasing)
                report(.unclear, settings)
            }
            if let samples = frame.samples {
                // Skip complete analysis windows under load, never tap samples needed
                // to assemble a contiguous window. There is no unbounded work queue.
                guard analysisGate.wait(timeout: .now()) == .success else { return }
                let token = epoch.load(ordering: .acquiring)
                analysisQueue.async { [self] in
                    if trackerConfiguration != settings || trackerEpoch != token {
                        tracker = PitchTracker(profile: profile)
                        trackerConfiguration = settings
                        trackerEpoch = token
                    }
                    let reading = tracker.accept(algorithm.analyze(samples, sampleRate: sampleRate, profile: profile))
                    queue.async { [self] in
                        defer { analysisGate.signal() }
                        guard epoch.load(ordering: .acquiring) == token, revision == settings else { return }
                        report(reading, settings)
                    }
                }
            } else if frame.discontinuity && !invalidates {
                report(.unclear, settings)
            }
        }
    }
}
