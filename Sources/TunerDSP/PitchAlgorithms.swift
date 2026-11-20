import Foundation
import Accelerate

public enum PitchAlgorithm: String, CaseIterable, Sendable {
    #if !WATCHTUNER_APP
    // Historical methods remain available to offline tests and comparison tools.
    case current = "Current", noiseAware = "Noise-aware"
    #endif
    case mcleod = "McLeod · Pitchy"
    // Keep existing capture-configuration codes stable; code 2 is retired.
    public var code: UInt64 {
        switch self {
        #if !WATCHTUNER_APP
        case .current: 0
        case .noiseAware: 1
        #endif
        case .mcleod: 3
        }
    }
    public init(code: UInt64) {
        #if !WATCHTUNER_APP
        self = code == 0 ? .current : code == 1 ? .noiseAware : .mcleod
        #else
        self = .mcleod
        #endif
    }
    public static let licenseNotice = """
    Pitchy 4.1.0: Copyright 2018–2021 Ian Johnson.

    MIT License

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
    public func analyze(_ samples: [Float], sampleRate: Double, profile: TunerProfile) -> PitchReading {
        #if !WATCHTUNER_APP
        if self == .current || self == .noiseAware {
            return PitchDetector(profile: profile, noiseAware: self == .noiseAware).analyze(samples, sampleRate: sampleRate)
        }
        #endif
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), samples.count >= 512 else { return .unclear }
        switch PitchInputLeveling.prepare(Array(samples.suffix(32768))) {
        case .invalid: return .unclear
        case .silence: return .silence
        case .clipped: return .clipped
        case let .ready(samples, _, _):
            return McLeodPitchEstimator.estimate(samples, rate: sampleRate, profile: profile)
        }
    }
}

/// Native bounded adaptation of Pitchy 4.1.0's McLeod method.
/// See THIRD_PARTY_NOTICES. Shared capture, leveling, ranges and display remain
/// identical. Correlation uses scoped vDSP dot products rather than a JS/FFT runtime.
enum McLeodPitchEstimator {
    static func estimate(_ input: [Float], rate: Double, profile: TunerProfile) -> PitchReading {
        let count = input.count
        let maximumLag = min(count / 2 - 2, Int(ceil(rate / (profile.minimumHz * 0.98))))
        guard count >= 256, maximumLag >= 4 else { return .unclear }
        var energy = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { energy[i + 1] = energy[i] + Double(input[i]) * Double(input[i]) }
        var values = [Double](repeating: 0, count: maximumLag + 2)
        input.withUnsafeBufferPointer { buffer in
            for lag in 0..<values.count {
                let length = count - lag
                var correlation: Float = 0
                vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress!.advanced(by: lag), 1,
                           &correlation, vDSP_Length(length))
                let combined = energy[length] + energy[lag + length] - energy[lag]
                values[lag] = combined > 0 ? 2 * Double(correlation) / combined : 0
            }
        }
        // Pitchy key maxima: highest point in each positive lobe following
        // a positive zero crossing; choose first at least 0.9 of the best.
        var maxima: [Int] = [], looking = false, maximum = 0
        for i in 1...maximumLag {
            if values[i - 1] <= 0 && values[i] > 0 { looking = true; maximum = i }
            else if values[i - 1] > 0 && values[i] <= 0 {
                if looking { maxima.append(maximum) }
                looking = false
            } else if looking && values[i] > values[maximum] { maximum = i }
        }
        // A bounded search may end during a lobe. Only use a completed local
        // maximum with both neighbors available, never the boundary slope.
        if looking, maximum < maximumLag { maxima.append(maximum) }
        guard let best = maxima.map({ values[$0] }).max(),
              let first = maxima.first(where: { values[$0] >= 0.9 * best }) else { return .unclear }
        let selected = first
        let left = values[selected - 1], center = values[selected], right = values[selected + 1]
        let curvature = left - 2 * center + right
        let delta = abs(curvature) > 1e-12 ? max(-1, min(1, 0.5 * (left - right) / curvature)) : 0
        let interpolated = center - 0.25 * (left - right) * delta
        let clarity = min(1, max(0, interpolated))
        let hz = rate / (Double(selected) + delta)
        guard hz.isFinite, hz >= profile.minimumHz * 0.999, hz <= profile.maximumHz * 1.001,
              Double(count) >= 4 * rate / hz, clarity >= 0.8 else { return .unclear }
        return .pitch(hz: min(profile.maximumHz, max(profile.minimumHz, hz)), confidence: clarity)
    }
}
