import Foundation
import Combine

@MainActor
class AuthViewModel: ObservableObject {
    // MARK: - Published Properties

    // Login fields
    @Published var loginEmail = ""
    @Published var loginPassword = ""

    // Signup fields
    @Published var signupEmail = ""
    @Published var signupPassword = ""
    @Published var signupConfirmPassword = ""
    @Published var signupUsername = ""

    // State
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var authMode: AuthMode = .login

    // MARK: - Dependencies
    private let supabaseService = SupabaseService.shared

    // MARK: - Auth Mode
    enum AuthMode {
        case login
        case signup
    }

    // MARK: - Computed Properties

    var isLoginValid: Bool {
        !loginEmail.isEmpty && !loginPassword.isEmpty && loginPassword.count >= 6
    }

    var isSignupValid: Bool {
        !signupEmail.isEmpty &&
        !signupPassword.isEmpty &&
        !signupUsername.isEmpty &&
        signupPassword.count >= 6 &&
        signupPassword == signupConfirmPassword
    }

    var passwordMatchError: String? {
        if signupPassword.isEmpty || signupConfirmPassword.isEmpty {
            return nil
        }
        if signupPassword != signupConfirmPassword {
            return "Passwörter stimmen nicht überein"
        }
        return nil
    }

    var passwordLengthError: String? {
        if signupPassword.isEmpty {
            return nil
        }
        if signupPassword.count < 6 {
            return "Mindestens 6 Zeichen erforderlich"
        }
        return nil
    }

    // MARK: - Actions

    func login() async {
        guard isLoginValid else {
            showError(message: "Bitte fülle alle Felder aus")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await supabaseService.signIn(
                email: loginEmail.trimmingCharacters(in: .whitespaces),
                password: loginPassword
            )
            clearLoginFields()
        } catch {
            showError(message: supabaseService.errorMessage ?? "Anmeldung fehlgeschlagen")
        }

        isLoading = false
    }

    func signup() async {
        guard isSignupValid else {
            if !signupEmail.isEmpty && !signupPassword.isEmpty && signupPassword != signupConfirmPassword {
                showError(message: "Passwörter stimmen nicht überein")
            } else {
                showError(message: "Bitte fülle alle Felder korrekt aus")
            }
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await supabaseService.signUp(
                email: signupEmail.trimmingCharacters(in: .whitespaces),
                password: signupPassword,
                username: signupUsername.trimmingCharacters(in: .whitespaces)
            )
            clearSignupFields()
        } catch {
            showError(message: supabaseService.errorMessage ?? "Registrierung fehlgeschlagen")
        }

        isLoading = false
    }

    func switchToLogin() {
        authMode = .login
        errorMessage = nil
        showError = false
    }

    func switchToSignup() {
        authMode = .signup
        errorMessage = nil
        showError = false
    }

    // MARK: - Private Helpers

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }

    private func clearLoginFields() {
        loginEmail = ""
        loginPassword = ""
    }

    private func clearSignupFields() {
        signupEmail = ""
        signupPassword = ""
        signupConfirmPassword = ""
        signupUsername = ""
    }
}
