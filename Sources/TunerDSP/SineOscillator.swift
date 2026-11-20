import Foundation

/// Validate the oscillator's range without inferring a speaker response cutoff.
/// Acoustic limitations are guidance; playback always retains the requested Hz.
public enum ToneOutputPolicy {
    public static func permits(_ frequency: Double) -> Bool {
        frequency.isFinite && (20...8000).contains(frequency)
    }
    public static let speakerGuidance = "Low tones may be weak or inaudible on Watch. Try Bluetooth audio."
    public static let frequencyGuidance = "Choose a frequency from 20 to 8000 Hz."
}

/// Owned exclusively by the audio render callback. Targets are passed once per buffer.
public struct SineOscillator: Sendable {
    public private(set) var phase = 0.0
    public private(set) var frequency = 440.0
    public private(set) var amplitude = 0.0
    public init() {}
    public mutating func next(sampleRate: Double, targetHz: Double, targetAmplitude: Double) -> Float {
        guard sampleRate.isFinite, sampleRate > 0, targetHz.isFinite, targetAmplitude.isFinite else { return 0 }
        let hz = min(sampleRate * 0.45, max(20, min(8000, targetHz)))
        let gain = max(0, min(0.15, targetAmplitude))
        // 10 ms smoothing, phase never resets during frequency changes.
        let coefficient = 1 - exp(-1 / (sampleRate * 0.01))
        frequency += (hz - frequency) * coefficient
        amplitude += (gain - amplitude) * coefficient
        let sample = Float(sin(phase) * amplitude)
        phase += 2 * .pi * frequency / sampleRate
        phase.formTruncatingRemainder(dividingBy: 2 * .pi)
        return sample
    }
}

/// Gesture-level Crown dead zone. Input is the normalized continuous SwiftUI Crown axis,
/// not Hz; small isolated bumps never accumulate across idle or direction changes.
public struct ToneCrownFilter: Sendable {
    public static let activationDistance = 0.4
    public static let stepDistance = 0.1
    private var pending = 0.0
    private var direction = 0.0
    private var engaged = false
    private var lastTime: Double?
    public init() {}
    public mutating func reset() { pending = 0; direction = 0; engaged = false; lastTime = nil }
    public mutating func turn(delta: Double, frequency: Double, at time: Double) -> Double? {
        guard delta.isFinite, frequency.isFinite, time.isFinite else { reset(); return nil }
        guard delta != 0 else { return nil }
        let sign = delta > 0 ? 1.0 : -1.0
        if direction != sign || lastTime.map({ time <= $0 || time - $0 > 0.25 }) == true { reset() }
        direction = sign; lastTime = time
        pending += abs(delta)
        var steps = 0.0
        if !engaged {
            guard pending + 1e-12 >= Self.activationDistance else { return nil }
            pending = max(0, pending - Self.activationDistance)
            engaged = true
            steps = 1
        }
        let additional = floor((pending + 1e-12) / Self.stepDistance)
        pending = max(0, pending - additional * Self.stepDistance)
        steps += additional
        guard steps > 0 else { return nil }
        return min(8000, max(20, frequency + sign * steps * 10))
    }
}
