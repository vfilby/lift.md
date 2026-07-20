import XCTest
@testable import LiftMark

final class AudioServiceTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceExists() {
        let service = AudioService.shared
        XCTAssertNotNil(service)
    }

    func testSharedInstanceIsSameReference() {
        let first = AudioService.shared
        let second = AudioService.shared
        XCTAssertTrue(first === second)
    }

    // MARK: - Sound File Existence

    func testTickSoundFileExistsInBundle() {
        let url = Bundle.main.url(forResource: "tick", withExtension: "mp3")
        XCTAssertNotNil(url, "tick.mp3 should exist in the app bundle")
    }

    func testCompleteSoundFileExistsInBundle() {
        let url = Bundle.main.url(forResource: "complete", withExtension: "mp3")
        XCTAssertNotNil(url, "complete.mp3 should exist in the app bundle")
    }

    // MARK: - Preload / Unload Lifecycle

    func testPreloadDoesNotCrash() {
        let service = AudioService.shared
        service.preloadSounds()
        // If we reach here without crashing, the test passes.
        // Clean up so other tests start fresh.
        service.unloadSounds()
    }

    func testUnloadDoesNotCrash() {
        let service = AudioService.shared
        service.unloadSounds()
    }

    func testPreloadThenUnloadCycle() {
        let service = AudioService.shared
        service.preloadSounds()
        service.unloadSounds()
        // Second cycle should also work (re-initialization)
        service.preloadSounds()
        service.unloadSounds()
    }

    func testDoublePreloadIsIdempotent() {
        let service = AudioService.shared
        service.preloadSounds()
        service.preloadSounds() // Should be a no-op due to isInitialized guard
        service.unloadSounds()
    }

    // MARK: - Playback (Graceful in Test Environment)

    func testPlayTickDoesNotCrash() {
        let service = AudioService.shared
        // Play without preload — should handle nil player gracefully
        service.playTick()
    }

    func testPlayCompleteDoesNotCrash() {
        let service = AudioService.shared
        // Play without preload — should handle nil player gracefully
        service.playComplete()
    }

    func testPlayAfterUnloadDoesNotCrash() {
        let service = AudioService.shared
        service.preloadSounds()
        service.unloadSounds()
        // Players are nil after unload; playback should handle gracefully
        service.playTick()
        service.playComplete()
    }
}
