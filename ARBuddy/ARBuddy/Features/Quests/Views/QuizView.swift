import SwiftUI

struct QuizView: View {
    let poiId: UUID?
    let poiName: String
    let category: String
    let xpPerQuestion: Int

    @StateObject private var viewModel = QuizViewModel()
    @Environment(\.dismiss) private var dismiss

    init(poiId: UUID? = nil, poiName: String, category: String, xpPerQuestion: Int = 20) {
        self.poiId = poiId
        self.poiName = poiName
        self.category = category
        self.xpPerQuestion = xpPerQuestion
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if viewModel.isLoading {
                    LoadingView()
                } else if let error = viewModel.errorMessage {
                    ErrorView(message: error) {
                        Task {
                            await viewModel.loadQuiz()
                        }
                    }
                } else if viewModel.showIntro, viewModel.quiz != nil {
                    QuizIntroView(
                        poiName: poiName,
                        description: viewModel.quiz?.description,
                        questionCount: viewModel.quiz?.questionCount ?? 5,
                        onStart: {
                            viewModel.startQuiz()
                        }
                    )
                } else if viewModel.isQuizComplete, let result = viewModel.quizResult {
                    QuizResultView(result: result) {
                        dismiss()
                    }
                } else if let question = viewModel.currentQuestion {
                    QuizQuestionView(
                        question: question,
                        questionNumber: viewModel.currentQuestionIndex + 1,
                        totalQuestions: viewModel.quiz?.questionCount ?? 0,
                        selectedAnswerIndex: viewModel.selectedAnswerIndex,
                        isAnswerRevealed: viewModel.isAnswerRevealed,
                        onSelectAnswer: { index in
                            viewModel.selectAnswer(index)
                        },
                        onNext: {
                            viewModel.nextQuestion()
                        }
                    )
                } else {
                    // Empty state
                    ContentUnavailableView(
                        "Quiz nicht verfügbar",
                        systemImage: "questionmark.circle",
                        description: Text("Das Quiz konnte nicht geladen werden.")
                    )
                }
            }
            .navigationTitle(poiName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            viewModel.configure(poiId: poiId, poiName: poiName, category: category, xpPerQuestion: xpPerQuestion)
            Task {
                await viewModel.loadQuiz()
            }
        }
    }
}

// MARK: - Loading View
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text("Quiz wird generiert...")
                    .font(.headline)

                Text("Bitte warten")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Error View
struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("Fehler")
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Erneut versuchen") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Quiz Question View
struct QuizQuestionView: View {
    let question: QuizQuestion
    let questionNumber: Int
    let totalQuestions: Int
    let selectedAnswerIndex: Int?
    let isAnswerRevealed: Bool
    let onSelectAnswer: (Int) -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Progress Header
            VStack(spacing: 12) {
                // Progress bar
                ProgressView(value: Double(questionNumber - 1), total: Double(totalQuestions))
                    .progressViewStyle(.linear)
                    .tint(.blue)

                // Question counter
                HStack {
                    Text("Frage \(questionNumber) von \(totalQuestions)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
            .padding()
            .background(Color(.systemBackground))

            ScrollView {
                VStack(spacing: 24) {
                    // Question
                    Text(question.question)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemBackground))
                        )
                        .padding(.horizontal)
                        .padding(.top)

                    // Answers
                    VStack(spacing: 12) {
                        ForEach(Array(question.answers.enumerated()), id: \.offset) { index, answer in
                            AnswerButton(
                                answer: answer,
                                index: index,
                                isSelected: selectedAnswerIndex == index,
                                isCorrect: question.correctAnswerIndex == index,
                                isRevealed: isAnswerRevealed
                            ) {
                                onSelectAnswer(index)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Explanation after answer reveal
                    if isAnswerRevealed, let explanation = question.explanation, !explanation.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                                .font(.title3)

                            Text(explanation)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.yellow.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer(minLength: 100)
                }
            }

            // Bottom button
            if isAnswerRevealed {
                VStack {
                    Divider()

                    Button {
                        onNext()
                    } label: {
                        Text(questionNumber < totalQuestions ? "Nächste Frage" : "Ergebnis anzeigen")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding()
                }
                .background(Color(.systemBackground))
            }
        }
    }
}

// MARK: - Answer Button
struct AnswerButton: View {
    let answer: String
    let index: Int
    let isSelected: Bool
    let isCorrect: Bool
    let isRevealed: Bool
    let action: () -> Void

    private var backgroundColor: Color {
        guard isRevealed else {
            return isSelected ? Color.blue.opacity(0.1) : Color(.systemBackground)
        }

        if isCorrect {
            return Color.green.opacity(0.2)
        } else if isSelected {
            return Color.red.opacity(0.2)
        }
        return Color(.systemBackground)
    }

    private var borderColor: Color {
        guard isRevealed else {
            return isSelected ? Color.blue : Color(.systemGray4)
        }

        if isCorrect {
            return Color.green
        } else if isSelected {
            return Color.red
        }
        return Color(.systemGray4)
    }

    private var indicatorIcon: String? {
        guard isRevealed else { return nil }

        if isCorrect {
            return "checkmark.circle.fill"
        } else if isSelected {
            return "xmark.circle.fill"
        }
        return nil
    }

    private var indicatorColor: Color {
        if isCorrect {
            return .green
        } else {
            return .red
        }
    }

    private var answerLetter: String {
        let letters = ["A", "B", "C", "D"]
        return index < letters.count ? letters[index] : ""
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Letter indicator
                Text(answerLetter)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isSelected && !isRevealed ? Color.blue : Color.gray)
                    )

                // Answer text
                Text(answer)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)

                Spacer()

                // Result indicator
                if let icon = indicatorIcon {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(indicatorColor)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: 2)
            )
        }
        .disabled(isRevealed)
    }
}

// MARK: - Quiz Result View
struct QuizResultView: View {
    let result: QuizResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Result icon
            ZStack {
                Circle()
                    .fill(resultColor.opacity(0.2))
                    .frame(width: 120, height: 120)

                Image(systemName: resultIcon)
                    .font(.system(size: 60))
                    .foregroundColor(resultColor)
            }

            // Result message
            VStack(spacing: 8) {
                Text(result.resultMessage)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("\(result.correctAnswers) von \(result.totalQuestions) Fragen richtig")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            // XP earned
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)

                Text("+\(result.xpEarned) XP")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.yellow.opacity(0.1))
            )

            // Stats
            HStack(spacing: 40) {
                StatItem(
                    title: "Richtig",
                    value: "\(result.correctAnswers)",
                    color: .green
                )

                StatItem(
                    title: "Falsch",
                    value: "\(result.totalQuestions - result.correctAnswers)",
                    color: .red
                )

                StatItem(
                    title: "Quote",
                    value: "\(Int(result.percentage))%",
                    color: .blue
                )
            }

            Spacer()

            // Done button
            Button(action: onDismiss) {
                Text("Fertig")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    private var resultColor: Color {
        switch result.percentage {
        case 80...100:
            return .green
        case 60..<80:
            return .blue
        case 40..<60:
            return .orange
        default:
            return .red
        }
    }

    private var resultIcon: String {
        switch result.percentage {
        case 100:
            return "crown.fill"
        case 80..<100:
            return "star.fill"
        case 60..<80:
            return "hand.thumbsup.fill"
        case 40..<60:
            return "face.smiling"
        default:
            return "arrow.up.circle.fill"
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Quiz Intro View
struct QuizIntroView: View {
    let poiName: String
    let description: String?
    let questionCount: Int
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 20)

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 100, height: 100)

                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)
                }

                // Title
                Text(poiName)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Description
                if let description = description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Quiz info
                HStack(spacing: 24) {
                    Label("\(questionCount) Fragen", systemImage: "list.number")
                    Label("Multiple Choice", systemImage: "checkmark.circle")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                Spacer(minLength: 40)

                // Start button
                Button(action: onStart) {
                    Text("Quiz starten")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }
}

#Preview {
    QuizView(poiName: "Brandenburger Tor", category: "Sehenswürdigkeit")
}
