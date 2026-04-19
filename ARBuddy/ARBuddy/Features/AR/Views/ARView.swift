//
//  ARView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI
import RealityKit
import UIKit

struct ARBuddyView: View {
    @EnvironmentObject var locationService: LocationService
    @StateObject private var viewModel = ARBuddyViewModel()

    var body: some View {
        ZStack {
            ARViewContainer(viewModel: viewModel)
                .edgesIgnoringSafeArea(.all)

            // Country buttons overlay (only show when globe is visible)
            if viewModel.isGlobeVisible {
                CountryButtonsOverlay(viewModel: viewModel)
                    .edgesIgnoringSafeArea(.all)
            }

            // UI Overlay
            VStack {
                Spacer()

                VStack(spacing: 8) {
                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("Lade Buddy...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    } else if viewModel.placementMode == .manual {
                        // Placed state
                        if let buddy = viewModel.currentBuddy {
                            Text(buddy.name)
                                .font(.headline)
                                .foregroundColor(.white)
                        }

                        // Globe hint when globe is visible
                        if viewModel.isGlobeVisible {
                            Text("Tippe auf ein Land für Infos • Drehen mit Finger")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }

                        Button(action: {
                            viewModel.resetPlacement()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Neu platzieren")
                            }
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(8)
                        }
                    } else {
                        // Waiting for placement
                        if let buddy = viewModel.currentBuddy {
                            Text(buddy.name)
                                .font(.headline)
                                .foregroundColor(.white)
                        } else {
                            Text("AR Buddy")
                                .font(.headline)
                                .foregroundColor(.white)
                        }

                        Text("Tippe auf den Boden, um deinen Buddy zu platzieren")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }

                    // Error messages
                    if let error = viewModel.placementError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding(.bottom, 100)
            }

            // AR Menu (only show when buddy is placed)
            if viewModel.placementMode == .manual {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ARMenuView(
                            viewModel: viewModel,
                            isGlobeVisible: $viewModel.isGlobeVisible,
                            isBuddyVisible: $viewModel.isBuddyVisible
                        )
                        .padding(.trailing, 20)
                        .padding(.bottom, 200)
                    }
                }
            }

            // Country Popup Overlay
            if let countryCode = viewModel.selectedCountryCode,
               let progress = viewModel.getCountryProgress(for: countryCode) {
                Color.black.opacity(0.3)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.clearSelectedCountry()
                    }

                ARCountryPopup(progress: progress) {
                    viewModel.clearSelectedCountry()
                }
                .transition(.scale.combined(with: .opacity))
            } else if let countryCode = viewModel.selectedCountryCode {
                // Country selected but no progress data - show placeholder
                Color.black.opacity(0.3)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.clearSelectedCountry()
                    }

                ARCountryPopup(
                    progress: CountryProgress(
                        id: countryCode,
                        countryName: countryCode,
                        totalPOIs: 0,
                        completedPOIs: 0
                    )
                ) {
                    viewModel.clearSelectedCountry()
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.selectedCountryCode)
        .task {
            await viewModel.loadSelectedBuddy()
        }
    }
}

#Preview {
    ARBuddyView()
        .environmentObject(LocationService())
}
