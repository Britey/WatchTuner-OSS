import Foundation

/// Fractional beat phase advances once per rendered audio sample. Tempo changes keep
/// the current beat's fractional progress; block sizes and UI polling cannot affect timing.
public struct MetronomeClock: Sendable {
    public private(set) var phase = 0.0
    private var firstBeat = true
    private var beatIndex = 0
    private var requestedBar = 4
    private var resetBarOnBeat = false
    public private(set) var activeBeatsPerBar = 4
    public init() {}

    public mutating func next(sampleRate: Double, bpm: Double, beatsPerBar: Int) -> Int? {
        guard sampleRate.isFinite, sampleRate >= 8000, bpm.isFinite else { return nil }
        let tempo = max(30, min(240, bpm))
        let bar = max(1, min(8, beatsPerBar))
        if bar != requestedBar { requestedBar = bar; resetBarOnBeat = true }
        var beat: Int?
        if firstBeat {
            firstBeat = false
            beatIndex = 0
            activeBeatsPerBar = requestedBar
            resetBarOnBeat = false
            beat = 0
        } else if phase >= 1 {
            phase -= 1
            if resetBarOnBeat {
                beatIndex = 0
                activeBeatsPerBar = requestedBar
                resetBarOnBeat = false
            } else {
                beatIndex = (beatIndex + 1) % activeBeatsPerBar
            }
            beat = beatIndex
        }
        phase += tempo / (60 * sampleRate)
        return beat
    }
}

public struct MetronomeSample: Sendable {
    public let value: Float
    public let beat: Int?
    public let beatsPerBar: Int
}

/// Short, bounded sine clicks with soft attack/release. Only the audio render
/// callback owns this state. Disabling suppresses future beats and fades the tail.
public struct MetronomeOscillator: Sendable {
    private var clock = MetronomeClock()
    private var age = Double.infinity
    private var clickHz = 1800.0
    private var clickGain = 0.12
    private var masterGain = 1.0
    public init() {}
    public var isSilent: Bool { age >= 0.024 || masterGain < 0.00001 }

    public mutating func next(sampleRate: Double, bpm: Double, beatsPerBar: Int,
                              accentFirst: Bool, enabled: Bool = true) -> MetronomeSample {
        guard sampleRate.isFinite, sampleRate >= 8000, bpm.isFinite else {
            return MetronomeSample(value: 0, beat: nil, beatsPerBar: clock.activeBeatsPerBar)
        }
        let beat = enabled ? clock.next(sampleRate: sampleRate, bpm: bpm, beatsPerBar: beatsPerBar) : nil
        if let beat {
            age = 0
            let accent = accentFirst && beat == 0
            clickHz = min(sampleRate * 0.4, accent ? 2400 : 1800)
            clickGain = accent ? 0.16 : 0.12
        }
        masterGain += ((enabled ? 1 : 0) - masterGain) * min(1, 1 / (sampleRate * 0.003))
        let duration = 0.024
        guard age < duration else { return MetronomeSample(value: 0, beat: beat, beatsPerBar: clock.activeBeatsPerBar) }
        let attack = min(1, age / 0.001)
        let release = min(1, (duration - age) / 0.004)
        let envelope = attack * release * exp(-age / 0.008)
        let value = Float(sin(2 * .pi * clickHz * age) * envelope * clickGain * masterGain)
        age += 1 / sampleRate
        return MetronomeSample(value: value, beat: beat, beatsPerBar: clock.activeBeatsPerBar)
    }
}
