import Foundation

struct SpectralPeak: Sendable {
    let hz: Double
    let power: Double
}

/// Hann-windowed, zero-padded radix-2 FFT. All storage is bounded and worker-owned.
/// Peaks seed harmonic models; the strongest peak alone is never the pitch result.
struct SpectrumEstimate {
    let peaks: [SpectralPeak]
    let broadbandNoiseFraction: Double
}

struct HarmonicSpectrum {
    static func peaks(_ samples: [Double], sampleRate: Double) -> [SpectralPeak] {
        analyze(samples, sampleRate: sampleRate).peaks
    }
    static func analyze(_ samples: [Double], sampleRate: Double, suppressBroadbandNoise: Bool = false) -> SpectrumEstimate {
        let count = samples.count
        var size = 1
        while size < count * 4 { size *= 2 }
        var real = [Double](repeating: 0, count: size)
        var imaginary = real
        var weightSum = 0.0, energy = 0.0
        for i in 0..<count {
            let weight = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(count - 1))
            real[i] = samples[i] * weight
            weightSum += weight
            energy += samples[i] * samples[i] * weight
        }
        let normalization = weightSum * energy
        guard normalization > 0 else { return SpectrumEstimate(peaks: [], broadbandNoiseFraction: 1) }
        var reversed = 0
        for i in 1..<size {
            var bit = size >> 1
            while reversed & bit != 0 { reversed ^= bit; bit >>= 1 }
            reversed ^= bit
            if i < reversed { real.swapAt(i, reversed); imaginary.swapAt(i, reversed) }
        }
        var length = 2
        while length <= size {
            let angle = -2 * Double.pi / Double(length)
            let cosine = cos(angle), sine = sin(angle)
            for start in stride(from: 0, to: size, by: length) {
                var c = 1.0, s = 0.0
                for offset in 0..<(length / 2) {
                    let even = start + offset, odd = even + length / 2
                    let r = real[odd] * c - imaginary[odd] * s
                    let im = real[odd] * s + imaginary[odd] * c
                    real[odd] = real[even] - r; imaginary[odd] = imaginary[even] - im
                    real[even] += r; imaginary[even] += im
                    let nextC = c * cosine - s * sine
                    s = s * cosine + c * sine; c = nextC
                }
            }
            length *= 2
        }
        let powers = (0...(size / 2)).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }
        // Median bin power estimates a broad noise bed without treating a few
        // harmonic peaks as noise. For white noise, power is exponentially
        // distributed, so median / ln(2) estimates its mean. This deliberately
        // does not erase isolated interfering tones or claim source separation.
        var noisePower = 0.0, fraction = 0.0
        if suppressBroadbandNoise {
            let positive = Array(powers[1..<(size / 2)])
            let sorted = positive.sorted()
            noisePower = sorted[sorted.count / 2] / log(2)
            fraction = min(1, noisePower * Double(positive.count) / max(positive.reduce(0, +), 1e-30))
        }
        var peaks: [SpectralPeak] = []
        for i in 1..<(size / 2) where powers[i] > powers[i - 1] && powers[i] >= powers[i + 1] {
            let left = log(max(powers[i - 1], 1e-30)), center = log(max(powers[i], 1e-30))
            let right = log(max(powers[i + 1], 1e-30))
            let curvature = left - 2 * center + right
            let offset = abs(curvature) > 1e-15 ? max(-0.5, min(0.5, 0.5 * (left - right) / curvature)) : 0
            let hz = (Double(i) + offset) * sampleRate / Double(size)
            // Use measured bin power for evidence. Extrapolated log-parabolic
            // heights can inflate a sidelobe next to a spectral null.
            let power = 2 * powers[i] / normalization
            if hz >= 20 && power >= 0.001 && (!suppressBroadbandNoise || powers[i] >= noisePower * 8) { peaks.append(SpectralPeak(hz: hz, power: power)) }
        }
        return SpectrumEstimate(peaks: Array(peaks.sorted { $0.power > $1.power }.prefix(24)), broadbandNoiseFraction: fraction)
    }
}
