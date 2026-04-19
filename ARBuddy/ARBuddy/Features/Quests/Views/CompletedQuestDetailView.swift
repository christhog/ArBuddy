//
//  CompletedQuestDetailView.swift
//  ARBuddy
//
//  Created by Chris Greve on 31.01.26.
//

import SwiftUI

struct CompletedQuestDetailView: View {
    let entry: CompletedQuestEntry

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header with category icon and completion badge
                headerSection

                // POI Name and City
                poiInfoSection

                // Description
                if let description = entry.pois.description, !description.isEmpty {
                    descriptionSection(description)
                }

                // AI Facts "Wusstest du schon?"
                if let facts = entry.pois.aiFacts, !facts.isEmpty {
                    factsSection(facts)
                }

                // Quiz Introduction (collapsible)
                if entry.quizCompleted, let quizIntro = entry.pois.effectiveQuizDescription {
                    quizIntroSection(quizIntro)
                }

                // Completion Summary
                completionSummarySection
            }
            .padding()
        }
        .navigationTitle("Quest-Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 100, height: 100)

            Image(systemName: categoryIcon)
                .font(.system(size: 40))
                .foregroundColor(.green)

            // Completion checkmark
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)
                .background(Circle().fill(Color.white).frame(width: 24, height: 24))
                .offset(x: 35, y: 35)
        }
    }

    // MARK: - POI Info Section

    private var poiInfoSection: some View {
        VStack(spacing: 4) {
            Text(entry.pois.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            if let city = entry.pois.city {
                Text(city)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Description Section

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Beschreibung")
                .font(.headline)
                .foregroundColor(.primary)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Facts Section

    private func factsSection(_ facts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Wusstest du schon?")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(facts, id: \.self) { fact in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.top, 4)
                        Text(fact)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Quiz Intro Section

    private func quizIntroSection(_ quizIntro: String) -> some View {
        DisclosureGroup {
            Text(quizIntro)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "text.book.closed.fill")
                    .foregroundColor(.blue)
                Text("Beschreibung")
                    .font(.headline)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Completion Summary Section

    private var completionSummarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Abschluss-Zusammenfassung")
                .font(.headline)

            // Quest type badges
            HStack(spacing: 12) {
                QuestTypeBadge(
                    type: "Besuchen",
                    icon: "mappin.circle",
                    isCompleted: entry.visitCompleted
                )
                QuestTypeBadge(
                    type: "Foto",
                    icon: "camera",
                    isCompleted: entry.photoCompleted
                )
                QuestTypeBadge(
                    type: "AR",
                    icon: "arkit",
                    isCompleted: entry.arCompleted
                )
                QuestTypeBadge(
                    type: "Quiz",
                    icon: "questionmark.circle",
                    isCompleted: entry.quizCompleted
                )
            }

            Divider()

            // Quiz result if available
            if entry.quizCompleted, let score = entry.quizScore {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                    Text("Quiz-Ergebnis:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(score)/5 richtig")
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
            }

            // Completion date
            if let date = entry.updatedAt {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.secondary)
                    Text("Abgeschlossen am:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(date, style: .date)
                        .fontWeight(.medium)
                }
            }

            // XP earned
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.orange)
                Text("XP verdient:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("+\(entry.xpEarned) XP")
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
            }

            // Completion status
            HStack {
                Image(systemName: entry.completedCount == 4 ? "checkmark.seal.fill" : "circle.lefthalf.filled")
                    .foregroundColor(entry.completedCount == 4 ? .green : .orange)
                Text("Fortschritt:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(entry.completedCount)/4 abgeschlossen")
                    .fontWeight(.medium)
                    .foregroundColor(entry.completedCount == 4 ? .green : .orange)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private var categoryIcon: String {
        switch entry.pois.category.lowercased() {
        case "landmark": return "building.columns"
        case "nature": return "leaf"
        case "culture": return "theatermasks"
        case "food": return "fork.knife"
        case "shop": return "bag"
        case "entertainment": return "gamecontroller"
        default: return "mappin"
        }
    }
}

// MARK: - Quest Type Badge

struct QuestTypeBadge: View {
    let type: String
    let icon: String
    let isCompleted: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(isCompleted ? .green : .gray)
            }

            Text(type)
                .font(.caption2)
                .foregroundColor(isCompleted ? .primary : .secondary)
        }
    }
}

#Preview {
    NavigationStack {
        CompletedQuestDetailView(entry: CompletedQuestEntry(
            id: UUID(),
            userId: UUID(),
            poiId: UUID(),
            visitCompleted: true,
            photoCompleted: true,
            arCompleted: false,
            quizCompleted: true,
            quizScore: 4,
            xpEarned: 150,
            updatedAt: Date(),
            pois: CompletedQuestPOIInfo(
                name: "Brandenburger Tor",
                category: "landmark",
                city: "Berlin",
                description: "Das Brandenburger Tor ist ein Symbol der deutschen Einheit und eines der bekanntesten Wahrzeichen Berlins.",
                aiFacts: [
                    "Das Tor wurde zwischen 1788 und 1791 erbaut.",
                    "Die Quadriga oben wurde 1806 von Napoleon nach Paris gebracht.",
                    "Seit 1990 ist das Tor wieder frei begehbar."
                ],
                quizDescription: nil,
                aiDescription: "Das Brandenburger Tor ist eines der bedeutendsten Wahrzeichen Deutschlands und symbolisiert die deutsche Einheit. Mit seiner imposanten klassizistischen Architektur und der berühmten Quadriga zieht es jährlich Millionen von Besuchern an. Testen Sie Ihr Wissen über dieses historische Monument!"
            )
        ))
    }
}
