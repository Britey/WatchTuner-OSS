import Foundation

/// Historical harmonic estimator (`PitchAlgorithm.current`), not the production Pitchy path.
/// Global harmonic models select the shortest supported fundamental; fractional
/// waveform repetition validates it. This is monophonic estimation, not chord analysis.
public struct PitchDetector: Sendable {
    public let profile: TunerProfile
    private let noiseAware: Bool
    public var minimumHz: Double { profile.minimumHz }
    public var maximumHz: Double { profile.maximumHz }
    // Default preserves the historical stateless DSP API; the Watch app explicitly
    // loads Vocals by default from TunerProfile, including at first launch.
    public init(profile: TunerProfile = .guitar, noiseAware: Bool = false) { self.profile = profile; self.noiseAware = noiseAware }
    public func analyze(_ samples: [Float], sampleRate: Double) -> PitchReading {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), samples.count >= 512,
              samples.allSatisfy(\.isFinite) else { return .unclear }
        // Bound work, and retain the same recent-history policy as vocal recovery.
        let window = profile == .guitar ? Array(samples.prefix(8192)) : Array(samples.suffix(32768))
        switch PitchInputLeveling.prepare(window) {
        case .invalid: return .unclear
        case .silence: return .silence
        case .clipped: return .clipped
        case let .ready(samples, _, _): return analyzeLeveled(samples, sampleRate: sampleRate)
        }
    }
    private func analyzeLeveled(_ samples: [Float], sampleRate: Double) -> PitchReading {
        guard profile == .vocals else {
            return analyzeWindow(samples, sampleRate: sampleRate)
        }
        // Recent windows preserve glides/vibrato; longer windows support low voices.
        // Never fall back through a fresh silent/unvoiced ending to an old note.
        let recent = Array(samples.suffix(max(512, Int(sampleRate * 0.04))))
        let mean = recent.reduce(0.0) { $0 + Double($1) } / Double(max(1, recent.count))
        let centeredRecent = recent.map { Double($0) - mean }
        let first = analyzeWindow(recent, sampleRate: sampleRate)
        if first != .unclear { return first }
        for duration in [0.08, 0.16] {
            let window = Array(samples.suffix(Int(sampleRate * duration)))
            guard window.count > recent.count else { continue }
            let result = analyzeWindow(window, sampleRate: sampleRate)
            if case let .pitch(hz, _) = result {
                // A longer window can recover uncertain short-window estimates at
                // any frequency. Eligibility comes from current centered-sample
                // evidence, not a cutoff at four cycles / 40 ms (100 Hz).
                if repetitionResidual(centeredRecent, period: sampleRate / hz) < 0.15 { return result }
            }
        }
        // Root identity still requires a globally coherent spectral model. Time
        // evidence may replace the stationary-cycle guard, never invent a root.
        let identities = [0.04, 0.08, 0.16].compactMap { duration -> Double? in
            if case let .pitch(hz, _) = analyzeWindow(Array(samples.suffix(Int(sampleRate * duration))), sampleRate: sampleRate, validateRepetition: false) { return hz }
            return nil
        }
        return VocalPeriodEstimator.recover(samples, sampleRate: sampleRate, identities: identities) ?? .unclear
    }
    private func analyzeWindow(_ samples: [Float], sampleRate: Double, validateRepetition: Bool = true) -> PitchReading {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), samples.count >= 512,
              samples.allSatisfy({ $0.isFinite }) else { return .unclear }
        let count = min(samples.count, profile == .guitar ? 8192 : 32768)
        let input = samples.prefix(count)
        let mean = input.reduce(0.0) { $0 + Double($1) } / Double(count)
        let x = input.map { Double($0) - mean }
        let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(count))
        guard rms > 1e-12 else { return .silence }
        if profile == .guitar, Double(count) < 4 * sampleRate / minimumHz { return .unclear }
        let spectrum = HarmonicSpectrum.analyze(x, sampleRate: sampleRate, suppressBroadbandNoise: noiseAware && profile != .vocals)
        let peaks = spectrum.peaks
        guard !peaks.isEmpty else { return .unclear }

        func gcd(_ a: Int, _ b: Int) -> Int {
            var a = a, b = b
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            return a
        }
        struct Model { let hz: Double; let score: Double }
        let spectralPower = peaks.reduce(0) { $0 + $1.power }
        let strongestPower = peaks[0].power
        // A small interference budget supports a dominant monophonic source in a
        // real room. Weak unrelated peaks cannot establish an absent fundamental:
        // canonicalization uses only substantial partials unless the root is observed.
        let unexplainedBudget = 0.03 + (!noiseAware || profile == .vocals ? 0 : min(0.07, spectrum.broadbandNoiseFraction * 0.2))
        let missingRootSupport = 0.10
        func matches(_ hz: Double, stiffness: Double = 0, tolerance: Double) -> [(SpectralPeak, Int)] {
            peaks.compactMap { peak in
                let harmonic = Int((peak.hz / hz).rounded())
                guard (1...64).contains(harmonic),
                      abs(1200 * log2(peak.hz / (hz * Double(harmonic) * sqrt((1 + stiffness * Double(harmonic * harmonic)) / (1 + stiffness))))) < tolerance else { return nil }
                return (peak, harmonic)
            }
        }
        func fit(_ initial: Double) -> Model? {
            var hz = initial
            var stiffness = 0.0
            for _ in 0..<4 {
                let matched = matches(hz, stiffness: stiffness, tolerance: profile == .piano ? 80 : profile == .vocals ? 30 : 20)
                guard !matched.isEmpty else { return nil }
                if !matched.contains(where: { $0.1 == 1 }) {
                    let core = matched.filter { $0.0.power >= strongestPower * missingRootSupport }
                    guard !core.isEmpty else { return nil }
                    // Two unrelated high partials can approximate a very low
                    // harmonic grid. An absent instrument root needs at least
                    // one low-order supporting partial, not just a large GCD.
                    if noiseAware, profile != .vocals, (core.map { $0.1 }.min() ?? 65) > 4 { return nil }
                    let divisor = core.reduce(0) { gcd($0, $1.1) }
                    if divisor > 1 { hz *= Double(divisor); continue }
                }
                // Weight normalized partial frequencies by power / harmonic².
                // Strong resolved low partials refine a weak noisy root, while
                // stretched upper partials have decreasing leverage on tuning.
                let weight = matched.reduce(0.0) { $0 + $1.0.power / Double($1.1 * $1.1) }
                hz = matched.reduce(0) { $0 + $1.0.power * $1.0.hz / Double($1.1 * $1.1 * $1.1) } / weight
                if profile == .piano, matched.count >= 3 {
                    // (partial / h)² = a + b h²; B=b/a. Report sqrt(a+b),
                    // the first partial, not an ideal flexible-string frequency.
                    let meanX = matched.reduce(0) { $0 + $1.0.power } / weight
                    let meanY = matched.reduce(0) { $0 + $1.0.power * pow($1.0.hz / Double($1.1), 2) / Double($1.1 * $1.1) } / weight
                    let covariance = matched.reduce(0.0) { total, item in
                        let h2 = Double(item.1 * item.1)
                        return total + item.0.power / h2 * (h2 - meanX) * (pow(item.0.hz / Double(item.1), 2) - meanY)
                    }
                    let variance = matched.reduce(0.0) { $0 + $1.0.power / Double($1.1 * $1.1) * pow(Double($1.1 * $1.1) - meanX, 2) }
                    if variance > 0 {
                        let b = covariance / variance, a = meanY - b * meanX
                        if a > 0, b >= 0, b / a <= 0.005 {
                            stiffness = b / a; hz = sqrt(a + b)
                        }
                    }
                }
            }
            let matched = matches(hz, stiffness: stiffness, tolerance: profile == .vocals ? 20 : 8)
            let score = matched.reduce(0.0) { $0 + $1.0.power }
            guard score >= spectralPower * (1 - unexplainedBudget) else { return nil }
            return Model(hz: hz, score: score)
        }
        // Normalize the minimum tonal evidence against the estimated broadband
        // bed, with a hard lower bound so noise cannot manufacture a model.
        let minimumScore = !noiseAware || profile == .vocals ? 0.5 : max(0.35, 0.5 * (1 - spectrum.broadbandNoiseFraction))
        var models: [Model] = []
        for peak in peaks {
            for harmonic in 1...16 {
                let proposed = peak.hz / Double(harmonic)
                guard proposed >= 20, let model = fit(proposed), model.score >= minimumScore else { continue }
                if !models.contains(where: { abs(1200 * log2($0.hz / model.hz)) < 1 }) { models.append(model) }
            }
        }
        guard let best = models.max(by: { $0.score < $1.score }) else { return .unclear }
        if models.contains(where: { abs(1200 * log2($0.hz / best.hz)) > 4 && $0.score >= best.score - 0.001 }) {
            return .unclear
        }
        guard best.hz >= minimumHz * 0.999, best.hz <= maximumHz * 1.001 else { return .unclear }
        // Identity-only results never reach the UI; zero is not periodicity evidence.
        if !validateRepetition { return .pitch(hz: min(maximumHz, max(minimumHz, best.hz)), confidence: 0) }
        guard Double(count) >= 4 * sampleRate / best.hz else { return .unclear }
        let residual = repetitionResidual(x, period: sampleRate / best.hz)
        // Instrument decay and room noise need not repeat exactly. Permit only
        // the broadband portion estimated independently from spectral bins;
        // isolated competing tones retain the strict harmonic-model rejection.
        let noiseAllowance = !noiseAware || profile == .vocals ? 0 : min(0.20, spectrum.broadbandNoiseFraction)
        guard residual < 0.15 + noiseAllowance else { return .unclear }
        return .pitch(hz: min(maximumHz, max(minimumHz, best.hz)), confidence: 1 - residual)
    }
    private func repetitionResidual(_ x: [Double], period: Double) -> Double {
        let count = x.count
        let length = min(count / 2, count - Int(ceil(period)) - 2)
        guard length > 0, period >= 2 else { return 1 }
        var error = 0.0, energy = 0.0
        for i in 0..<length {
            let position = Double(i) + period
            let base = Int(position), t = position - Double(base)
            let a = x[base - 1], b = x[base], c = x[base + 1], d = x[base + 2]
            let shifted = b + 0.5 * t * (c - a + t * (2*a - 5*b + 4*c - d + t * (3*(b-c) + d-a)))
            let delta = x[i] - shifted
            error += delta * delta
            energy += x[i] * x[i] + shifted * shifted
        }
        return energy > 0 ? error / energy : 1
    }
}
