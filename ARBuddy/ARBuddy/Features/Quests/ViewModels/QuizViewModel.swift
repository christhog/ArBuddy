import Foundation
import Combine

@MainActor
class QuizViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var quiz: Quiz?
    @Published var currentQuestionIndex = 0
    @Published var selectedAnswerIndex: Int?
    @Published var isAnswerRevealed = false
    @Published var correctAnswersCount = 0
    @Published var isQuizComplete = false
    @Published var quizResult: QuizResult?

    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private let supabaseService = SupabaseService.shared
    private var poiId: UUID?
    private var poiName: String = ""
    private var category: String = ""
    private var xpPerQuestion: Int = 20

    // MARK: - Computed Properties

    var currentQuestion: QuizQuestion? {
        guard let quiz = quiz,
              currentQuestionIndex < quiz.questions.count else {
            return nil
        }
        return quiz.questions[currentQuestionIndex]
    }

    var progress: Double {
        guard let quiz = quiz, quiz.questionCount > 0 else { return 0 }
        return Double(currentQuestionIndex) / Double(quiz.questionCount)
    }

    var progressText: String {
        guard let quiz = quiz else { return "" }
        return "\(currentQuestionIndex + 1) / \(quiz.questionCount)"
    }

    var isCorrectAnswer: Bool {
        guard let selectedIndex = selectedAnswerIndex,
              let question = currentQuestion else { return false }
        return question.isCorrect(answerIndex: selectedIndex)
    }

    var canProceed: Bool {
        isAnswerRevealed
    }

    var totalXPEarnable: Int {
        guard let quiz = quiz else { return 0 }
        return quiz.questionCount * xpPerQuestion
    }

    // MARK: - Initialization

    func configure(poiId: UUID? = nil, poiName: String, category: String, xpPerQuestion: Int = 20) {
        self.poiId = poiId
        self.poiName = poiName
        self.category = category
        self.xpPerQuestion = xpPerQuestion
    }

    // MARK: - Quiz Loading

    func loadQuiz() async {
        guard !poiName.isEmpty else {
            errorMessage = "Kein POI Name angegeben"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            if let poiId = poiId {
                // Neuer Pfad: nutzt poiId, aktualisiert pois Tabelle
                quiz = try await supabaseService.generateQuiz(poiId: poiId)
            } else {
                // Legacy Fallback für Quizzes ohne POI-Zuordnung
                quiz = try await supabaseService.generateQuiz(
                    poiName: poiName,
                    category: category
                )
            }
        } catch {
            errorMessage = "Quiz konnte nicht geladen werden. Bitte prüfe deine Internetverbindung."
            print("Failed to load quiz: \(error)")
        }

        isLoading = false
    }

    // MARK: - Quiz Interaction

    func selectAnswer(_ index: Int) {
        guard !isAnswerRevealed else { return }

        selectedAnswerIndex = index
        isAnswerRevealed = true

        if let question = currentQuestion, question.isCorrect(answerIndex: index) {
            correctAnswersCount += 1
        }
    }

    func nextQuestion() {
        guard let quiz = quiz else { return }

        if currentQuestionIndex + 1 < quiz.questionCount {
            currentQuestionIndex += 1
            selectedAnswerIndex = nil
            isAnswerRevealed = false
        } else {
            completeQuiz()
        }
    }

    private func completeQuiz() {
        guard let quiz = quiz else { return }

        let earnedXP = correctAnswersCount * xpPerQuestion

        quizResult = QuizResult(
            totalQuestions: quiz.questionCount,
            correctAnswers: correctAnswersCount,
            xpEarned: earnedXP,
            poiName: poiName
        )

        isQuizComplete = true

        // Save to Supabase
        Task {
            await saveQuizResult(xpEarned: earnedXP)
        }
    }

    private func saveQuizResult(xpEarned: Int) async {
        do {
            // If we have a POI ID, use completePOIQuest to save all progress data
            if let poiId = poiId {
                try await supabaseService.completePOIQuest(
                    poiId: poiId,
                    questType: "quiz",
                    xpEarned: xpEarned,
                    quizScore: correctAnswersCount
                )
                print("Quiz result saved for POI: \(poiName)")
            } else if xpEarned > 0 {
                // Legacy fallback: just add XP
                try await supabaseService.addXP(xpEarned)
                print("XP added (legacy path): \(xpEarned)")
            }
        } catch {
            print("Failed to save quiz result: \(error)")
        }
    }

    // MARK: - Reset

    func reset() {
        quiz = nil
        currentQuestionIndex = 0
        selectedAnswerIndex = nil
        isAnswerRevealed = false
        correctAnswersCount = 0
        isQuizComplete = false
        quizResult = nil
        isLoading = false
        errorMessage = nil
    }
}
