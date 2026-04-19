//
//  ARCountryPopup.swift
//  ARBuddy
//
//  Created by Chris Greve on 22.01.26.
//

import SwiftUI

/// AR overlay popup showing country progress when tapping on the globe
struct ARCountryPopup: View {
    let progress: CountryProgress
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Header: Flag + Name + Close button
            HStack(alignment: .center) {
                Text(progress.flagEmoji)
                    .font(.system(size: 40))

                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.countryName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("\(progress.completedPOIs)/\(progress.totalPOIs) POIs besucht")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Progress stats grid
            HStack(spacing: 16) {
                ARStatBox(
                    icon: "checkmark.circle.fill",
                    value: "\(progress.totalQuestsCompleted)",
                    label: "Quests",
                    color: .green
                )

                ARStatBox(
                    icon: "star.fill",
                    value: "\(progress.estimatedXP)",
                    label: "XP",
                    color: .orange
                )

                ARStatBox(
                    icon: "percent",
                    value: "\(Int(progress.completionPercentage * 100))%",
                    label: "Fortschritt",
                    color: progressColor
                )
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Quest-Fortschritt")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(progress.totalQuestsCompleted)/\(progress.totalPossibleQuests)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background bar
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 8)

                        // Progress fill
                        RoundedRectangle(cornerRadius: 4)
                            .fill(progressColor)
                            .frame(
                                width: geometry.size.width * CGFloat(progress.completionPercentage),
                                height: 8
                            )
                    }
                }
                .frame(height: 8)
            }

            // Quest breakdown
            HStack(spacing: 12) {
                ARQuestTypeIndicator(
                    icon: "mappin.circle.fill",
                    count: progress.visitsCompleted,
                    color: .blue
                )
                ARQuestTypeIndicator(
                    icon: "camera.fill",
                    count: progress.photosCompleted,
                    color: .purple
                )
                ARQuestTypeIndicator(
                    icon: "arkit",
                    count: progress.arCompleted,
                    color: .cyan
                )
                ARQuestTypeIndicator(
                    icon: "questionmark.circle.fill",
                    count: progress.quizzesCompleted,
                    color: .yellow
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.4))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        .frame(maxWidth: 320)
    }

    private var progressColor: Color {
        let percentage = progress.completionPercentage
        if percentage >= 1.0 {
            return .green
        } else if percentage >= 0.5 {
            return .blue
        } else if percentage > 0 {
            return .orange
        } else {
            return .gray
        }
    }
}

/// Stat box component for the popup
private struct ARStatBox: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)

            Text(value)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.1))
        )
    }
}

/// Quest type indicator showing icon and count
private struct ARQuestTypeIndicator: View {
    let icon: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.1))
        )
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ARCountryPopup(
            progress: CountryProgress.sampleData[0],
            onClose: {}
        )
        .padding()
    }
}
