//
//  CountryPopupOverlay.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import SwiftUI

/// Compact overlay showing country progress details when tapping on the globe
struct CountryPopupOverlay: View {
    let progress: CountryProgress
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Header: Flag + Name + Close button
            HStack {
                Text(progress.flagEmoji)
                    .font(.title2)
                Text(progress.countryName)
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            // Quest progress
            HStack {
                Label("\(progress.totalQuestsCompleted)/\(progress.totalPossibleQuests)", systemImage: "checkmark.circle")
                    .font(.subheadline)
                Spacer()
                Label("\(progress.estimatedXP) XP", systemImage: "star.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            // Progress bar
            ProgressView(value: progress.completionPercentage)
                .tint(progressColor)

            // POI count
            HStack {
                Text("\(progress.completedPOIs)/\(progress.totalPOIs) POIs besucht")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
        .frame(width: 240)
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

#Preview {
    ZStack {
        Color.black.opacity(0.3)
        CountryPopupOverlay(
            progress: CountryProgress.sampleData[0],
            onClose: {}
        )
    }
}
