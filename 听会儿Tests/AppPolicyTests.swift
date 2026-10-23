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

    func testRemoteWordBookRejectsEmptyAndDuplicateWordIDs() {
        XCTAssertFalse(RemoteWordBookRepository.isValid(words: []))
        let duplicate = [
            Word(id: "1", word: "hello", translation: "你好"),
            Word(id: "1", word: "world", translation: "世界")
        ]
        XCTAssertFalse(RemoteWordBookRepository.isValid(words: duplicate))
    }

    func testRemoteWordBookAcceptsValidWords() {
        let words = [
            Word(id: "1", word: "hello", translation: "你好"),
            Word(id: "2", word: "world", translation: "世界")
        ]
        XCTAssertTrue(RemoteWordBookRepository.isValid(words: words))
    }
}
