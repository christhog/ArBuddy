import SwiftUI

struct SignUpView: View {
    @ObservedObject var viewModel: AuthViewModel
    var onSwitchToLogin: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Konto erstellen")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Starte dein Abenteuer")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Form
            VStack(spacing: 16) {
                // Username Field
                AuthTextField(
                    title: "Benutzername",
                    icon: "person",
                    placeholder: "Dein Name",
                    text: $viewModel.signupUsername
                )

                // Email Field
                AuthTextField(
                    title: "E-Mail",
                    icon: "envelope",
                    placeholder: "deine@email.de",
                    text: $viewModel.signupEmail,
                    keyboardType: .emailAddress
                )

                // Password Field
                AuthSecureField(
                    title: "Passwort",
                    icon: "lock",
                    placeholder: "Mindestens 6 Zeichen",
                    text: $viewModel.signupPassword,
                    errorMessage: viewModel.passwordLengthError
                )

                // Confirm Password Field
                AuthSecureField(
                    title: "Passwort bestätigen",
                    icon: "lock.fill",
                    placeholder: "Passwort wiederholen",
                    text: $viewModel.signupConfirmPassword,
                    errorMessage: viewModel.passwordMatchError
                )
            }

            // Signup Button
            AuthButton(
                title: "Registrieren",
                isLoading: viewModel.isLoading,
                isEnabled: viewModel.isSignupValid
            ) {
                Task {
                    await viewModel.signup()
                }
            }

            // Switch to Login
            HStack {
                Text("Bereits ein Konto?")
                    .foregroundColor(.secondary)

                Button("Anmelden") {
                    onSwitchToLogin()
                }
                .fontWeight(.semibold)
            }
            .font(.subheadline)
        }
    }
}

#Preview {
    SignUpView(viewModel: AuthViewModel()) {
        print("Switch to login")
    }
    .padding()
}
