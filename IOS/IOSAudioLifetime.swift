import Foundation
import Synchronization

/// Shared by the controller and host tests; inactive is still foreground on iOS.
enum IOSAudioScenePolicy {
    static func preservesEngagedAudio(isBackground: Bool, engaged: Bool) -> Bool {
        !isBackground && engaged
    }
}

/// One lease covers the audio objects made during one media-service lifetime.
/// Invalidation is immediate, including while an asynchronous fade or activation
/// is suspended. Already-begun system calls are allowed to finish; callers retain
/// their task as a fence before starting another session.
final class IOSAudioObjectLifetime: Sendable {
    private let valid = Atomic<Bool>(true)
    var isValid: Bool { valid.load(ordering: .acquiring) }
    func invalidate() { valid.store(false, ordering: .releasing) }

    /// Main-actor graph operations cannot interleave with reset notification
    /// invalidation. Background session calls check this just before beginning.
    @discardableResult
    func performIfValid<Value>(_ operation: () throws -> Value) rethrows -> Value? {
        guard isValid else { return nil }
        return try operation()
    }

    /// The production fade/cleanup sequence is also executable with host-test
    /// closures. The activation fence survives invalidation; orphaned graph and
    /// session operations do not. A dispatched deactivate must recheck this lease
    /// before beginning its system call, just as activation does.
    @MainActor
    func finishShutdown(wasActive: Bool,
                        isRunning: @MainActor () -> Bool,
                        isQuiet: @MainActor () -> Bool,
                        stop: @MainActor () -> Void,
                        awaitActivation: @MainActor () async -> Bool,
                        deactivate: @MainActor () async -> Void,
                        waitForFade: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(5)) }) async {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while performIfValid({ isRunning() }) == true,
              performIfValid({ isQuiet() }) == false, ContinuousClock.now < deadline {
            await waitForFade()
        }
        performIfValid { stop() }
        // An already-begun system call cannot be cancelled. Always fence it.
        let didActivate = await awaitActivation()
        if isValid, wasActive || didActivate { await deactivate() }
    }
}
