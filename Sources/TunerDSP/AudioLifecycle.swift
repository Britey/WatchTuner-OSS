import Foundation

public enum AudioActivity: Sendable, Equatable { case active, inactive, background }

/// Shared policy and sequencing used by the Watch controller and deterministic host tests.
@MainActor public final class AudioLifecycle {
    public private(set) var generation = 0
    public private(set) var activity: AudioActivity = .active
    public var systemPromptPending = false
    public var foregroundWaiterCount: Int { waiters.count }
    private var waiters: [(Int, CheckedContinuation<Bool, Never>)] = []
    private var shutdown: Task<Void, Never>?
    public init() {}

    public func beginStart() -> Int { cancelStart(); return generation }
    public func cancelStart() {
        generation &+= 1
        systemPromptPending = false
        let pending = waiters; waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: false) }
    }
    /// An already-running microphone session survives wrist-down/background with
    /// the app's audio background mode. Pending starts still require foreground;
    /// playback and idle transitions retain their existing cancellation policy.
    public func updateActivity(_ value: AudioActivity, runningCapture: Bool = false) -> Bool {
        activity = value
        if value == .active {
            let pending = waiters; waiters.removeAll()
            for (token, continuation) in pending { continuation.resume(returning: token == generation) }
            return false
        }
        if runningCapture { return false }
        if value == .background || !systemPromptPending { cancelStart(); return true }
        return false
    }
    public func beginPrompt(token: Int) { if token == generation { systemPromptPending = true } }
    public func endPrompt(token: Int) { if token == generation { systemPromptPending = false } }
    public func finishPermission(token: Int, granted: Bool) -> AudioPermissionResult {
        guard token == generation else { return .cancelled }
        systemPromptPending = false
        if granted { return .granted }
        cancelStart()
        return .denied
    }
    public func waitForForeground(token: Int) async -> Bool {
        guard token == generation, activity != .background else { return false }
        if activity == .active { return true }
        return await withCheckedContinuation { waiters.append((token, $0)) }
    }
    public func enqueueShutdown(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = shutdown
        shutdown = Task { await previous?.value; await operation() }
    }
    public func waitForShutdown() async { await shutdown?.value }
}

public enum AudioPermissionResult: Equatable, Sendable { case granted, denied, cancelled }

public struct AudioRouteState: Equatable, Sendable {
    public let inputIDs: [String]
    public let outputIDs: [String]
    public let sampleRate: Double
    public let inputChannels: Int
    public let outputChannels: Int
    public init(inputIDs: [String], outputIDs: [String], sampleRate: Double,
                inputChannels: Int = 0, outputChannels: Int = 0) {
        self.inputIDs = inputIDs.sorted(); self.outputIDs = outputIDs.sorted()
        self.sampleRate = sampleRate; self.inputChannels = inputChannels; self.outputChannels = outputChannels
    }
}
public enum AudioRouteEvent: Sendable, Equatable { case changed, lostDevice, noSuitableRoute }
public enum AudioRoutePolicy {
    public static func shouldStop(previous: AudioRouteState?, current: AudioRouteState, event: AudioRouteEvent) -> Bool {
        event == .lostDevice || event == .noSuitableRoute || previous != current
    }
}
