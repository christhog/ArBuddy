//
//  POIProgressSectionView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct POIProgressSectionView: View {
    let stats: UserPOIStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("POI Fortschritt")
                .font(.headline)

            VStack(spacing: 8) {
                // Overall progress
                if stats.totalPoisVisited > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Vollständig erkundet")
                                .font(.subheadline)
                            Spacer()
                            Text("\(stats.fullyCompletedPois)/\(stats.totalPoisVisited)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        ProgressView(
                            value: Double(stats.fullyCompletedPois),
                            total: Double(max(stats.totalPoisVisited, 1))
                        )
                        .tint(.green)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }

                // Quest type breakdown
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    QuestTypeStatCard(
                        type: "Besuche",
                        icon: "mappin.circle",
                        count: stats.visitQuestsCompleted,
                        color: .blue
                    )
                    QuestTypeStatCard(
                        type: "Fotos",
                        icon: "camera",
                        count: stats.photoQuestsCompleted,
                        color: .pink
                    )
                    QuestTypeStatCard(
                        type: "AR",
                        icon: "arkit",
                        count: stats.arQuestsCompleted,
                        color: .purple
                    )
                    QuestTypeStatCard(
                        type: "Quiz",
                        icon: "questionmark.circle",
                        count: stats.quizQuestsCompleted,
                        color: .orange
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuestTypeStatCard: View {
    let type: String
    let icon: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(type)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(count)")
                    .font(.headline)
            }

            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

#Preview {
    POIProgressSectionView(stats: UserPOIStatistics())
}
