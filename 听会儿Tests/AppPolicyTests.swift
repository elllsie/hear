import XCTest
@testable import 听会儿

final class AppPolicyTests: XCTestCase {
    func testPlaybackSpeedIsClampedToSupportedRange() {
        XCTAssertEqual(AppPolicy.clampedPlaybackSpeed(0.1), 0.5)
        XCTAssertEqual(AppPolicy.clampedPlaybackSpeed(1.25), 1.25)
        XCTAssertEqual(AppPolicy.clampedPlaybackSpeed(3.0), 2.0)
    }

    func testOnlyEnglishStudyShowsPhonetics() {
        XCTAssertTrue(AppPolicy.shouldShowPhonetic(for: .english))
        XCTAssertFalse(AppPolicy.shouldShowPhonetic(for: .german))
    }

    func testPodcastExplanationAlwaysDefaultsToChinese() {
        XCTAssertEqual(AppPolicy.podcastExplanationLanguage, .chinese)
    }
}
