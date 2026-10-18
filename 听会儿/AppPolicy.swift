import Foundation

enum AppPolicy {
    static let playbackSpeedRange = 0.5...2.0

    static func clampedPlaybackSpeed(_ value: Double) -> Double {
        min(max(value, playbackSpeedRange.lowerBound), playbackSpeedRange.upperBound)
    }

    static func shouldShowPhonetic(for studyLanguage: StudyLanguage) -> Bool {
        studyLanguage == .english
    }

    static var podcastExplanationLanguage: LearningLanguage {
        .chinese
    }
}
