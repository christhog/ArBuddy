//
//  SettingsView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @State private var showLogoutConfirmation = false
    @State private var isLoggingOut = false

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("E-Mail", value: supabaseService.currentUser?.email ?? "-")
                LabeledContent("Benutzername", value: supabaseService.currentUser?.username ?? "-")
            }

            Section("Statistiken") {
                LabeledContent("Level", value: "\(supabaseService.currentUser?.level ?? 1)")
                LabeledContent("Gesamt XP", value: "\(supabaseService.currentUser?.xp ?? 0)")
            }

            Section {
                Button(role: .destructive) {
                    showLogoutConfirmation = true
                } label: {
                    HStack {
                        if isLoggingOut {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Abmelden")
                        }
                    }
                }
                .disabled(isLoggingOut)
            }
        }
        .navigationTitle("Einstellungen")
        .confirmationDialog(
            "Möchtest du dich wirklich abmelden?",
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Abmelden", role: .destructive) {
                performLogout()
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func performLogout() {
        isLoggingOut = true
        Task {
            do {
                try await supabaseService.signOut()
            } catch {
                print("Logout failed: \(error)")
            }
            isLoggingOut = false
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(SupabaseService.shared)
    }
}
