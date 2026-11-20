import XCTest
@testable import TunerDSP

final class MetronomeTests: XCTestCase {
    func testClockRatesTemposAndBars() {
        for rate in [16000.0, 44100, 48000] {
            for bpm in [30.0, 59, 120, 137, 240] {
                var clock = MetronomeClock()
                var beats: [(Int, Int)] = []
                for frame in 0..<Int(rate * 8) {
                    if let beat = clock.next(sampleRate: rate, bpm: bpm, beatsPerBar: 3) { beats.append((frame, beat)) }
                }
                XCTAssertEqual(beats.first?.0, 0)
                XCTAssertEqual(beats.count, Int(ceil(8 * bpm / 60)))
                for (i, beat) in beats.enumerated() {
                    XCTAssertLessThanOrEqual(abs(Double(beat.0) - Double(i) * rate * 60 / bpm), 1.01)
                    XCTAssertEqual(beat.1, i % 3)
                }
            }
        }
    }

    func testFractionalTempoHasNoAccumulatedSampleDrift() {
        var clock = MetronomeClock()
        let rate = 44100.0, bpm = 137.0
        var count = 0
        for frame in 0..<Int(rate * 600) {
            if clock.next(sampleRate: rate, bpm: bpm, beatsPerBar: 4) != nil {
                XCTAssertLessThanOrEqual(abs(Double(frame) - Double(count) * rate * 60 / bpm), 1.01)
                count += 1
            }
        }
        XCTAssertEqual(count, 1370)
    }

    func testLiveTempoKeepsFractionalBeatProgress() {
        var clock = MetronomeClock()
        for _ in 0..<6000 { _ = clock.next(sampleRate: 48000, bpm: 120, beatsPerBar: 4) }
        XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-9)
        var next: Int?
        for frame in 6000..<20000 {
            if clock.next(sampleRate: 48000, bpm: 240, beatsPerBar: 4) != nil { next = frame; break }
        }
        XCTAssertEqual(Double(next ?? -1), 15000, accuracy: 1.01)
    }

    func testBarChangeBoundsAndInvalidInputs() {
        var clock = MetronomeClock()
        XCTAssertNil(clock.next(sampleRate: .nan, bpm: 120, beatsPerBar: 4))
        XCTAssertNil(clock.next(sampleRate: 48000, bpm: .nan, beatsPerBar: 4))
        XCTAssertEqual(clock.next(sampleRate: 48000, bpm: 999, beatsPerBar: 99), 0)
        var beats: [Int] = []
        for _ in 0..<48000 {
            if let beat = clock.next(sampleRate: 48000, bpm: 240, beatsPerBar: 1) { beats.append(beat) }
        }
        XCTAssertTrue(beats.allSatisfy { $0 == 0 })
        var slow = MetronomeClock()
        var count = 0
        for _ in 0..<96000 { if slow.next(sampleRate: 48000, bpm: -1, beatsPerBar: -1) != nil { count += 1 } }
        XCTAssertEqual(count, 1)
    }

    func testBarEditsRestartOnNextRealBeatWithMatchingAccentAndDisplay() {
        for newBar in [1, 4, 8] {
            var oscillator = MetronomeOscillator()
            // At 240 BPM, beat five of a five-beat bar begins at sample 48000.
            for _ in 0...48002 {
                if oscillator.next(sampleRate: 48000, bpm: 240, beatsPerBar: 5, accentFirst: true).beat == 4 { break }
            }
            var events: [(Int, Int, Int)] = []
            var downbeatPeak: Float = 0
            for index in 1...25000 {
                let sample = oscillator.next(sampleRate: 48000, bpm: 240, beatsPerBar: newBar, accentFirst: true)
                if let beat = sample.beat { events.append((index, beat, sample.beatsPerBar)) }
                if index < 11999 { XCTAssertEqual(sample.beatsPerBar, 5) }
                if (12000..<13152).contains(index) { downbeatPeak = max(downbeatPeak, abs(sample.value)) }
            }
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events[0].0, 12000, accuracy: 1)
            XCTAssertEqual(events[0].1, 0)
            XCTAssertEqual(events[0].2, newBar)
            XCTAssertEqual(events[1].1, 1 % newBar)
            // Accent matches a fresh first beat, rather than a remapped plain click.
            var reference = MetronomeOscillator()
            var peak: Float = 0
            for _ in 0..<1152 { peak = max(peak, abs(reference.next(sampleRate: 48000, bpm: 240, beatsPerBar: newBar, accentFirst: true).value)) }
            XCTAssertEqual(downbeatPeak, peak, accuracy: 0.00001)
        }
    }

    func testClickBoundsAccentAndDisableTail() {
        var oscillator = MetronomeOscillator()
        var values: [Float] = []
        var beats: [Int] = []
        for _ in 0..<48000 {
            let sample = oscillator.next(sampleRate: 48000, bpm: 240, beatsPerBar: 4, accentFirst: true)
            values.append(sample.value)
            if let beat = sample.beat { beats.append(beat) }
        }
        XCTAssertEqual(beats, [0, 1, 2, 3])
        XCTAssertEqual(values[0], 0)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && abs($0) <= 0.16 })
        XCTAssertLessThan(zip(values, values.dropFirst()).map { abs($0 - $1) }.max()!, 0.06)
        let accent = values[0..<1152].map { abs($0) }.max()!
        let plain = values[12001..<13153].map { abs($0) }.max()!
        XCTAssertGreaterThan(accent, plain)
        var stopped = MetronomeOscillator()
        for _ in 0..<100 { _ = stopped.next(sampleRate: 48000, bpm: 120, beatsPerBar: 4, accentFirst: true) }
        var tail: Float = 1
        for _ in 0..<48000 {
            let sample = stopped.next(sampleRate: 48000, bpm: 120, beatsPerBar: 4, accentFirst: true, enabled: false)
            XCTAssertNil(sample.beat)
            tail = sample.value
        }
        XCTAssertEqual(tail, 0)
        XCTAssertEqual(stopped.next(sampleRate: 0, bpm: 120, beatsPerBar: 4, accentFirst: true).value, 0)
    }

    func testRenderingIsIndependentOfBufferPartition() {
        func render(blocks: [Int]) -> [Float] {
            var oscillator = MetronomeOscillator()
            var output: [Float] = []
            for count in blocks {
                for _ in 0..<count {
                    output.append(oscillator.next(sampleRate: 48000, bpm: 137, beatsPerBar: 4, accentFirst: false).value)
                }
            }
            return output
        }
        XCTAssertEqual(render(blocks: [48000]), render(blocks: [127, 512, 4096, 43265]))
    }
}
