import Foundation

/// Complementary vocal evidence: normalized time-domain differences seed period
/// candidates; original-rate adjacent-cycle matching refines Hz locally. The
/// spectral estimator must independently supply a coherent root identity.
struct VocalPeriodEstimator {
    static func refine(_ samples: [Float], sampleRate: Double, hz: Double,
                       confidenceCeiling: Double = 1) -> PitchReading? {
        guard hz.isFinite, (40 * 0.999...2000 * 1.001).contains(hz) else { return nil }
        let x = Array(samples.suffix(32768)).map(Double.init)
        let seed = sampleRate / hz
        let length = max(4, Int(seed.rounded()))
        let lower = max(sampleRate / 2000, seed * 0.95)
        let upper = min(sampleRate / 40, seed * 1.05)
        guard lower < upper, x.count > length + Int(ceil(upper)) + 4 else { return nil }
        let bStart = x.count - length - 2
        // Local variance removes DC even if its level changed at a voiced ending.
        let meanB = x[bStart..<bStart+length].reduce(0, +) / Double(length)
        let varianceB = x[bStart..<bStart+length].reduce(0) { $0 + pow($1 - meanB, 2) }
        func residual(_ period: Double) -> Double {
            var error = 0.0, sumA = 0.0, squareA = 0.0
            for i in 0..<length {
                let position = Double(bStart + i) - period
                let index = Int(position), t = position - Double(index)
                let a = x[index-1], b = x[index], c = x[index+1], d = x[index+2]
                let shifted = b + 0.5*t*(c-a+t*(2*a-5*b+4*c-d+t*(3*(b-c)+d-a)))
                let delta = shifted - x[bStart+i]
                error += delta * delta; sumA += shifted; squareA += shifted * shifted
            }
            let energy = max(0, squareA - sumA * sumA / Double(length)) + varianceB
            return energy > 1e-12 ? error / energy : 1
        }
        let step = (upper - lower) / 20
        let grid = (0...20).map { lower + Double($0) * step }
        let values = grid.map(residual)
        guard let best = values.indices.min(by: { values[$0] < values[$1] }) else { return nil }
        // A minimum outside the search is uncertain, unless clipped by the
        // explicitly supported physical frequency range (e.g. exactly 40 Hz).
        if best == 0 && lower > sampleRate / 2000 { return nil }
        if best == 20 && upper < sampleRate / 40 { return nil }
        var left = grid[max(0, best-1)], right = grid[min(20, best+1)]
        let ratio = (sqrt(5.0)-1)/2
        var a = right-ratio*(right-left), b = left+ratio*(right-left)
        var fa = residual(a), fb = residual(b)
        for _ in 0..<16 {
            if fa < fb { right=b; b=a; fb=fa; a=right-ratio*(right-left); fa=residual(a) }
            else { left=a; a=b; fa=fb; b=left+ratio*(right-left); fb=residual(b) }
        }
        let options = [(grid[best], values[best]), (a, fa), (b, fb)]
        let result = options.min { $0.1 < $1.1 }!
        guard result.1 < 0.15 else { return nil }
        return .pitch(hz: sampleRate / result.0, confidence: min(confidenceCeiling, 1-result.1))
    }

    static func recover(_ samples: [Float], sampleRate: Double, identities: [Double]) -> PitchReading? {
        guard !identities.isEmpty else { return nil }
        for duration in [0.04, 0.08] {
            let window = Array(samples.suffix(Int(sampleRate * duration))).map(Double.init)
            guard window.count >= 512, window.allSatisfy(\.isFinite) else { continue }
            let mean = window.reduce(0, +) / Double(window.count)
            let centered = window.map { $0-mean }
            let (x, rate) = decimate(centered, sampleRate: sampleRate)
            let maximumLag = min(Int(ceil(rate / 40))+1, x.count/2-2)
            let minimumLag = max(2, Int(rate / 2000))
            guard maximumLag > minimumLag + 1 else { continue }
            let length = x.count-maximumLag
            var normalized = [Double](repeating: 1, count: maximumLag+1)
            var cumulative = 0.0
            for lag in 1...maximumLag {
                var difference = 0.0
                for i in 0..<length { let delta=x[i]-x[i+lag]; difference += delta*delta }
                cumulative += difference
                normalized[lag] = cumulative > 0 ? difference * Double(lag) / cumulative : 1
            }
            // YIN-style cumulative normalization counters short-period formant
            // valleys. Never use a best available candidate above the voicing gate.
            let candidates = (minimumLag..<maximumLag).filter {
                normalized[$0] < 0.15 && normalized[$0] < normalized[$0-1] && normalized[$0] <= normalized[$0+1]
            }
            var attempted = 0
            for lag in candidates {
                let divisor = normalized[lag-1]-2*normalized[lag]+normalized[lag+1]
                let offset = abs(divisor) > 1e-12 ? max(-0.5, min(0.5, 0.5*(normalized[lag-1]-normalized[lag+1])/divisor)) : 0
                let hz = rate / (Double(lag)+offset)
                guard identities.contains(where: { abs(1200 * log2(hz / $0)) < 80 }) else { continue }
                attempted += 1
                if let result = refine(samples, sampleRate: sampleRate, hz: hz, confidenceCeiling: 1-normalized[lag]) { return result }
                if attempted >= 8 { break }
            }
        }
        return nil
    }

    /// Integer-rate, Hann-windowed sinc decimation. A precomputed FIR avoids
    /// aliasing high formants into the coarse period candidates. Final refinement
    /// uses original-rate samples, so output precision is not the coarse lag grid.
    private static func decimate(_ x: [Double], sampleRate: Double) -> ([Double], Double) {
        let factor = max(1, Int(ceil(sampleRate / 12000)))
        guard factor > 1 else { return (x, sampleRate) }
        let radius = 8 * factor
        guard x.count > 2*radius else { return ([], sampleRate / Double(factor)) }
        let cutoff = 0.45 / Double(factor)
        let taps = (-radius...radius).map { k -> Double in
            let sinc = k == 0 ? 2*cutoff : sin(2 * .pi * cutoff * Double(k)) / (.pi * Double(k))
            return sinc * (0.5+0.5*cos(.pi * Double(k)/Double(radius)))
        }
        let scale = taps.reduce(0,+)
        var output: [Double] = []; output.reserveCapacity(x.count/factor)
        for center in stride(from: radius, to: x.count-radius, by: factor) {
            var value = 0.0
            for index in taps.indices { value += x[center+index-radius] * taps[index] }
            output.append(value / scale)
        }
        return (output, sampleRate / Double(factor))
    }
}
