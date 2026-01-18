//
//  CountryProgressMapView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI

struct CountryProgressMapView: View {
    let countryProgress: [CountryProgress]
    var isLoading: Bool = false

    var body: some View {
        if isLoading {
            loadingView
        } else if countryProgress.isEmpty {
            emptyStateView
        } else {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(countryProgress) { country in
                    CountryProgressCard(country: country)
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)

            Text("Lade Länder-Fortschritt...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe.europe.africa")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("Noch keine Länder erkundet")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Besuche POIs um deinen Fortschritt zu sehen")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct CountryProgressCard: View {
    let country: CountryProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(country.flagEmoji)
                    .font(.title2)

                Text(country.countryName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            ProgressView(value: country.completionPercentage)
                .tint(progressColor)

            // Quest-based progress text
            Text("\(country.totalQuestsCompleted)/\(country.totalPossibleQuests) Quests")
                .font(.caption)
                .foregroundColor(.secondary)

            // Quest type indicators
            HStack(spacing: 4) {
                QuestTypeIndicator(
                    systemImage: "location.fill",
                    completed: country.visitsCompleted,
                    total: country.totalPOIs
                )
                QuestTypeIndicator(
                    systemImage: "camera.fill",
                    completed: country.photosCompleted,
                    total: country.totalPOIs
                )
                QuestTypeIndicator(
                    systemImage: "arkit",
                    completed: country.arCompleted,
                    total: country.totalPOIs
                )
                QuestTypeIndicator(
                    systemImage: "questionmark.circle.fill",
                    completed: country.quizzesCompleted,
                    total: country.totalPOIs
                )
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var progressColor: Color {
        if country.completionPercentage >= 1.0 {
            return .green
        } else if country.completionPercentage >= 0.5 {
            return .blue
        } else {
            return .orange
        }
    }
}

struct QuestTypeIndicator: View {
    let systemImage: String
    let completed: Int
    let total: Int

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption2)
            .foregroundColor(indicatorColor)
    }

    private var indicatorColor: Color {
        if progress >= 1.0 {
            return .green
        } else if progress > 0 {
            return .orange
        } else {
            return .gray.opacity(0.5)
        }
    }
}

#Preview {
    CountryProgressMapView(countryProgress: CountryProgress.sampleData)
        .padding()
}
