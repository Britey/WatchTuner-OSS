import XCTest

@MainActor final class WatchTunerUITests: XCTestCase {
    private func dismissProfiles(_ app: XCUIApplication) {
        let done = app.buttons["profiles-done"]
        for _ in 0..<6 { if done.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(done.isHittable); done.tap()
    }
    private func openProfiles(_ app: XCUIApplication) {
        let button = app.buttons["profile-settings"]
        for _ in 0..<4 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable); button.tap()
        XCTAssertTrue(app.buttons["profile-Vocals"].waitForExistence(timeout: 5))
    }
    func testProfileLongPressSelectionPersistenceAndAlternateEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["-tunerProfile", "Vocals", "-pitchAlgorithm", "Current"]
        app.launch()
        let settings = app.buttons["profile-settings"]
        XCTAssertEqual(settings.value as? String, "Vocals")
        let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 10))
        reading.press(forDuration: 1)
        XCTAssertTrue(app.buttons["profile-Piano"].waitForExistence(timeout: 5))
        app.buttons["profile-Piano"].tap()
        XCTAssertEqual(app.buttons["profile-Piano"].value as? String, "Selected")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Piano profile settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        dismissProfiles(app)
        XCTAssertEqual(settings.value as? String, "Piano")
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "Piano")
        openProfiles(app)
        app.buttons["profile-Guitar"].tap()
        dismissProfiles(app)
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "Guitar")
        openProfiles(app)
        app.buttons["profile-Vocals"].tap()
        dismissProfiles(app)
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "Vocals")
    }
    func testLiveProfileSwitchUsesSyntheticInputAndKeepsModeExclusion() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-tuner", "-tunerProfile", "Vocals", "-pitchAlgorithm", "Current"]
        app.launch()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
        func waitForPitch() {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "220."), object: reading)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        }
        waitForPitch()
        let tunerScreenshot = XCTAttachment(screenshot: app.screenshot())
        tunerScreenshot.name = "Vocals tuner with synthetic input"; tunerScreenshot.lifetime = .keepAlways; add(tunerScreenshot)
        openProfiles(app)
        app.buttons["profile-Piano"].tap()
        dismissProfiles(app)
        XCTAssertTrue(app.buttons["Stop"].exists)
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "Piano")
        waitForPitch()
        app.buttons["Tone"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop"].exists)
        app.buttons["Tuner"].tap()
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "Piano")
        XCTAssertNotEqual(reading.value as? String, "220.0 Hz")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        waitForPitch()
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
    }

    func testPitchySettingsIgnoreLegacyDetectorChoiceAndKeepProfiles() {
        let app = XCUIApplication()
        // A pre-comparison saved choice must not restore a different engine.
        app.launchArguments = ["--synthetic-tuner", "-tunerProfile", "Piano", "-pitchAlgorithm", "Current"]
        app.launch()
        app.buttons["Start"].tap()
        let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
        for profile in ["Piano", "Guitar", "Vocals"] {
            openProfiles(app)
            XCTAssertEqual(app.staticTexts["detector-build"].label, "Pitchy")
            for code in 0...3 { XCTAssertFalse(app.buttons["algorithm-\(code)"].exists) }
            XCTAssertFalse(app.staticTexts["Detector"].exists)
            app.buttons["profile-\(profile)"].tap()
            dismissProfiles(app)
            XCTAssertEqual(app.buttons["profile-settings"].value as? String, profile)
            XCTAssertTrue(app.buttons["Stop"].exists)
            let pitch = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "220."), object: reading)
            XCTAssertEqual(XCTWaiter.wait(for: [pitch], timeout: 10), .completed)
        }
        app.buttons["Stop"].tap()
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["Start"].exists)
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "Vocals")
    }

    func testUnknownTimestampRetryRecoversWithIndependentLargerBuffers() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-tuner", "--synthetic-invalid-timestamps", "-tunerProfile", "Vocals", "-pitchAlgorithm", "Current"]
        app.launch()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.staticTexts["Listening • slower updates"].waitForExistence(timeout: 5))
        let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
        let pitch = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "220."), object: reading)
        XCTAssertEqual(XCTWaiter.wait(for: [pitch], timeout: 5), .completed)
        app.buttons["Tone"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop"].exists)
    }
    func testQuiet440HzUsesTheRealTunerPipeline() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-tuner", "--synthetic-quiet-input", "-tunerProfile", "Vocals", "-pitchAlgorithm", "Current"]
        app.launch()
        app.buttons["Start"].tap()
        let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "440."), object: reading)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(reading.value as? String, "440.0 Hz")
    }
    func testLowWatchSpeakerTonePlaysWithGuidanceAndKeepsExactFrequency() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-low-watch-tone"]
        app.launch()
        app.buttons["Tone"].tap()
        XCTAssertEqual(app.staticTexts["frequency-value"].value as? String, "220")
        XCTAssertTrue(app.staticTexts["tone-output-guidance"].label.contains("weak or inaudible"))
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["frequency-value"].value as? String, "220")
        app.buttons["Decrease frequency"].tap()
        XCTAssertEqual(app.staticTexts["frequency-value"].value as? String, "219")
        XCTAssertTrue(app.buttons["Stop"].exists)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
    }
    func testToneCrownIgnoresBumpsAndButtonsKeepOneHertzSteps() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Tone"].tap()
        let frequency = app.staticTexts["frequency-value"]
        func rotateAndExpectChange() {
            let previous = frequency.value as? String ?? ""
            XCUIDevice.shared.rotateDigitalCrown(delta: 1.0)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", previous), object: frequency)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            XCTAssertTrue(frequency.isHittable)
        }
        XCTAssertEqual(frequency.value as? String, "440")
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.1)
        XCTAssertEqual(frequency.value as? String, "440", "A small bump must not retune")
        rotateAndExpectChange()
        // Pass the old finite axis limit repeatedly; continuing clockwise must
        // never wrap or undo the frequency when the native control goes idle.
        for _ in 0..<3 {
            let previous = Int(frequency.value as? String ?? "")!
            XCUIDevice.shared.rotateDigitalCrown(delta: 3)
            XCTAssertGreaterThan(Int(frequency.value as? String ?? "")!, previous)
        }
        let beforeReverse = Int(frequency.value as? String ?? "")!
        XCUIDevice.shared.rotateDigitalCrown(delta: -1)
        XCTAssertLessThan(Int(frequency.value as? String ?? "")!, beforeReverse)
        for name in ["Decrease frequency", "Increase frequency"] {
            XCTAssertGreaterThanOrEqual(app.buttons[name].frame.width, 44)
            XCTAssertGreaterThanOrEqual(app.buttons[name].frame.height, 44)
        }
        let before = Int(frequency.value as? String ?? "")!
        app.buttons["Increase frequency"].tap()
        XCTAssertEqual(Int(frequency.value as? String ?? ""), before + 1)
        app.buttons["Decrease frequency"].tap()
        XCTAssertEqual(Int(frequency.value as? String ?? ""), before)
        app.buttons["preset-1000"].tap()
        XCTAssertEqual(frequency.value as? String, "1000")
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.1)
        XCTAssertEqual(frequency.value as? String, "1000")
        rotateAndExpectChange()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        let playing = frequency.value as? String
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.1)
        XCTAssertEqual(frequency.value as? String, playing)
        rotateAndExpectChange()
        app.buttons["Stop"].tap()
        app.buttons["Tuner"].tap()
        app.buttons["Tone"].tap()
        rotateAndExpectChange()
    }
    func testStartedTunerSurvivesInactiveBackgroundAndReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-tuner", "--synthetic-wrist-cycle", "-tunerProfile", "Piano", "-pitchAlgorithm", "Current"]
        app.launch()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.staticTexts["Listening • wrist cycle verified"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Stop"].exists)
        let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
        let pitch = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "220."), object: reading)
        XCTAssertEqual(XCTWaiter.wait(for: [pitch], timeout: 5), .completed)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["Start"].exists)
        XCTAssertFalse(app.buttons["Stop"].exists)
    }
    func testFooterButtonFitsEveryModeWhenStoppedAndRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-tuner", "-pitchAlgorithm", "Current"]
        app.launch()
        func verify(_ label: String) {
            let button = app.buttons["audio-toggle"]
            XCTAssertEqual(button.label, label)
            XCTAssertTrue(button.isHittable)
            XCTAssertLessThanOrEqual(button.frame.width, 140.5)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 23)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 23)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY - 7)
        }
        for mode in ["Tuner", "Tone", "Metronome"] {
            app.buttons[mode].tap()
            verify("Start")
            if mode == "Tuner" {
                let reading = app.descendants(matching: .any).matching(identifier: "tuner-reading").firstMatch
                XCTAssertLessThanOrEqual(reading.frame.maxY, app.buttons["audio-toggle"].frame.minY - 1,
                                         "The complete tuner reading must fit above the footer")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Narrow footer - \(mode)"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["audio-toggle"].tap()
            XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
            verify("Stop")
            app.buttons["audio-toggle"].tap()
            XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        }
    }
    func testUnknownTimestampRetryExhaustionStopsAndAllowsExplicitRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-tuner", "--synthetic-invalid-timestamps", "--synthetic-ignore-larger-tap", "-tunerProfile", "Vocals", "-pitchAlgorithm", "Current"]
        app.launch()
        for _ in 0..<2 {
            app.buttons["Start"].tap()
            XCTAssertTrue(app.staticTexts["Microphone timing unavailable. Tap Start to retry."].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Start"].exists)
            XCTAssertFalse(app.buttons["Stop"].exists)
        }
    }

    func testMetronomeLargeAdjustmentButtons() {
        let app = XCUIApplication()
        app.launch(); app.buttons["Metronome"].tap()
        func reveal(_ element: XCUIElement) {
            // A partially visible row beneath the fixed footer needs scrolling.
            for _ in 0..<4 {
                if element.isHittable && element.frame.maxY <= app.buttons["audio-toggle"].frame.minY { break }
                app.swipeUp()
            }
        }
        for name in ["Increase tempo", "Decrease tempo", "More beats per bar", "Fewer beats per bar"] {
            let button = app.buttons[name]
            reveal(button)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        reveal(app.buttons["More beats per bar"])
        XCTAssertLessThanOrEqual(app.staticTexts["beat-value"].frame.maxY,
                                 app.buttons["audio-toggle"].frame.minY - 6)
        app.buttons["More beats per bar"].tap()
        XCTAssertEqual(app.staticTexts["bar-value"].value as? String, "5")
        app.buttons["Fewer beats per bar"].tap()
        XCTAssertEqual(app.staticTexts["bar-value"].value as? String, "4")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Metronome enlarged bar controls"; shot.lifetime = .keepAlways; add(shot)
        if !app.buttons["Increase tempo"].isHittable { app.swipeDown() }
        app.buttons["Increase tempo"].tap()
        XCTAssertEqual(app.staticTexts["bpm-value"].value as? String, "121")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        app.buttons["Decrease tempo"].tap()
        XCTAssertEqual(app.staticTexts["bpm-value"].value as? String, "120")
        XCTAssertTrue(app.buttons["Stop"].exists)
        app.buttons["Stop"].tap()
    }

    func testMetronomeCrownAfterToneReleasesSequencer() {
        let app = XCUIApplication()
        app.launch(); app.buttons["Tone"].tap()
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.1)
        XCTAssertEqual(app.staticTexts["frequency-value"].value as? String, "440")
        app.buttons["Metronome"].tap()
        let bpm = app.staticTexts["bpm-value"]
        XCTAssertEqual(bpm.value as? String, "120")
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.2)
        XCTAssertNotEqual(bpm.value as? String, "120")
        XCTAssertTrue(app.buttons["Start"].exists)
    }

    func testMetronomeTempoBeatAndModeExclusion() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Metronome"].waitForExistence(timeout: 10))
        app.buttons["Metronome"].tap()
        XCTAssertEqual(app.staticTexts["bpm-value"].value as? String, "120")
        app.buttons["Increase tempo"].tap()
        XCTAssertEqual(app.staticTexts["bpm-value"].value as? String, "121")
        app.buttons["More beats per bar"].tap()
        XCTAssertEqual(app.staticTexts["bar-value"].value as? String, "5")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        app.buttons["Decrease tempo"].tap()
        XCTAssertEqual(app.staticTexts["bpm-value"].value as? String, "120")
        XCTAssertTrue(app.buttons["Stop"].exists)
        let beat = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "0"), object: app.staticTexts["beat-value"])
        XCTAssertEqual(XCTWaiter.wait(for: [beat], timeout: 5), .completed)
        let fifthBeat = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "5"), object: app.staticTexts["beat-value"])
        XCTAssertEqual(XCTWaiter.wait(for: [fifthBeat], timeout: 5), .completed)
        app.buttons["Fewer beats per bar"].tap()
        XCTAssertEqual(app.staticTexts["bar-value"].value as? String, "4")
        let newDownbeat = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: app.staticTexts["beat-value"])
        XCTAssertEqual(XCTWaiter.wait(for: [newDownbeat], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Beat 1 of 4"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Metronome playing"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Tone"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop"].exists)
        app.buttons["Metronome"].tap()
        XCTAssertEqual(app.staticTexts["beat-value"].value as? String, "0")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
    }

    func testToneStartStopAndModeExclusion() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Tone"].waitForExistence(timeout: 10))
        app.buttons["Tone"].tap()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        let playing = XCTAttachment(screenshot: app.screenshot())
        playing.name = "Tone playing in simulator"; playing.lifetime = .keepAlways; add(playing)
        app.buttons["Tuner"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop"].exists)
        app.buttons["Tone"].tap()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            app.buttons["Stop"].tap()
            XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
            app.buttons["Start"].tap()
            XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        }
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
    }

    func testModesFrequencyAndFreshLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Tuner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Tone"].exists)
        XCTAssertTrue(app.buttons["Start"].isHittable)
        let tuner = XCTAttachment(screenshot: app.screenshot())
        tuner.name = "Tuner initial screen"; tuner.lifetime = .keepAlways; add(tuner)
        app.buttons["Tone"].tap()
        XCTAssertTrue(app.staticTexts["frequency-value"].waitForExistence(timeout: 5))
        let preset = app.buttons["preset-1000"]
        for _ in 0..<4 { if preset.isHittable { break }; app.swipeUp() }
        preset.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1000"), object: app.staticTexts["frequency-value"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        if !app.staticTexts["frequency-value"].isHittable { app.swipeDown() }
        XCTAssertEqual(app.staticTexts["frequency-value"].value as? String, "1000")
        XCTAssertTrue(app.buttons["Start"].isHittable)
        let tone = XCTAttachment(screenshot: app.screenshot())
        tone.name = "Tone 1000 Hz"; tone.lifetime = .keepAlways; add(tone)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Tuner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start"].exists)
        XCTAssertFalse(app.buttons["Stop"].exists)
    }
}
