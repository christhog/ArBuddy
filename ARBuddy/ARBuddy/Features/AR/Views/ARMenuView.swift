//
//  ARMenuView.swift
//  ARBuddy
//
//  Created by Chris Greve on 22.01.26.
//

import SwiftUI

/// Floating action menu for AR view with expandable options
struct ARMenuView: View {
    @ObservedObject var viewModel: ARBuddyViewModel
    @Binding var isGlobeVisible: Bool
    @Binding var isBuddyVisible: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            // Expandable menu options
            if isExpanded {
                // Globe toggle
                ARMenuButton(
                    icon: isGlobeVisible ? "globe.europe.africa.fill" : "globe.europe.africa",
                    label: isGlobeVisible ? "Globus aus" : "Globus",
                    isActive: isGlobeVisible
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isGlobeVisible.toggle()
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))

                // Buddy visibility toggle
                ARMenuButton(
                    icon: isBuddyVisible ? "eye.fill" : "eye.slash.fill",
                    label: isBuddyVisible ? "Buddy aus" : "Buddy ein",
                    isActive: !isBuddyVisible
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isBuddyVisible.toggle()
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))

                // Country picker (only when globe is visible)
                if isGlobeVisible {
                    Menu {
                        ForEach(viewModel.availableCountries, id: \.code) { country in
                            Button(country.name) {
                                viewModel.rotateGlobeToCountry(country.code)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "map")
                                .font(.system(size: 16, weight: .medium))
                            Text("Land wählen")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                        )
                    }
                    .transition(.asymmetric(
                        insertion: .scale.combined(with: .opacity),
                        removal: .scale.combined(with: .opacity)
                    ))
                }
            }

            // Main FAB button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "xmark" : "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(isExpanded ? Color.red.opacity(0.9) : Color.blue)
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    )
            }
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
    }
}

/// Individual menu button with icon and label
struct ARMenuButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(isActive ? Color.orange : Color.black.opacity(0.6))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            )
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        VStack {
            Spacer()
            HStack {
                Spacer()
                ARMenuView(
                    viewModel: ARBuddyViewModel(),
                    isGlobeVisible: .constant(false),
                    isBuddyVisible: .constant(true)
                )
                .padding()
            }
        }
    }
}
