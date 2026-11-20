import XCTest
@testable import TunerDSP

@MainActor private final class TransitionLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor final class AudioLifecycleTests: XCTestCase {
    func testPermissionPromptPreservesIntentButWaitsForForeground() async {
        let state = AudioLifecycle()
        let token = state.beginStart()
        state.beginPrompt(token: token)
        XCTAssertFalse(state.updateActivity(.inactive))
        XCTAssertEqual(state.generation, token)
        XCTAssertEqual(state.finishPermission(token: token, granted: true), .granted)
        let start = Task { await state.waitForForeground(token: token) }
        for _ in 0..<100 where state.foregroundWaiterCount == 0 { await Task.yield() }
        XCTAssertEqual(state.foregroundWaiterCount, 1)
        XCTAssertFalse(state.updateActivity(.active))
        let result1 = await start.value
        XCTAssertTrue(result1)
    }
    func testBackgroundAndExplicitStopCancelPermissionIntent() async {
        for background in [false, true] {
            let state = AudioLifecycle()
            let token = state.beginStart()
            state.beginPrompt(token: token)
            _ = state.updateActivity(.inactive)
            if background { XCTAssertTrue(state.updateActivity(.background)) }
            else { state.cancelStart() }
            XCTAssertEqual(state.finishPermission(token: token, granted: true), .cancelled)
            _ = state.updateActivity(.active)
            let result2 = await state.waitForForeground(token: token)
            XCTAssertFalse(result2)
        }
    }
    func testDeniedPermissionAndSupersededCallbacksCannotActivate() async {
        let state = AudioLifecycle()
        let denied = state.beginStart()
        state.beginPrompt(token: denied)
        XCTAssertEqual(state.finishPermission(token: denied, granted: false), .denied)
        let result3 = await state.waitForForeground(token: denied)
        XCTAssertFalse(result3)
        let old = state.beginStart()
        state.beginPrompt(token: old)
        let new = state.beginStart()
        state.beginPrompt(token: new)
        XCTAssertEqual(state.finishPermission(token: old, granted: true), .cancelled)
        XCTAssertTrue(state.systemPromptPending)
        XCTAssertEqual(state.finishPermission(token: new, granted: true), .granted)
        let result4 = await state.waitForForeground(token: new)
        XCTAssertTrue(result4)
    }
    func testRunningInactivityCancelsAndCannotAutoResume() async {
        let state = AudioLifecycle()
        let token = state.beginStart()
        let result5 = await state.waitForForeground(token: token)
        XCTAssertTrue(result5)
        XCTAssertTrue(state.updateActivity(.inactive))
        XCTAssertFalse(state.updateActivity(.active))
        let result6 = await state.waitForForeground(token: token)
        XCTAssertFalse(result6)
    }
    func testRunningCaptureSurvivesWristAndBackgroundTransitionsUntilExplicitStop() async {
        let state = AudioLifecycle()
        let token = state.beginStart()
        let started = await state.waitForForeground(token: token)
        XCTAssertTrue(started)
        for _ in 0..<20 {
            XCTAssertFalse(state.updateActivity(.inactive, runningCapture: true))
            XCTAssertFalse(state.updateActivity(.background, runningCapture: true))
            XCTAssertEqual(state.generation, token)
            XCTAssertFalse(state.updateActivity(.active, runningCapture: true))
        }
        state.cancelStart()
        _ = state.updateActivity(.active)
        let resumed = await state.waitForForeground(token: token)
        XCTAssertFalse(resumed, "Stop must remain explicit and irreversible without a new Start")
    }
    func testBackgroundWithoutRunningCaptureCancelsPendingStart() async {
        let state = AudioLifecycle()
        let token = state.beginStart()
        state.beginPrompt(token: token)
        XCTAssertFalse(state.updateActivity(.inactive))
        XCTAssertTrue(state.updateActivity(.background, runningCapture: false))
        XCTAssertEqual(state.finishPermission(token: token, granted: true), .cancelled)
        _ = state.updateActivity(.active)
        let resumed = await state.waitForForeground(token: token)
        XCTAssertFalse(resumed)
    }
    func testCancelledForegroundWaitIsReleased() async {
        let state = AudioLifecycle()
        let token = state.beginStart()
        state.beginPrompt(token: token)
        _ = state.updateActivity(.inactive)
        state.endPrompt(token: token)
        let waiting = Task { await state.waitForForeground(token: token) }
        for _ in 0..<100 where state.foregroundWaiterCount == 0 { await Task.yield() }
        XCTAssertEqual(state.foregroundWaiterCount, 1)
        state.cancelStart()
        let result7 = await waiting.value
        XCTAssertFalse(result7)
        XCTAssertEqual(state.foregroundWaiterCount, 0)
    }
    func testRestartWaitsForEntireQueuedShutdownWithoutTimingSleeps() async {
        let state = AudioLifecycle(), fade = TransitionLatch()
        var events: [String] = []
        state.enqueueShutdown { events.append("fade"); await fade.wait(); events.append("deactivated") }
        let restart = Task { await state.waitForShutdown(); events.append("activated") }
        for _ in 0..<100 where !fade.waiting { await Task.yield() }
        XCTAssertEqual(events, ["fade"])
        fade.release()
        await restart.value
        XCTAssertEqual(events, ["fade", "deactivated", "activated"])
        state.enqueueShutdown { events.append("stop-one") }
        state.enqueueShutdown { events.append("stop-two") }
        await state.waitForShutdown()
        XCTAssertEqual(Array(events.suffix(2)), ["stop-one", "stop-two"])
    }
    func testRouteMetadataIsIgnoredButActualRouteOrFormatLossStops() {
        let speaker = AudioRouteState(inputIDs: [], outputIDs: ["speaker"], sampleRate: 48000, outputChannels: 1)
        XCTAssertFalse(AudioRoutePolicy.shouldStop(previous: speaker, current: speaker, event: .changed))
        let bluetooth = AudioRouteState(inputIDs: [], outputIDs: ["headphones"], sampleRate: 48000, outputChannels: 1)
        XCTAssertTrue(AudioRoutePolicy.shouldStop(previous: speaker, current: bluetooth, event: .changed))
        let changedFormat = AudioRouteState(inputIDs: [], outputIDs: ["speaker"], sampleRate: 44100, outputChannels: 1)
        XCTAssertTrue(AudioRoutePolicy.shouldStop(previous: speaker, current: changedFormat, event: .changed))
        XCTAssertTrue(AudioRoutePolicy.shouldStop(previous: speaker, current: speaker, event: .lostDevice))
        XCTAssertTrue(AudioRoutePolicy.shouldStop(previous: speaker, current: speaker, event: .noSuitableRoute))
    }
}
