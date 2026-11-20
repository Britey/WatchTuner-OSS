import Foundation

public enum CaptureTimingAction: Equatable, Sendable {
    case retryLargerTap(frames: Int)
    case unavailable
}

/// One retry per Start. Unknown timestamps never authorize joining buffers.
/// Awaiting/failed stages emit once; replacement owns a fresh, exhausted budget.
public struct CaptureTimingRecovery: Sendable {
    private enum Stage: Sendable { case initial, awaitingReplacement, larger, failed }
    private var stage: Stage
    private var consecutive = 0
    public init(largerTapAttempted: Bool = false) { stage = largerTapAttempted ? .larger : .initial }
    public static func windowFrames(sampleRate: Double) -> Int { max(2048, Int(ceil(sampleRate * 0.18))) }
    /// AVAudioNode documents a supported tap request range of 100–400 ms.
    public static func initialTapFrames(sampleRate: Double) -> Int { max(2048, Int(ceil(sampleRate * 0.10))) }
    public mutating func observe(sampleRate: Double, frameCount: Int, timestampValid: Bool) -> CaptureTimingAction? {
        guard stage == .initial || stage == .larger else { return nil }
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate), frameCount > 0 else { consecutive = 0; return nil }
        guard !timestampValid, frameCount < Self.windowFrames(sampleRate: sampleRate) else { consecutive = 0; return nil }
        consecutive += 1
        guard consecutive >= 3 else { return nil }
        if stage == .initial { stage = .awaitingReplacement; return .retryLargerTap(frames: Self.windowFrames(sampleRate: sampleRate)) }
        stage = .failed
        return .unavailable
    }
}
