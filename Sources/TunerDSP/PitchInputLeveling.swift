import Foundation

public enum PitchReading: Equatable, Sendable {
    case silence, unclear, clipped
    case pitch(hz: Double, confidence: Double)
}

enum LeveledPitchInput {
    case invalid, silence, clipped
    case ready(samples: [Float], inputRMS: Double, gain: Double)
}

/// Analysis-only automatic level adjustment. A single linear gain per window
/// preserves waveform shape and SNR; it is neither microphone gain nor denoising.
/// Tonal structure, rather than a minimum recording volume, decides pitch validity.
struct PitchInputLeveling {
    static func prepare(_ samples: [Float]) -> LeveledPitchInput {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return .invalid }
        var railSamples = 0, plateau = 0, longestPlateau = 0
        var previous: Float?
        for value in samples {
            if abs(value) >= 0.99999 {
                railSamples += 1
                plateau = value == previous ? plateau + 1 : 1
                longestPlateau = max(longestPlateau, plateau)
            } else { plateau = 0 }
            previous = value
        }
        // Near-full-scale amplitude alone is not clipping. Require repeated flat
        // rail samples as well. This is a digital overload heuristic, never dB SPL.
        if railSamples > samples.count / 100 && longestPlateau >= 3 { return .clipped }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let centered = samples.map { Double($0) - mean }
        let rms = sqrt(centered.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        // Numerical zero only (-180 dBFS), not an acoustic or ambient-noise gate.
        guard rms > 1e-9 else { return .silence }
        let peak = centered.reduce(0.0) { max($0, abs($1)) }
        let gain = min(4096, min(0.12 / rms, 0.8 / peak))
        return .ready(samples: centered.map { Float($0 * gain) }, inputRMS: rms, gain: gain)
    }
}
