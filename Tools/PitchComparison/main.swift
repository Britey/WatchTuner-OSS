import Foundation
func instrument(hz: Double, rate: Double, amplitude: Double, piano: Bool,
                            noise: Double = 0.25, offset: Double = 0.2) -> [Float] {
        var state: UInt64 = 193939
        let detunings = piano ? [-2.5, 0, 2.5] : [0.0]
        return (0..<Int(rate * 0.18)).map { index in
            let t = Double(index) / rate + offset
            state = state &* 6364136223846793005 &+ 1
            var value = noise * (Double(state >> 32) / Double(UInt32.max) * 2 - 1)
            for cents in detunings {
                for harmonic in 1...10 {
                    let h = Double(harmonic)
                    let frequency = hz * pow(2, cents / 1200) * h * sqrt((1 + 0.0002 * h*h) / 1.0002)
                    guard frequency < rate * 0.45 else { continue }
                    let envelope = exp(-t / (0.8 / sqrt(h)))
                    let phase = 2 * Double.pi * frequency * t + 0.31 * h + cents
                    // A direct path plus a fixed, attenuated room reflection.
                    value += envelope / (h * Double(detunings.count)) * (sin(phase) + 0.35 * sin(phase - 2 * .pi * frequency * 0.013))
                }
            }
            return Float(amplitude * value)
        }
    }

func ours(_ samples: [Float], rate: Double, profile: TunerProfile) -> Double? {
    if case let .pitch(hz, _) = PitchAlgorithm.noiseAware.analyze(samples, sampleRate: rate, profile: profile) { return hz }
    return nil
}
func native(_ algorithm: PitchAlgorithm, _ input: [Float], _ rate: Double, _ profile: TunerProfile) -> Double? {
 if case let .pitch(hz, _) = algorithm.analyze(input, sampleRate: rate, profile: profile) { return hz }
 return nil
}
var rows: [[String: Any]] = []
@MainActor func record(_ input: [Float], rate: Double, profile: TunerProfile, expected: Double?, kind: String) {
    rows.append(["kind": kind, "profile": profile.rawValue, "sample_rate": rate,
                 "expected": expected as Any? ?? NSNull(), "input": input,
                 "native_harmonic": native(.current, input, rate, profile) as Any? ?? NSNull(),
                 "native_noise_aware": ours(input, rate: rate, profile: profile) as Any? ?? NSNull(),
                 "native_mcleod": native(.mcleod, input, rate, profile) as Any? ?? NSNull()])
}
for profile in [TunerProfile.piano, .guitar] {
 for rate in [16000.0, 48000] {
  for hz in [110.0, 220, 440, 880] {
   for amplitude in [0.1, 0.00003] {
    for noise in [0.0, 0.25] {
     record(instrument(hz: hz, rate: rate, amplitude: amplitude, piano: profile == .piano, noise: noise), rate: rate, profile: profile, expected: hz, kind: noise == 0 ? "clean_instrument" : "noisy_instrument")
    }
   }
  }
 }
 for seed in 1...12 {
  var state = UInt64(seed), low = 0.0
  let noise: [Float] = (0..<2880).map { _ in
   state = state &* 6364136223846793005 &+ 1
   let white = Double(state >> 32) / Double(UInt32.max) * 2 - 1
   low = 0.92 * low + 0.08 * white
   return Float((seed % 2 == 0 ? white : low) * 0.00003)
  }
  record(noise, rate: 16000, profile: profile, expected: nil, kind: "noise")
 }
 for ratio in [sqrt(2.0), sqrt(3.0), 1.5] {
  let mixed: [Float] = (0..<2880).map { Float(0.1 * sin(2 * .pi * 440 * Double($0)/16000) + 0.08 * sin(2 * .pi * 440 * ratio * Double($0)/16000)) }
  record(mixed, rate: 16000, profile: profile, expected: nil, kind: "competing_tones")
 }
 record([Float](repeating: 0, count: 2880), rate: 16000, profile: profile, expected: nil, kind: "silence")
}
let json = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
