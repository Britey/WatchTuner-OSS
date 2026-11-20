import Foundation

@MainActor private final class LifetimeLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct IOSAudioLifetimeSmoke {
    @MainActor
    static func main() async {
        await sceneTransitions()
        await ordinaryShutdown()
        await resetBeforeQueuedCleanup()
        await resetDuringFade()
        await resetDuringActivationStillFencesRestart()
        print("PASS: 5 iOS audio lifetime scenarios; inactive/background, normal cleanup, reset before/during fade, pending activation fencing")
    }

    @MainActor
    private static func waitUntilEntered(_ latch: LifetimeLatch) async {
        for _ in 0..<10_000 where !latch.entered { await Task.yield() }
        precondition(latch.entered, "Shutdown never reached its controlled suspension")
    }

    @MainActor
    private static func sceneTransitions() async {
        let lifecycle = AudioLifecycle()
        let token = lifecycle.beginStart()
        // This is the production iOS policy applied to the unchanged shared
        // lifecycle: an engaged foreground session survives ordinary inactivity.
        let preserve = IOSAudioScenePolicy.preservesEngagedAudio(isBackground: false, engaged: true)
        precondition(!lifecycle.updateActivity(.inactive, runningCapture: preserve))
        precondition(lifecycle.generation == token)
        let waiting = Task { await lifecycle.waitForForeground(token: token) }
        for _ in 0..<10_000 where lifecycle.foregroundWaiterCount == 0 { await Task.yield() }
        precondition(lifecycle.foregroundWaiterCount == 1, "An inactive pending start must wait")
        _ = lifecycle.updateActivity(.active, runningCapture: preserve)
        let resumed = await waiting.value
        precondition(resumed)
        precondition(!lifecycle.updateActivity(.inactive, runningCapture: preserve))
        let backgroundPreserve = IOSAudioScenePolicy.preservesEngagedAudio(isBackground: true, engaged: true)
        precondition(lifecycle.updateActivity(.background, runningCapture: backgroundPreserve))
        _ = lifecycle.updateActivity(.active)
        let oldStart = await lifecycle.waitForForeground(token: token)
        precondition(!oldStart, "Background must cancel the old Start")
        precondition(!IOSAudioScenePolicy.preservesEngagedAudio(isBackground: false, engaged: false))
    }

    @MainActor
    private static func ordinaryShutdown() async {
        let objects = IOSAudioObjectLifetime()
        var events: [String] = []
        await objects.finishShutdown(wasActive: true,
            isRunning: { events.append("running"); return true },
            isQuiet: { events.append("quiet"); return true },
            stop: { events.append("stop") },
            awaitActivation: { events.append("activation fence"); return false },
            deactivate: { events.append("deactivate") })
        precondition(events == ["running", "quiet", "stop", "activation fence", "deactivate"])
    }

    @MainActor
    private static func resetBeforeQueuedCleanup() async {
        let objects = IOSAudioObjectLifetime()
        objects.invalidate()
        var fenced = false
        // Real shutdown orchestration must not even query an invalid graph.
        await objects.finishShutdown(wasActive: true,
            isRunning: { preconditionFailure("Queried orphaned engine") },
            isQuiet: { preconditionFailure("Queried orphaned renderer") },
            stop: { preconditionFailure("Stopped orphaned engine") },
            awaitActivation: { fenced = true; return true },
            deactivate: { preconditionFailure("Deactivated reset session") })
        precondition(fenced, "Invalidation must not discard the in-flight activation fence")
    }

    @MainActor
    private static func resetDuringFade() async {
        let objects = IOSAudioObjectLifetime(), fade = LifetimeLatch()
        var graphInvalid = false
        var events: [String] = []
        let shutdown = Task { @MainActor in
            await objects.finishShutdown(wasActive: true,
                isRunning: { precondition(!graphInvalid); events.append("running"); return true },
                isQuiet: { precondition(!graphInvalid); events.append("quiet"); return false },
                stop: { precondition(!graphInvalid); events.append("stop") },
                awaitActivation: { events.append("activation fence"); return false },
                deactivate: { preconditionFailure("Deactivated after reset during fade") },
                waitForFade: { await fade.wait() })
        }
        await waitUntilEntered(fade)
        objects.invalidate()
        graphInvalid = true
        fade.release()
        await shutdown.value
        precondition(events == ["running", "quiet", "activation fence"], "Old fade touched invalid objects")
    }

    @MainActor
    private static func resetDuringActivationStillFencesRestart() async {
        let lifecycle = AudioLifecycle()
        let oldObjects = IOSAudioObjectLifetime(), activation = LifetimeLatch()
        var events: [String] = []
        lifecycle.enqueueShutdown {
            await oldObjects.finishShutdown(wasActive: false,
                isRunning: { false }, isQuiet: { true },
                stop: { events.append("old stop") },
                awaitActivation: {
                    events.append("old activation began")
                    await activation.wait()
                    events.append("old activation completed")
                    return true
                },
                deactivate: { preconditionFailure("Old cleanup deactivated the new service lifetime") })
        }
        await waitUntilEntered(activation)
        oldObjects.invalidate()
        let freshObjects = IOSAudioObjectLifetime()
        let restart = Task { @MainActor in
            await lifecycle.waitForShutdown()
            freshObjects.performIfValid { events.append("fresh activation") }
        }
        await Task.yield()
        precondition(!events.contains("fresh activation"), "Restart bypassed old in-flight system call")
        activation.release()
        await restart.value
        precondition(events == ["old stop", "old activation began", "old activation completed", "fresh activation"])
        precondition(!oldObjects.isValid && freshObjects.isValid, "Reset revived the old object lifetime")
    }
}
