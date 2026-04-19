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
    let userCoordinates: (lat: Double, lon: Double)?
    let userCountryCode: String?

    @State private var globeController = GlobeController()
    @State private var inactivityTimer: Timer?
    @State private var hasInitialized = false
    @State private var isControllerConfigured = false
    @State private var selectedCountryCode: String?
    @State private var showCountryPopup = false

    /// Duration of inactivity before starting rotation (in seconds)
    private let inactivityTimeout: TimeInterval = 5.0

    init(countryProgress: [CountryProgress], isLoading: Bool = false, userCoordinates: (lat: Double, lon: Double)? = nil, userCountryCode: String? = nil) {
        self.countryProgress = countryProgress
        self.isLoading = isLoading
        self.userCoordinates = userCoordinates
        self.userCountryCode = userCountryCode
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
                GlobeSceneView(
                    countryProgress: countryProgress,
                    controller: globeController
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            // Country popup overlay (centered)
            if showCountryPopup,
               let code = selectedCountryCode,
               let progress = countryProgress.first(where: { $0.id == code }) {
                // Transparent background to catch taps outside popup
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closePopup()
                    }

                CountryPopupOverlay(
                    progress: progress,
                    onClose: {
                        closePopup()
                    }
                )
                .transition(.scale.combined(with: .opacity))
            }

            // Overlay with legend
            VStack {
                Spacer()
                legendView
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            setupGlobeController()
        }
        .onChange(of: userCoordinates?.lat) { oldValue, newValue in
            // When user coordinates change (e.g., location detected), center on them
            // Only react if we actually got new coordinates
            if newValue != nil {
                centerOnUserCountryIfNeeded()
            }
        }
        .onChange(of: userCountryCode) { oldValue, newValue in
            // When country code is detected, re-center with correct bounding box
            if newValue != nil {
                centerOnUserCountryIfNeeded()
            }
        }
        .onDisappear {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
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

    // MARK: - Globe Control

    private func setupGlobeController() {
        // Set up interaction callback
        globeController.onInteraction = { [self] in
            handleUserInteraction()
        }

        // Set up configured callback
        globeController.onConfigured = { [self] in
            isControllerConfigured = true
            initializeGlobe()
        }

        // Set up country tap callback
        globeController.onCountryTapped = { [self] countryCode in
            // Stop timer and rotation while popup is open
            inactivityTimer?.invalidate()
            inactivityTimer = nil
            globeController.pauseRotation()

            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedCountryCode = countryCode
                showCountryPopup = true
            }
        }

        // Also check after a short delay in case callback was missed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if globeController.isConfigured && !hasInitialized {
                isControllerConfigured = true
                initializeGlobe()
            }
        }
    }

    private func initializeGlobe() {
        guard !hasInitialized, globeController.isConfigured else { return }

        // Center on user's country if available
        if let coords = userCoordinates {
            let boundingBox = userCountryCode.flatMap { GeoJSONParser.boundingBox(for: $0) }
            print("[Globe] Centering on: \(coords.lat), \(coords.lon), country: \(userCountryCode ?? "unknown"), span: \(boundingBox?.maxSpan ?? 0)°")
            globeController.centerOn(latitude: coords.lat, longitude: coords.lon, boundingBox: boundingBox)
        }
        // If no coordinates yet, we'll center when they arrive

        hasInitialized = true

        // Always start the inactivity timer
        startInactivityTimer()
    }

    private func centerOnUserCountryIfNeeded() {
        // If coordinates arrive after initialization, center on them
        guard isControllerConfigured, let coords = userCoordinates else { return }

        let boundingBox = userCountryCode.flatMap { GeoJSONParser.boundingBox(for: $0) }
        print("[Globe] Centering on: \(coords.lat), \(coords.lon), country: \(userCountryCode ?? "unknown"), span: \(boundingBox?.maxSpan ?? 0)°")
        globeController.centerOn(latitude: coords.lat, longitude: coords.lon, boundingBox: boundingBox)

        // Reset timer since we just moved the camera
        startInactivityTimer()
    }

    private func handleUserInteraction() {
        // Pause rotation during interaction
        globeController.pauseRotation()

        // Reset the timer on any interaction (but not if popup is open)
        if !showCountryPopup {
            startInactivityTimer()
        }
    }

    private func closePopup() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showCountryPopup = false
        }
        // Resume inactivity timer after popup closes
        startInactivityTimer()
    }

    private func startInactivityTimer() {
        // Don't start timer if popup is open
        guard !showCountryPopup else { return }

        // Cancel existing timer
        inactivityTimer?.invalidate()

        // Start new timer
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityTimeout, repeats: false) { _ in
            Task { @MainActor in
                transitionToDefaultView()
            }
        }
    }

    private func transitionToDefaultView() {
        // Don't transition if popup is open
        guard !showCountryPopup else { return }

        // Start rotation
        globeController.resumeRotation()

        // Animate camera back to default position (slow transition to match rotation speed)
        globeController.animateToDefaultView(duration: 8.0)
    }
}

#Preview("Globe View") {
    GlobeView(countryProgress: CountryProgress.sampleData)
        .frame(height: 300)
        .padding()
}

#Preview("Globe View with User Location") {
    GlobeView(
        countryProgress: CountryProgress.sampleData,
        userCoordinates: (lat: 51.1657, lon: 10.4515), // Germany center
        userCountryCode: "DE"
    )
    .frame(height: 300)
    .padding()
}

#Preview("Globe View Loading") {
    GlobeView(countryProgress: [], isLoading: true)
        .frame(height: 300)
        .padding()
}
