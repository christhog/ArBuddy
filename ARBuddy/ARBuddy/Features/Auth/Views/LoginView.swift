import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel
    var onSwitchToSignup: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Willkommen zurück!")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Melde dich an, um fortzufahren")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Form
            VStack(spacing: 16) {
                // Email Field
                AuthTextField(
                    title: "E-Mail",
                    icon: "envelope",
                    placeholder: "deine@email.de",
                    text: $viewModel.loginEmail,
                    keyboardType: .emailAddress
                )

                // Password Field
                AuthSecureField(
                    title: "Passwort",
                    icon: "lock",
                    placeholder: "••••••••",
                    text: $viewModel.loginPassword
                )
            }

            // Login Button
            AuthButton(
                title: "Anmelden",
                isLoading: viewModel.isLoading,
                isEnabled: viewModel.isLoginValid
            ) {
                Task {
                    await viewModel.login()
                }
            }

            // Switch to Signup
            HStack {
                Text("Noch kein Konto?")
                    .foregroundColor(.secondary)

                Button("Registrieren") {
                    onSwitchToSignup()
                }
                .fontWeight(.semibold)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Reusable Auth Components

struct AuthTextField: View {
    let title: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let error = errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboardType)
                .autocapitalization(.none)
                .autocorrectionDisabled()
        }
    }
}

struct AuthSecureField: View {
    let title: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let error = errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct AuthButton: View {
    let title: String
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text(title)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isEnabled && !isLoading ? Color.blue : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!isEnabled || isLoading)
    }
}

#Preview {
    LoginView(viewModel: AuthViewModel()) {
        print("Switch to signup")
    }
    .padding()
}
