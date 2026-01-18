import SwiftUI

struct AuthView: View {
    @StateObject private var viewModel = AuthViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.4)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 32) {
                        // Logo & Title
                        VStack(spacing: 16) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.white)
                                .shadow(radius: 10)

                            Text("ARBuddy")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(.white)

                            Text("Entdecke deine Stadt")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(.top, 60)

                        // Auth Card
                        VStack(spacing: 24) {
                            // Mode Picker
                            Picker("", selection: $viewModel.authMode) {
                                Text("Anmelden").tag(AuthViewModel.AuthMode.login)
                                Text("Registrieren").tag(AuthViewModel.AuthMode.signup)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)

                            // Content based on mode
                            if viewModel.authMode == .login {
                                LoginFormView(viewModel: viewModel)
                            } else {
                                SignUpFormView(viewModel: viewModel)
                            }
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.ultraThinMaterial)
                        )
                        .padding(.horizontal)

                        Spacer(minLength: 50)
                    }
                }
            }
            .alert("Fehler", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Ein Fehler ist aufgetreten")
            }
        }
    }
}

// MARK: - Login Form
struct LoginFormView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Email Field
            VStack(alignment: .leading, spacing: 6) {
                Label("E-Mail", systemImage: "envelope")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("deine@email.de", text: $viewModel.loginEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }

            // Password Field
            VStack(alignment: .leading, spacing: 6) {
                Label("Passwort", systemImage: "lock")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SecureField("••••••••", text: $viewModel.loginPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            }

            // Login Button
            Button {
                Task {
                    await viewModel.login()
                }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Anmelden")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.isLoginValid ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!viewModel.isLoginValid || viewModel.isLoading)
            .padding(.top, 8)
        }
    }
}

// MARK: - SignUp Form
struct SignUpFormView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Username Field
            VStack(alignment: .leading, spacing: 6) {
                Label("Benutzername", systemImage: "person")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Dein Name", text: $viewModel.signupUsername)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }

            // Email Field
            VStack(alignment: .leading, spacing: 6) {
                Label("E-Mail", systemImage: "envelope")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("deine@email.de", text: $viewModel.signupEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }

            // Password Field
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Passwort", systemImage: "lock")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let error = viewModel.passwordLengthError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }

                SecureField("Mindestens 6 Zeichen", text: $viewModel.signupPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)
            }

            // Confirm Password Field
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Passwort bestätigen", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let error = viewModel.passwordMatchError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }

                SecureField("Passwort wiederholen", text: $viewModel.signupConfirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)
            }

            // Signup Button
            Button {
                Task {
                    await viewModel.signup()
                }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Registrieren")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.isSignupValid ? Color.green : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!viewModel.isSignupValid || viewModel.isLoading)
            .padding(.top, 8)
        }
    }
}

#Preview {
    AuthView()
}
