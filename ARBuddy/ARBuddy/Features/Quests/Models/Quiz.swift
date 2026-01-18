import Foundation

// MARK: - Quiz Question
struct QuizQuestion: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    let question: String
    let answers: [String]
    let correctAnswerIndex: Int

    enum CodingKeys: String, CodingKey {
        case question, answers, correctAnswerIndex
    }

    nonisolated init(id: UUID = UUID(), question: String, answers: [String], correctAnswerIndex: Int) {
        self.id = id
        self.question = question
        self.answers = answers
        self.correctAnswerIndex = correctAnswerIndex
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.question = try container.decode(String.self, forKey: .question)
        self.answers = try container.decode([String].self, forKey: .answers)
        self.correctAnswerIndex = try container.decode(Int.self, forKey: .correctAnswerIndex)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(answers, forKey: .answers)
        try container.encode(correctAnswerIndex, forKey: .correctAnswerIndex)
    }

    var correctAnswer: String {
        guard correctAnswerIndex >= 0 && correctAnswerIndex < answers.count else {
            return answers.first ?? ""
        }
        return answers[correctAnswerIndex]
    }

    func isCorrect(answerIndex: Int) -> Bool {
        return answerIndex == correctAnswerIndex
    }
}

// MARK: - Quiz
struct Quiz: Codable {
    let questions: [QuizQuestion]

    var questionCount: Int {
        questions.count
    }
}

// MARK: - Quiz Result
struct QuizResult {
    let totalQuestions: Int
    let correctAnswers: Int
    let xpEarned: Int
    let poiName: String

    var percentage: Double {
        guard totalQuestions > 0 else { return 0 }
        return Double(correctAnswers) / Double(totalQuestions) * 100
    }

    var isPerfect: Bool {
        correctAnswers == totalQuestions
    }

    var resultMessage: String {
        switch percentage {
        case 100:
            return "Perfekt! Du bist ein Experte!"
        case 80..<100:
            return "Sehr gut! Fast alles richtig!"
        case 60..<80:
            return "Gut gemacht!"
        case 40..<60:
            return "Nicht schlecht, aber da geht mehr!"
        default:
            return "Übe weiter, du schaffst das!"
        }
    }
}
