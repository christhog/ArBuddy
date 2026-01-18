//
//  ARBuddyApp.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

@main
struct ARBuddyApp: App {
    @StateObject private var locationService = LocationService()
    @StateObject private var supabaseService = SupabaseService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(locationService)
                .environmentObject(supabaseService)
        }
    }
}

// MARK: - Root View (Auth Gate)
struct RootView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @State private var isCheckingAuth = true

    var body: some View {
        Group {
            if isCheckingAuth {
                // Splash / Loading Screen
                SplashView()
            } else if supabaseService.isAuthenticated {
                // Main App
                MainTabView()
            } else {
                // Auth Flow
                AuthView()
            }
        }
        .task {
            await supabaseService.checkAuthStatus()
            isCheckingAuth = false
        }
    }
}

// MARK: - Splash View
struct SplashView: View {
    var body: some View {
        ZStack {
            Image("SplashImage")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "map.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.white)

                Text("ARBuddy")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
            }
        }
    }
}
