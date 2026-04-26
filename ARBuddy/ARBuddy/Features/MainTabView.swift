//
//  MainTabView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @StateObject private var mapViewModel = MapViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            UserProgressView()
                .tabItem {
                    Label("Fortschritt", systemImage: "chart.bar.fill")
                }
                .tag(1)

            MapTabView()
                .tabItem {
                    Label("Karte", systemImage: "map")
                }
                .tag(2)

            QuestsView()
                .tabItem {
                    Label("Quests", systemImage: "list.bullet.clipboard")
                }
                .tag(3)

            ARBuddyView()
                .tabItem {
                    Label("AR", systemImage: "arkit")
                }
                .tag(4)
        }
        .environmentObject(mapViewModel)
        .onChange(of: selectedTab) { _, newValue in
            if newValue == 4 {
                NotificationCenter.default.post(name: .arBuddyWillEnterAR, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let arBuddyWillEnterAR = Notification.Name("ARBuddyWillEnterAR")
}

#Preview {
    MainTabView()
        .environmentObject(LocationService())
        .environmentObject(SupabaseService.shared)
}
