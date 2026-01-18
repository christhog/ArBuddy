//
//  GlobeView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI

/// SwiftUI container view for the 3D globe visualization
/// Displays country progress as highlighted markers on an interactive Earth globe
struct GlobeView: View {
    let countryProgress: [CountryProgress]
    let isLoading: Bool

    init(countryProgress: [CountryProgress], isLoading: Bool = false) {
        self.countryProgress = countryProgress
        self.isLoading = isLoading
    }

    var body: some View {
        ZStack {
            // Globe background gradient
            LinearGradient(
                colors: [
                    Color.black.opacity(0.8),
                    Color.blue.opacity(0.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            } else {
                // 3D Globe
                GlobeSceneView(countryProgress: countryProgress)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            // Overlay with legend
            VStack {
                Spacer()
                legendView
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Legend showing what the colors mean
    private var legendView: some View {
        HStack(spacing: 16) {
            legendItem(color: .green, label: "100%")
            legendItem(color: .blue, label: "50%+")
            legendItem(color: .orange, label: "<50%")
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Globe View") {
    GlobeView(countryProgress: CountryProgress.sampleData)
        .frame(height: 300)
        .padding()
}

#Preview("Globe View Loading") {
    GlobeView(countryProgress: [], isLoading: true)
        .frame(height: 300)
        .padding()
}
