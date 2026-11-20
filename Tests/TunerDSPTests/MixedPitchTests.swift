import XCTest
@testable import TunerDSP

private struct IndependentRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func unit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / 9007199254740992.0
    }
}

final class MixedPitchTests: XCTestCase {
    private let detector = PitchDetector()
    private func waveform(hz: Double, rate: Double, amplitudes: [Double], phases: [Double],
                          noise: Double = 0, seed: UInt64 = 1) -> [Float] {
        var random = IndependentRandom(seed)
        return (0..<Int(rate * 0.18)).map { i in
            let p = 2 * Double.pi * hz * Double(i) / rate
            var value = noise * (2 * random.unit() - 1)
            for h in amplitudes.indices { value += amplitudes[h] * sin(Double(h + 1) * p + phases[h]) }
            return Float(value)
        }
    }
    @discardableResult private func check(_ reading: PitchReading, hz: Double, cents: Double = 4,
                                          context: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
        switch reading {
        case let .pitch(actual, confidence):
            XCTAssertLessThan(abs(1200 * log2(actual / hz)), cents, "\(context): \(hz) → \(actual), confidence=\(confidence)", file: file, line: line)
            XCTAssertGreaterThan(confidence, 0.85, file: file, line: line)
            return true
        case .unclear: return false
        default: XCTFail("Unexpected \(reading): \(context)", file: file, line: line); return false
        }
    }
    func testSimpleReviewerMixedPartialsDoNotAcquireLongerPeriod() {
        for hz in [1600.0, 1650, 1670, 1671, 1680, 1700] {
            for gains in [[0.11, 0.12, 0.3], [0.12, 0.12, 0.3], [0.12, 0.2, 0]] {
                let input = waveform(hz: hz, rate: 48000, amplitudes: gains, phases: [0, 0, 0])
                XCTAssertTrue(check(detector.analyze(input, sampleRate: 48000), hz: hz, context: "simple \(gains)"))
            }
        }
        let input = waveform(hz: 1670.9851593014284, rate: 48000,
                             amplitudes: [0.1122327827248333, 0.11893981730540744, 0.3],
                             phases: [4.742290029318931, 2.8393532655900406, 0.5182436714383261])
        XCTAssertTrue(check(detector.analyze(input, sampleRate: 48000), hz: 1670.9851593014284, context: "exact randomized reviewer regression"))
    }
    func testReviewerSeed315Full2500MixedSignals() {
        var state: UInt64 = 315
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double(state >> 32) / Double(UInt32.max)
        }
        var reports = 0
        for index in 0..<2500 {
            let hz = 55 + random() * 1945
            let dominant = 2 + Int(random() * 3)
            let base = 0.015 + random() * 0.105, extra = random() * 0.2
            let extraHarmonic = dominant == 3 ? 2 : 3
            let phase1 = random() * 2 * .pi, phase2 = random() * 2 * .pi, phase3 = random() * 2 * .pi
            let input: [Float] = (0..<8640).map { i in
                let p = 2 * Double.pi * hz * Double(i) / 48000
                return Float(base * sin(p + phase1) + 0.3 * sin(Double(dominant) * p + phase2) + extra * sin(Double(extraHarmonic) * p + phase3))
            }
            if check(detector.analyze(input, sampleRate: 48000), hz: hz, context: "reviewer index=\(index) dominant=\(dominant)") { reports += 1 }
        }
        XCTAssertGreaterThanOrEqual(reports, 2000, "Do not hide wrong pitches by rejecting every mixture")
        print("reviewer_seed_315 total=2500 reported=\(reports) unclear=\(2500-reports)")
    }
    func testIndependentMixedPartialsAcrossRates() {
        var random = IndependentRandom(0x5741544348)
        var reports = 0
        for rate in [16000.0, 44100, 48000] {
            for index in 0..<140 {
                let hz = 55 + 1945 * random.unit()
                let highest = max(2, min(6, Int(rate * 0.45 / hz)))
                let dominant = 2 + Int(random.unit() * Double(highest - 1))
                var amplitudes = [0.025 + 0.075 * random.unit()]
                for h in 2...6 { amplitudes.append(h <= highest ? 0.12 * random.unit() : 0) }
                amplitudes[dominant - 1] += 0.25
                let scale = 0.65 / amplitudes.reduce(0, +)
                amplitudes = amplitudes.map { $0 * scale }
                let phases = (0..<6).map { _ in 2 * Double.pi * random.unit() }
                let input = waveform(hz: hz, rate: rate, amplitudes: amplitudes, phases: phases)
                if check(detector.analyze(input, sampleRate: rate), hz: hz, context: "independent rate=\(rate) index=\(index)") { reports += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(reports, 252)
        print("independent_mixtures total=420 reported=\(reports) unclear=\(420-reports)")
    }
    func testIndependentWhiteAndColoredNoiseAreNeverPitch() {
        for rate in [8000.0, 16000, 44100, 48000] {
            for seed in 1...32 {
                let amplitude = [0.004, 0.03, 0.3, 0.6][seed % 4]
                for colored in [false, true] {
                    var random = IndependentRandom(UInt64(seed) ^ UInt64(rate))
                    var filtered = 0.0
                    var values: [Double] = []
                    for _ in 0..<Int(rate * 0.18) {
                        let white = 2 * random.unit() - 1
                        filtered = 0.92 * filtered + 0.08 * white
                        values.append(colored ? filtered : white)
                    }
                    let scale = amplitude / values.map { abs($0) }.max()!
                    let input = values.map { Float($0 * scale + 0.15) }
                    let reading = detector.analyze(input, sampleRate: rate)
                    switch reading {
                    case .silence, .unclear: break
                    default: XCTFail("Noise reported as \(reading): rate=\(rate), seed=\(seed), colored=\(colored)")
                    }
                }
            }
        }
    }
    func testIndependentNoisyHarmonicMixtures() {
        var random = IndependentRandom(0x4e4f495345)
        var reports = 0
        for rate in [16000.0, 44100, 48000] {
            for index in 0..<60 {
                let hz = 55 + random.unit() * 1945
                let amplitudes = [0.06 + 0.08 * random.unit(), 0.3, 0.15 * random.unit()]
                let phases = (0..<3).map { _ in 2 * Double.pi * random.unit() }
                let noise = [0.005, 0.02, 0.06, 0.12][index % 4]
                let input = waveform(hz: hz, rate: rate, amplitudes: amplitudes, phases: phases,
                                     noise: noise, seed: UInt64(index + 1) ^ UInt64(rate))
                if check(detector.analyze(input, sampleRate: rate), hz: hz, cents: 10,
                         context: "noisy rate=\(rate) index=\(index) amplitude=\(noise)") { reports += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(reports, 90)
        print("independent_noisy total=180 reported=\(reports) unclear=\(180-reports)")
    }
}
