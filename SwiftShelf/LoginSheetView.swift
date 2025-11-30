import SwiftUI

enum LoginMethod: String, CaseIterable, Identifiable {
    case apiKey = "API Key"
    case userPass = "Username & Password"

    var id: String { rawValue }
}

struct LoginSheetView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var apiKey: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var loginMethod: LoginMethod = .apiKey
    @State private var isLoggingIn: Bool = false
    @State private var loginError: String? = nil

    private var canSubmit: Bool {
        if host.isEmpty { return false }
        switch loginMethod {
        case .apiKey:
            return !apiKey.isEmpty
        case .userPass:
            return !username.isEmpty && !password.isEmpty
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server")) {
                    TextField("Host (e.g., https://abs.example.com)", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Authentication Method")) {
                    Picker("Login Method", selection: $loginMethod) {
                        ForEach(LoginMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Credentials")) {
                    switch loginMethod {
                    case .apiKey:
                        SecureField("API Key", text: $apiKey)
                    case .userPass:
                        TextField("Username", text: $username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        SecureField("Password", text: $password)
                    }
                }

                if let error = loginError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        Task {
                            await performLogin()
                        }
                    } label: {
                        HStack {
                            if isLoggingIn {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isLoggingIn ? "Logging in..." : "Login")
                        }
                    }
                    .disabled(!canSubmit || isLoggingIn)
                }
            }
            .navigationTitle("Login")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Pre-fill with current values
                host = viewModel.host
                apiKey = viewModel.apiKey
            }
        }
    }

    private func performLogin() async {
        isLoggingIn = true
        loginError = nil

        switch loginMethod {
        case .apiKey:
            viewModel.saveCredentialsToKeychain(host: host, apiKey: apiKey)
            await viewModel.connect()
            if viewModel.errorMessage == nil {
                await MainActor.run { dismiss() }
            } else {
                loginError = viewModel.errorMessage
            }

        case .userPass:
            let success = await viewModel.loginWithCredentials(
                host: host,
                username: username,
                password: password
            )
            if success {
                await viewModel.connect()
                await MainActor.run { dismiss() }
            } else {
                loginError = viewModel.errorMessage ?? "Login failed"
            }
        }

        isLoggingIn = false
    }
}

#Preview {
    LoginSheetView()
        .environmentObject(ViewModel())
}
