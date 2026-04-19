//
//  CountryButtonsOverlay.swift
//  ARBuddy
//
//  Created by Chris Greve on 25.01.26.
//

import SwiftUI

/// Overlay view that displays country selection buttons on the AR globe
struct CountryButtonsOverlay: View {
    @ObservedObject var viewModel: ARBuddyViewModel

    var body: some View {
        GeometryReader { _ in
            ForEach(viewModel.countryButtons) { button in
                if button.isVisible {
                    CountryButtonView(
                        countryCode: button.id,
                        clusteredWith: button.clusteredWith,
                        onTap: {
                            handleButtonTap(button)
                        }
                    )
                    .position(button.screenPosition)
                }
            }
        }
        .sheet(isPresented: $viewModel.showClusterPopup) {
            ClusterPopupView(
                countryCodes: viewModel.clusteredCountryCodes,
                onSelect: { code in
                    viewModel.dismissClusterPopup()
                    viewModel.selectCountry(code)
                },
                onDismiss: {
                    viewModel.dismissClusterPopup()
                }
            )
            .presentationDetents([.medium])
        }
    }

    private func handleButtonTap(_ button: CountryButton) {
        if let clustered = button.clusteredWith, !clustered.isEmpty {
            // Show cluster popup with all countries (including the main one)
            let allCodes = [button.id] + clustered
            viewModel.showClusterPopupWith(allCodes)
        } else {
            // Single country - select directly
            viewModel.selectCountry(button.id)
        }
    }
}

/// Individual country button view
struct CountryButtonView: View {
    let countryCode: String
    let clusteredWith: [String]?
    let onTap: () -> Void

    private var clusteredCount: Int {
        clusteredWith?.count ?? 0
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Background circle
                Circle()
                    .fill(clusteredCount > 0 ? Color.orange.opacity(0.9) : Color.blue.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                if clusteredCount > 0 {
                    // Badge showing cluster count
                    VStack(spacing: 0) {
                        Text("\(clusteredCount + 1)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Text("Länder")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.9))
                    }
                } else {
                    // Country flag emoji
                    Text(countryFlag(countryCode))
                        .font(.title2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Converts ISO country code to flag emoji
    private func countryFlag(_ code: String) -> String {
        let base: UInt32 = 127397
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            if let scalarValue = UnicodeScalar(base + scalar.value) {
                flag.append(Character(scalarValue))
            }
        }
        return flag.isEmpty ? "🌍" : flag
    }
}

/// Popup view for selecting from a cluster of countries
struct ClusterPopupView: View {
    let countryCodes: [String]
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            List(countryCodes, id: \.self) { code in
                Button {
                    onSelect(code)
                } label: {
                    HStack(spacing: 12) {
                        Text(countryFlag(code))
                            .font(.title)

                        Text(CountryCenters.countryNames[code] ?? code)
                            .font(.body)
                            .foregroundColor(.primary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Land auswählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") {
                        onDismiss()
                    }
                }
            }
        }
    }

    /// Converts ISO country code to flag emoji
    private func countryFlag(_ code: String) -> String {
        let base: UInt32 = 127397
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            if let scalarValue = UnicodeScalar(base + scalar.value) {
                flag.append(Character(scalarValue))
            }
        }
        return flag.isEmpty ? "🌍" : flag
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)

        CountryButtonsOverlay(viewModel: ARBuddyViewModel())
    }
}
