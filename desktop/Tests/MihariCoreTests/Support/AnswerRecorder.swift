import Foundation

/// テストから `@Sendable` な `onAnswer` コールバックの結果を受け取るための入れ物。
///
/// テスト内では常に同期的に呼ばれるとわかっているため `@unchecked Sendable` にしている。
final class AnswerRecorder: @unchecked Sendable {
    private(set) var answers: [Bool] = []

    var lastAnswer: Bool? { answers.last }

    func record(_ answer: Bool) {
        answers.append(answer)
    }
}
