import Foundation

public enum TunerProfile: String, CaseIterable, Sendable {
    case vocals = "Vocals", piano = "Piano", guitar = "Guitar"
    public static let preferenceKey = "tunerProfile"
    public var code: UInt64 { switch self { case .vocals: 0; case .piano: 1; case .guitar: 2 } }
    public init(code: UInt64) { self = code == 1 ? .piano : code == 2 ? .guitar : .vocals }
    public var minimumHz: Double { switch self { case .vocals: 40; case .piano: 27.5; case .guitar: 55 } }
    public var maximumHz: Double { self == .piano ? 4200 : 2000 }
    public var guidance: String {
        switch self {
        case .vocals: "Sing one voice. The display gently averages vocal pitch; breath or consonants may show no clear pitch."
        case .piano: "Play one key after its attack. Equal-tempered reference; no chord or piano stretch-tuning system."
        case .guitar: "Play one string and mute the others. Weak or missing roots can select another octave."
        }
    }
    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .vocals
    }
    public func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}

/// One explicit configuration shared by the Watch app and production-path tests.
/// Historical detector tests must name their algorithm instead of relying on this policy.
public struct PitchConfiguration: Sendable, Equatable {
    public let profile: TunerProfile
    public let algorithm: PitchAlgorithm
    public init(profile: TunerProfile, algorithm: PitchAlgorithm) {
        self.profile = profile
        self.algorithm = algorithm
    }
    public static func production(profile: TunerProfile) -> Self {
        // Use the Pitchy estimator for every production profile.
        Self(profile: profile, algorithm: .mcleod)
    }
    var code: UInt64 { profile.code | (algorithm.code << 2) }
}

/// Display-only log-frequency averaging. The detector and its voicing/root
/// decisions retain raw estimates. Silence or uncertainty clears immediately.
public struct VocalDisplaySmoother: Sendable {
    private var logFrequency: Double?
    private var lastTime: Double?
    public init() {}
    public mutating func reset() { logFrequency = nil; lastTime = nil }
    public mutating func accept(_ reading: PitchReading, profile: TunerProfile, at time: Double) -> PitchReading {
        guard profile == .vocals else { reset(); return reading }
        guard case let .pitch(hz, confidence) = reading else { reset(); return reading }
        guard hz.isFinite, hz > 0, confidence.isFinite, time.isFinite else { reset(); return .unclear }
        let current = log2(hz)
        defer { self.lastTime = time }
        guard let previous = logFrequency, let previousTime = lastTime, time > previousTime, time - previousTime <= 0.5 else {
            logFrequency = current
            return reading
        }
        // About 220 ms for steady-note fluctuations. Larger musical movements
        // use a faster 60 ms response rather than dragging through the old note.
        let seconds = abs(current - previous) * 1200 > 150 ? 0.06 : 0.22
        let amount = 1 - exp(-(time - previousTime) / seconds)
        let smoothed = previous + amount * (current - previous)
        logFrequency = smoothed
        return .pitch(hz: pow(2, smoothed), confidence: confidence)
    }
}

/// Confirmation only: never averages Hz, quantizes notes or holds a stale reading.
/// Two agreeing frames acquire voice/piano; one-frame octave excursions clear the
/// display, and a sustained real octave change is accepted on the second frame.
public struct PitchTracker: Sendable {
    public let profile: TunerProfile
    private var lastHz: Double?
    private var pendingHz: Double?
    public init(profile: TunerProfile) { self.profile = profile }
    public mutating func reset() { lastHz = nil; pendingHz = nil }
    public mutating func accept(_ reading: PitchReading) -> PitchReading {
        guard case let .pitch(hz, _) = reading else { reset(); return reading }
        guard profile != .guitar else { return reading }
        let cents = lastHz.map { abs(1200 * log2(hz / $0)) }
        if lastHz == nil || cents.map({ abs($0 - 1200) < 100 }) == true {
            if let pendingHz, abs(1200 * log2(hz / pendingHz)) < 200 {
                self.pendingHz = nil; lastHz = hz; return reading
            }
            pendingHz = hz
            return .unclear
        }
        pendingHz = nil; lastHz = hz
        return reading
    }
}
