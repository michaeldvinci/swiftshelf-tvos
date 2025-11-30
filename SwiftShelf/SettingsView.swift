import SwiftUI
import Combine

enum ProgressBarColor: String, CaseIterable, Identifiable {
    case yellow = "Yellow"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case orange = "Orange"
    case pink = "Pink"
    case teal = "Teal"
    case rainbow = "Rainbow"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: return .yellow
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .orange: return .orange
        case .pink: return .pink
        case .teal: return .teal
        case .rainbow: return .clear // Rainbow is handled separately with gradient
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var vm: ViewModel
    @EnvironmentObject var config: LibraryConfig
    @AppStorage("libraryItemLimit") var libraryItemLimit: Int = 10
    @AppStorage("progressBarColor") var progressBarColorString: String = "Yellow"
    @AppStorage("preferredPlaybackRate") var preferredPlaybackRate: Double = 1.0
    @State private var draftLimit: Int
    @State private var showLoginSheet = false
    @State private var loginHost: String = ""
    @State private var loginApiKey: String = ""

    var progressBarColor: ProgressBarColor {
        ProgressBarColor(rawValue: progressBarColorString) ?? .yellow
    }

    init() {
        _draftLimit = State(initialValue: UserDefaults.standard.integer(forKey: "libraryItemLimit") == 0 ? 10 : UserDefaults.standard.integer(forKey: "libraryItemLimit"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Section: Info note
                VStack(alignment: .leading, spacing: 8) {
                    Text("Libraries will automatically refresh when settings are saved.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }

                // Section: Library Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Library Settings").font(.headline)
                    VStack(alignment: .leading) {
                        HStack {
                            Button(action: { if draftLimit > 5 { draftLimit -= 1 } }) {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderedProminent)

                            Text("Max Items per Library Query: \(draftLimit)")
                                .frame(minWidth: 180, alignment: .center)
                                .padding(.horizontal, 8)

                            Button(action: { if draftLimit < 50 { draftLimit += 1 } }) {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Save") {
                            libraryItemLimit = draftLimit
                            vm.objectWillChange.send()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 6)

                        Text("This setting controls the maximum number of items fetched per query from the library to optimize performance and data usage.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }

                // Section: Appearance
                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance").font(.headline)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Progress Bar Color").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 24) {
                                ForEach(ProgressBarColor.allCases) { colorOption in
                                    Button {
                                        progressBarColorString = colorOption.rawValue
                                        vm.objectWillChange.send()
                                    } label: {
                                        ZStack {
                                            if progressBarColor == colorOption {
                                                Circle()
                                                    .fill(Color.white.opacity(0.15))
                                                    .frame(width: 80, height: 80)
                                            }
                                            if colorOption == .rainbow {
                                                RainbowPreview()
                                                    .frame(width: 60, height: 60)
                                                    .cornerRadius(30)
                                                    .overlay(
                                                        Circle().stroke(progressBarColor == colorOption ? Color.white : Color.clear, lineWidth: 3)
                                                    )
                                            } else {
                                                Circle()
                                                    .fill(colorOption.color)
                                                    .frame(width: 60, height: 60)
                                                    .overlay(
                                                        Circle().stroke(progressBarColor == colorOption ? Color.white : Color.clear, lineWidth: 3)
                                                    )
                                            }
                                        }
                                        .frame(width: 80, height: 80)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview").font(.caption).foregroundColor(.secondary)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.15)).frame(height: 8)
                                if progressBarColor == .rainbow {
                                    RainbowProgressBar().frame(width: 300 * 0.65, height: 8).clipShape(Capsule())
                                } else {
                                    Capsule().fill(progressBarColor.color).frame(width: 300 * 0.65, height: 8)
                                }
                            }
                            .frame(width: 300, height: 8)
                        }
                        .padding(.top, 8)
                    }
                    .padding(.vertical, 8)
                }

                // Section: Playback
                VStack(alignment: .leading, spacing: 12) {
                    Text("Playback").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preferred Playback Speed").font(.headline)
                        HStack(spacing: 16) {
                            Button(action: {
                                preferredPlaybackRate = max(0.5, (preferredPlaybackRate - 0.25).rounded(toPlaces: 2))
                                vm.objectWillChange.send()
                            }) { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderedProminent)

                            Text(String(format: "%.2fx", preferredPlaybackRate))
                                .frame(minWidth: 80)

                            Button(action: {
                                preferredPlaybackRate = min(3.0, (preferredPlaybackRate + 0.25).rounded(toPlaces: 2))
                                vm.objectWillChange.send()
                            }) { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderedProminent)
                        }
                        Text("Global default speed for new playback sessions. Adjust here or in the mini player; changes persist.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Section: User Account
                VStack(alignment: .leading, spacing: 12) {
                    Text("User Account").font(.headline)
                    HStack(spacing: 16) {
                        Button(role: .destructive) {
                            loginHost = vm.host
                            loginApiKey = vm.apiKey
                            showLoginSheet = true
                        } label: { Text("Login") }
                        .sheet(isPresented: $showLoginSheet) { LoginSheetView().environmentObject(vm) }

                        Button(role: .destructive) {
                            vm.logout()
                            vm.libraries = []
                            vm.errorMessage = nil
                            vm.isLoggedIn = false
                            vm.refreshToken += 1
                            config.selected = []
                            UserDefaults.standard.set("[]", forKey: "recentSearches")
                        } label: { Text("Logout") }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Rainbow Views

struct RainbowProgressBar: View {
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.black, .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: animationOffset)
            )
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    animationOffset = geometry.size.width
                }
            }
        }
    }
}

struct RainbowPreview: View {
    var body: some View {
        LinearGradient(
            colors: [.red, .orange, .yellow, .green, .blue, .purple],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

fileprivate extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ViewModel())
            .environmentObject(LibraryConfig())
    }
}
