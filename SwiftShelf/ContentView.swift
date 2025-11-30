//
//  ContentView.swift
//  SwiftShelf
//
//  Created by michaeldvinci on 8/2/25.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("recentSearches") private var recentSearchesRaw: String = "[]"

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentSearchesRaw.utf8))) ?? []
    }
    private func setRecentSearches(_ newValue: [String]) {
        if let data = try? JSONEncoder().encode(newValue), let str = String(data: data, encoding: .utf8) {
            recentSearchesRaw = str
        }
    }

    @EnvironmentObject var vm: ViewModel
    @EnvironmentObject var config: LibraryConfig
    @EnvironmentObject var audioManager: GlobalAudioManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTabIndex = 0
    @State private var wasLoggedIn = false
    @State private var showSelection = false
    @State private var dummyRefreshTrigger = 0

    @State private var searchText = ""
    @State private var searchSections: [(title: String, items: [SearchDisplayItem])] = []
    @State private var isSearching = false

    @State private var selectedSearchItemID: String? = nil
    @State private var coverCache: [String: Image] = [:]

    @FocusState private var searchFieldIsFocused: Bool
    @FocusState private var focusedResultID: String?

    @State private var selectedMediaItem: LibraryItem? = nil
    @State private var currentEbook: (item: LibraryItem, file: LibraryItem.LibraryFile)? = nil
    @State private var showChapterMenu = false

    var body: some View {
        NavigationView {
            if let selectedItem = selectedMediaItem {
                ItemDetailsFullScreenView(
                    item: selectedItem,
                    isPresented: Binding(
                        get: { selectedMediaItem != nil },
                        set: { if !$0 { selectedMediaItem = nil } }
                    ),
                    selectedTabIndex: $selectedTabIndex,
                    currentEbook: $currentEbook
                )
                .environmentObject(vm)
                .environmentObject(audioManager)
            } else if config.selected.isEmpty {
                connectionSelectionPane
            } else {
                mainTabView
            }
        }
        .onMoveCommand { direction in
            // Handle direction pad navigation if needed
        }
        .onExitCommand {
            // Handle Menu button press - focus on tab bar or go back
            if selectedMediaItem != nil {
                selectedMediaItem = nil
            }
        }
        .sheet(isPresented: $showSelection) {
            LibrarySelectionView(isPresented: $showSelection)
                .environmentObject(vm)
                .environmentObject(config)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                Task {
                    await vm.connect()
                    if !searchText.isEmpty {
                        await searchBooks()
                    }
                }
            }
        }
        .onAppear {
            #if DEBUG
            print("[ContentView] ContentView appeared")
            print("[ContentView] host: \(vm.host.isEmpty ? "empty" : "set"), apiKey: \(vm.apiKey.isEmpty ? "empty" : "set"), selected libraries: \(config.selected.count)")
            #endif
            
            // Focus on first library if we have libraries selected
            if !config.selected.isEmpty {
                selectedTabIndex = 0
            }
            
            if !vm.host.isEmpty && !vm.apiKey.isEmpty {
                if !config.selected.isEmpty {
                    #if DEBUG
                    print("[ContentView] Connecting to server...")
                    #endif
                    Task {
                        await vm.connect()
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        #if DEBUG
                        print("[ContentView] Connection complete")
                        #endif
                    }
                }
            }
        }
        .onChange(of: vm.isLoggedIn) { oldValue, newValue in
            if !oldValue && newValue && !config.selected.isEmpty {
                selectedTabIndex = 0 // Focus on first library
            }
        }
        .onChange(of: config.selected) { oldValue, newValue in
            if vm.isLoggedIn && !newValue.isEmpty {
                selectedTabIndex = 0 // Focus on first library
            }
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTabIndex) {
            ForEach(Array(config.selected.enumerated()), id: \.element.id) { idx, lib in
                LibraryDetailView(library: lib, selectedMediaItem: $selectedMediaItem)
                    .environmentObject(vm)
                    .environmentObject(config)
                    .environmentObject(audioManager)
                    .tabItem {
                        // Tab items should not contain interactive buttons on tvOS
                        Text(lib.name)
                    }
                    .tag(idx)
                    .onTapGesture {
                        // Tapping the active library tab triggers refresh
                        if selectedTabIndex == idx {
                            vm.refreshToken += 1
                        }
                    }
            }

            NowPlayingView()
                .environmentObject(audioManager)
                .environmentObject(vm)
                .tabItem { Image(systemName: "play.circle") }
                .tag(-998)

            // Reading tab
            Group {
                if let ebook = currentEbook {
                    EPUBReaderView(
                        item: ebook.item,
                        ebookFile: ebook.file,
                        showChapterMenu: $showChapterMenu
                    )
                    .environmentObject(vm)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                        Text("No ebook selected")
                            .font(.title2)
                            .foregroundColor(.gray)
                        Text("Select a book and tap READ to start reading")
                            .font(.body)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }
            }
            .tabItem { Image(systemName: "book.fill") }
            .tag(-997)
            .onChange(of: selectedTabIndex) { oldValue, newValue in
                // If user clicks the book tab while already reading, show chapter menu
                if newValue == -997 && oldValue == -997 && currentEbook != nil {
                    showChapterMenu = true
                }
            }

            searchTabView
                .tabItem { Image(systemName: "magnifyingglass") }
                .tag(-1)

            SettingsView()
                .environmentObject(vm)
                .environmentObject(config)
                .tabItem { Image(systemName: "gear") }
                .tag(config.selected.count)
        }
    }

    private var searchTabView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search books, narrators, series...", text: $searchText)
                    .focused($searchFieldIsFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        Task {
                            await searchBooks()
                            addRecentSearch(searchText)
                        }
                    }

                Button {
                    Task {
                        await searchBooks()
                        addRecentSearch(searchText)
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.6), lineWidth: 2)
            )
            .padding()

            if !recentSearches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recentSearches, id: \.self) { term in
                            Button(term) {
                                searchText = term
                                addRecentSearch(term)
                                Task { await searchBooks() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            if isSearching {
                ProgressView()
                    .padding()
            } else {
                if searchSections.isEmpty {
                    VStack {
                        Text("No results")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(searchSections, id: \.title) { section in
                            Section(header: Text(section.title)) {
                                ForEach(section.items) { item in
                                    if section.title == "Books", let libItem = item.libraryItem {
                                        Button {
                                            selectedMediaItem = libItem
                                        } label: {
                                            HStack(spacing: 12) {
                                                if let cachedImage = coverCache[item.id] {
                                                    cachedImage
                                                        .resizable()
                                                        .frame(width: 48, height: 48)
                                                        .cornerRadius(6)
                                                } else {
                                                    Rectangle()
                                                        .fill(Color.gray.opacity(0.3))
                                                        .frame(width: 48, height: 48)
                                                        .cornerRadius(6)
                                                        .task {
                                                            await loadCover(for: libItem)
                                                        }
                                                }
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(item.title)
                                                        .font(.headline)
                                                    if let subtitle = item.subtitle {
                                                        Text(subtitle)
                                                            .font(.subheadline)
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                                Spacer()
                                            }
                                            .padding(.vertical, 4)
                                            .contentShape(Rectangle())
                                            .background(selectedSearchItemID == item.id ? Color.accentColor.opacity(0.2) : Color.clear)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .focused($focusedResultID, equals: item.id)
                                        .onAppear {
                                            if selectedSearchItemID == nil && focusedResultID == nil {
                                                selectedSearchItemID = item.id
                                            }
                                        }
                                        .accessibilityRespondsToUserInteraction(true)
                                    } else {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title)
                                                .font(.headline)
                                            if let subtitle = item.subtitle {
                                                Text(subtitle)
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                        .background(selectedSearchItemID == item.id ? Color.accentColor.opacity(0.2) : Color.clear)
                                        .focused($focusedResultID, equals: item.id)
                                        .onAppear {
                                            if selectedSearchItemID == nil && focusedResultID == nil {
                                                selectedSearchItemID = item.id
                                            }
                                        }
                                        .onTapGesture {
                                            selectedSearchItemID = item.id
                                            focusedResultID = item.id
                                        }
                                        .accessibilityRespondsToUserInteraction(true)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.grouped)
                }
            }
        }
    }

    @State private var connectionLoginMethod: LoginMethod = .apiKey
    @State private var connectionUsername: String = ""
    @State private var connectionPassword: String = ""
    @State private var isConnecting: Bool = false

    private var connectionSelectionPane: some View {
        VStack(spacing: 16) {
            Text("SwiftShelf").font(.title2)

            // Host field (always shown)
            TextField("Host (e.g., https://abs.example.com)", text: $vm.host)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.6), lineWidth: 2)
                )
                .autocapitalization(.none)
                .disableAutocorrection(true)

            // Login method picker
            Picker("Login Method", selection: $connectionLoginMethod) {
                ForEach(LoginMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 8)

            // Credentials based on selected method
            VStack(spacing: 8) {
                switch connectionLoginMethod {
                case .apiKey:
                    SecureField("API Key", text: $vm.apiKey)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                        )
                case .userPass:
                    TextField("Username", text: $connectionUsername)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("Password", text: $connectionPassword)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                        )
                }
            }
            .onAppear {
                #if DEBUG
                // Pre-populate with config values for debug builds
                if let configURL = Bundle.main.url(forResource: ".swiftshelf-config", withExtension: "json"),
                   let data = try? Data(contentsOf: configURL),
                   let config = try? JSONDecoder().decode(DevConfig.self, from: data) {
                    if vm.host.isEmpty {
                        vm.saveCredentialsToKeychain(host: config.host, apiKey: config.apiKey)
                    }
                }
                #endif
            }

            Button {
                Task {
                    isConnecting = true
                    switch connectionLoginMethod {
                    case .apiKey:
                        vm.saveCredentialsToKeychain(host: vm.host, apiKey: vm.apiKey)
                        await vm.connect()
                    case .userPass:
                        let success = await vm.loginWithCredentials(
                            host: vm.host,
                            username: connectionUsername,
                            password: connectionPassword
                        )
                        if success {
                            await vm.connect()
                        }
                    }
                    isConnecting = false
                }
            } label: {
                if isConnecting || vm.isLoadingLibraries {
                    ProgressView()
                } else {
                    Text("Connect").bold()
                }
            }
            .disabled(vm.host.isEmpty || isConnecting || (connectionLoginMethod == .apiKey && vm.apiKey.isEmpty) || (connectionLoginMethod == .userPass && (connectionUsername.isEmpty || connectionPassword.isEmpty)))

            Button("Select Libraries") {
                showSelection = true
            }
            .disabled(vm.libraries.isEmpty)

            if let err = vm.errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            List(vm.libraries) { lib in
                HStack {
                    Text(lib.name)
                    Spacer()
                    Text(lib.id)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            Spacer()
        }
    }

    private func searchBooks() async {
        guard !config.selected.isEmpty else { return }
        guard let firstLibrary = config.selected.first else { return }
        guard !searchText.isEmpty else {
            searchSections = []
            return
        }

        isSearching = true
        vm.errorMessage = nil

        do {
            let host = vm.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let libraryID = firstLibrary.id
            let query = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "\(host)/api/libraries/\(libraryID)/search?q=\(query)&limit=5"

            guard let url = URL(string: urlString) else {
                vm.errorMessage = "Invalid search URL."
                searchSections = []
                isSearching = false
                return
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(vm.apiKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                vm.errorMessage = "Invalid response."
                searchSections = []
                isSearching = false
                return
            }

            guard httpResponse.statusCode == 200 else {
                vm.errorMessage = "Search request failed with status \(httpResponse.statusCode)."
                searchSections = []
                isSearching = false
                return
            }

            let decoder = JSONDecoder()
            let results = try decoder.decode(SearchResponse.self, from: data)

            var sections: [(title: String, items: [SearchDisplayItem])] = []

            if let books = results.book, !books.isEmpty {
                let bookItems = books.compactMap { bookResult -> SearchDisplayItem? in
                    let item = bookResult.libraryItem
                    return SearchDisplayItem(id: item.id, title: item.title, subtitle: item.authorNameLF ?? item.authorName, libraryItem: item)
                }
                if !bookItems.isEmpty {
                    sections.append((title: "Books", items: bookItems))
                }
            }

            if let narrators = results.narrators, !narrators.isEmpty {
                let narratorItems = narrators.map { narrator -> SearchDisplayItem in
                    let subtitle = narrator.numBooks != nil ? "\(narrator.numBooks!) books" : nil
                    return SearchDisplayItem(id: narrator.name, title: narrator.name, subtitle: subtitle, libraryItem: nil)
                }
                if !narratorItems.isEmpty {
                    sections.append((title: "Narrators", items: narratorItems))
                }
            }

            if let seriesArr = results.series, !seriesArr.isEmpty {
                let seriesItems = seriesArr.map { seriesResult in
                    SearchDisplayItem(id: seriesResult.series.id, title: seriesResult.series.name, subtitle: nil, libraryItem: nil)
                }
                if !seriesItems.isEmpty {
                    sections.append((title: "Series", items: seriesItems))
                }
            }

            searchSections = sections

        } catch {
            vm.errorMessage = "Error searching: \(error.localizedDescription)"
            searchSections = []
        }

        isSearching = false
    }

    private func loadCover(for item: LibraryItem) async {
        if coverCache[item.id] != nil { return }
        if let imageTuple = await vm.loadCover(for: item) {
            coverCache[item.id] = imageTuple.0
        }
    }

    private func addRecentSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var recents = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        recents.insert(trimmed, at: 0)
        setRecentSearches(Array(recents.prefix(8)))
    }

    // MARK: - Models for search response and display

    struct SearchResponse: Decodable {
        let book: [BookResult]?
        let narrators: [NarratorResult]?
        let tags: [TagResult]?
        let genres: [GenreResult]?
        let series: [SeriesResult]?
    }

    struct BookResult: Decodable {
        let libraryItem: LibraryItem
    }

    struct NarratorResult: Decodable {
        let name: String
        let numBooks: Int?
    }

    struct SeriesResult: Decodable {
        let series: Series
        struct Series: Decodable {
            let id: String
            let name: String
        }
    }

    struct TagResult: Decodable {
        let id: String
        let name: String
    }

    struct GenreResult: Decodable {
        let id: String
        let name: String
    }

    struct SearchDisplayItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let libraryItem: LibraryItem?
    }

    @ViewBuilder
    private func NowPlayingView() -> some View {
        ZStack {
            // Blurry background
            if let current = audioManager.currentItem {
                // Use cover art as blurred background
                if let coverArt = audioManager.coverArt?.0 {
                    coverArt
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 50)
                        .scaleEffect(1.2)
                        .ignoresSafeArea()
                } else if let image = coverCache[current.id] {
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 50)
                        .scaleEffect(1.2)
                        .ignoresSafeArea()
                } else {
                    // Fallback gradient background
                    LinearGradient(
                        colors: [.black, .gray.opacity(0.8), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
            } else {
                // Default background when nothing is playing
                LinearGradient(
                    colors: [.black, .gray.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            // Dark overlay to ensure text readability
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Main content
            if let current = audioManager.currentItem {
                let chapters = current.chapters

                VStack(spacing: 40) {
                    HStack(alignment: .center, spacing: 80) {
                        // Left side: Large cover art
                        VStack {
                            if let coverArt = audioManager.coverArt?.0 {
                                coverArt
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 500, maxHeight: 500)
                                    .cornerRadius(20)
                                    .shadow(radius: 20)
                            } else if let image = coverCache[current.id] {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 500, maxHeight: 500)
                                    .cornerRadius(20)
                                    .shadow(radius: 20)
                            } else {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 500, height: 500)
                                    .cornerRadius(20)
                                    .shadow(radius: 20)
                                    .task {
                                        await loadCover(for: current)
                                    }
                            }
                        }

                        // Right side: Metadata and controls
                        VStack(alignment: .leading, spacing: 24) {
                            // Title
                            Text(current.title)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            // Author
                            Text(current.authorNameLF ?? current.authorName ?? "Unknown Author")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)

                            // Current chapter (if available)
                            if !chapters.isEmpty {
                                let currentChapter = chapters.first { chapter in
                                    audioManager.currentTime >= chapter.start && audioManager.currentTime <= chapter.end
                                } ?? chapters.first

                                if let chapter = currentChapter {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Chapter \(chapters.firstIndex(of: chapter).map { $0 + 1 } ?? 1)")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                            .textCase(.uppercase)

                                        Text(chapter.title)
                                            .font(.title3)
                                            .foregroundColor(.white.opacity(0.9))
                                            .lineLimit(2)
                                    }

                                    // Chapter progress
                                    ChapterSeekBar(
                                        currentTime: max(0, audioManager.currentTime - chapter.start),
                                        duration: max(0, chapter.end - chapter.start),
                                        chapters: chapters,
                                        currentChapterIndex: chapters.firstIndex(of: chapter) ?? 0,
                                        audioManager: audioManager,
                                        onSeek: { seekTime in
                                            audioManager.seek(to: chapter.start + seekTime)
                                        }
                                    )
                                    .padding(.top, 16)
                                }
                            } else {
                                // Overall progress if no chapters
                                if let duration = current.duration {
                                    ChapterSeekBar(
                                        currentTime: audioManager.currentTime,
                                        duration: duration,
                                        chapters: [],
                                        currentChapterIndex: 0,
                                        audioManager: audioManager,
                                        onSeek: { seekTime in
                                            audioManager.seek(to: seekTime)
                                        }
                                    )
                                    .padding(.top, 16)
                                }
                            }
                        }
                        .frame(maxWidth: 600)
                    }

                    // Chapter navigation (if chapters exist)
                    if !chapters.isEmpty && chapters.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                                    let isCurrentChapter = audioManager.currentTime >= chapter.start && audioManager.currentTime <= chapter.end

                                    Button {
                                        audioManager.seek(to: chapter.start)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Chapter \(index + 1)")
                                                .font(.caption2)
                                                .textCase(.uppercase)

                                            Text(chapter.title)
                                                .font(.caption)
                                                .lineLimit(1)
                                                .frame(maxWidth: 200, alignment: .leading)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(ChapterButtonStyle(isCurrent: isCurrentChapter))
                                }
                            }
                            .padding(.horizontal, 40)
                        }
                        .frame(height: 80)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 60)
                .task {
                    // Load cover into cache if not already loaded
                    if coverCache[current.id] == nil {
                        await loadCover(for: current)
                    }
                }

            } else {
                // Nothing playing state
                VStack(spacing: 32) {
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundColor(.white.opacity(0.6))

                    VStack(spacing: 8) {
                        Text("Nothing Playing")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)

                        Text("Select an audiobook to start listening")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPlayPauseCommand {
            print("[NowPlayingView] 🎮 onPlayPauseCommand received")
            audioManager.togglePlayPause()
        }
    }

    // MARK: - tvOS Chapter Progress Display (Non-interactive)
    struct ChapterSeekBar: View {
        let currentTime: Double
        let duration: Double
        let chapters: [LibraryItem.Chapter]
        let currentChapterIndex: Int
        let audioManager: GlobalAudioManager
        let onSeek: (Double) -> Void

        var body: some View {
            VStack(spacing: 16) {
                // Use ProgressView for tvOS since Slider is not available
                ProgressView(value: duration > 0 ? max(0, min(1, currentTime / duration)) : 0)
                    .tint(.white)

                // Time labels
                HStack {
                    Text(timeString(max(0, currentTime)))
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Text(timeString(duration))
                        .font(.caption)
                        .monospacedDigit()
                }

                // Playback controls
                HStack(spacing: 24) {
                    // Previous chapter button
                    Button {
                        if !chapters.isEmpty && currentChapterIndex > 0 {
                            audioManager.seek(to: chapters[currentChapterIndex - 1].start)
                        }
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .disabled(chapters.isEmpty || currentChapterIndex == 0)
                    .opacity((chapters.isEmpty || currentChapterIndex == 0) ? 0.3 : 1.0)

                    // Back 30s button
                    Button {
                        let newTime = max(0, currentTime - 30)
                        onSeek(newTime)
                    } label: {
                        Image(systemName: "gobackward.30")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(PlayerControlButtonStyle())

                    // Play/Pause button
                    Button {
                        if audioManager.isPlaying {
                            audioManager.pause()
                        } else {
                            audioManager.play()
                        }
                    } label: {
                        Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Forward 30s button
                    Button {
                        let newTime = min(duration, currentTime + 30)
                        onSeek(newTime)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(PlayerControlButtonStyle())

                    // Next chapter button
                    Button {
                        if !chapters.isEmpty && currentChapterIndex < chapters.count - 1 {
                            audioManager.seek(to: chapters[currentChapterIndex + 1].start)
                        }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .disabled(chapters.isEmpty || currentChapterIndex >= chapters.count - 1)
                    .opacity((chapters.isEmpty || currentChapterIndex >= chapters.count - 1) ? 0.3 : 1.0)
                }

                // Playback speed control
                PlaybackSpeedControl(audioManager: audioManager)
            }
        }
        
        private func timeString(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - Playback Speed Control
    struct PlaybackSpeedControl: View {
        @ObservedObject var audioManager: GlobalAudioManager

        var body: some View {
            HStack(spacing: 20) {
                Text("Speed:")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))

                // Decrease speed button (by 0.25)
                Button {
                    let newRate = max(0.5, audioManager.rate - 0.25)
                    audioManager.setRate(newRate)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(PlayerControlButtonStyle())
                .disabled(audioManager.rate <= 0.5)
                .opacity(audioManager.rate <= 0.5 ? 0.3 : 1.0)

                // Current speed display
                Text(formatSpeed(audioManager.rate))
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(minWidth: 60)
                    .fontWeight(.medium)

                // Increase speed button (by 0.25)
                Button {
                    let newRate = min(3.0, audioManager.rate + 0.25)
                    audioManager.setRate(newRate)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(PlayerControlButtonStyle())
                .disabled(audioManager.rate >= 3.0)
                .opacity(audioManager.rate >= 3.0 ? 0.3 : 1.0)
            }
            .padding(.top, 12)
        }

        private func formatSpeed(_ speed: Float) -> String {
            return String(format: "%.2fx", speed)
        }
    }

    // MARK: - Custom Button Styles for tvOS
    struct PlayerControlButtonStyle: ButtonStyle {
        @Environment(\.isFocused) var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundColor(isFocused ? .black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isFocused ? Color.white : Color.clear)
                )
        }
    }

    struct ChapterButtonStyle: ButtonStyle {
        let isCurrent: Bool
        @Environment(\.isFocused) var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundColor(isFocused ? .black : .white)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isFocused ? Color.white : (isCurrent ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.1)))
                )
        }
    }

    // MARK: - Full-screen Item Details View
    struct ItemDetailsFullScreenView: View {
        let item: LibraryItem
        @Binding var isPresented: Bool
        @EnvironmentObject var vm: ViewModel
        @EnvironmentObject var audioManager: GlobalAudioManager
        @State private var coverImage: Image? = nil
        @State private var showFullDescription = false
        @State private var fullItem: LibraryItem? = nil

        // Focus management for tvOS navigation
        @FocusState private var closeButtonFocused: Bool
        @FocusState private var playButtonFocused: Bool
        @FocusState private var descriptionButtonFocused: Bool
        @FocusState private var focusedChapterID: String?

        // Access to parent's state
        @Binding var selectedTabIndex: Int
        @Binding var currentEbook: (item: LibraryItem, file: LibraryItem.LibraryFile)?

        // Use fullItem if loaded, otherwise fallback to item
        private var displayItem: LibraryItem {
            fullItem ?? item
        }

        var body: some View {
            ZStack {
                // Blurry background using cover art (matching Now Playing style)
                if let coverImage {
                    coverImage
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 50)
                        .scaleEffect(1.2)
                        .ignoresSafeArea()
                } else {
                    // Fallback gradient background
                    LinearGradient(
                        colors: [.black, .gray.opacity(0.8), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
                
                // Dark overlay to ensure text readability
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                // Main content - properly centered
                HStack(alignment: .center, spacing: 80) {
                    // Left side: XL cover art
                    VStack {
                        if let coverImage {
                            coverImage
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 600, maxHeight: 700)
                                .cornerRadius(20)
                                .shadow(radius: 20)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 600, height: 700)
                                .cornerRadius(20)
                                .shadow(radius: 20)
                                .task { await loadCover() }
                        }
                    }
                    
                    // Right side: metadata and actions
                    VStack {
                        // Fixed spacer to push content to match cover art center
                        Spacer()

                        VStack(alignment: .leading, spacing: 16) {
                            titleSection
                            seriesSection
                            authorSection
                            descriptionSection
                            playButtonSection
                            chapterListSection
                        }

                        Spacer()
                    }
                    .frame(maxWidth: 650)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 60)
            }
            .task {
                // Load full item details with chapters
                if let details = await vm.fetchLibraryItemDetails(itemId: item.id) {
                    fullItem = details
                }
            }
            .onAppear {
                // Set initial focus to close button after a slight delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    closeButtonFocused = true
                }
            }
        }
        
        // MARK: - Computed View Sections
        
        @ViewBuilder
        private var closeButtonSection: some View {
            HStack {
                Spacer()
                Button("Close") { 
                    isPresented = false 
                }
                .buttonStyle(.bordered)
                .focused($closeButtonFocused)
            }
        }
        
        @ViewBuilder
        private var titleSection: some View {
            Text(displayItem.title)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(.white)
        }

        @ViewBuilder
        private var seriesSection: some View {
            EmptyView()
        }

        @ViewBuilder
        private var authorSection: some View {
            if let author = displayItem.authorNameLF ?? displayItem.authorName {
                Text(author)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
            }
        }

        @ViewBuilder
        private var descriptionSection: some View {
            if !displayItem.descriptionText.isEmpty {
                Button {
                    showFullDescription = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayItem.descriptionText)
                            .font(.subheadline)
                            .foregroundColor(descriptionButtonFocused ? .black : .white.opacity(0.8))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack {
                            Text("More")
                                .font(.caption)
                                .foregroundColor(descriptionButtonFocused ? .black : .accentColor)
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .focused($descriptionButtonFocused)
                .alert(displayItem.title, isPresented: $showFullDescription) {
                    Button("Close", role: .cancel) {
                        showFullDescription = false
                    }
                } message: {
                    Text(displayItem.descriptionText)
                }
            }
        }
        
        @ViewBuilder
        private var playButtonSection: some View {
            HStack(spacing: 16) {
                Button {
                    Task {
                        // Load the item into the audio manager (use fullItem if available for chapters)
                        await audioManager.loadItem(displayItem, appVM: vm)
                        // Start playback
                        audioManager.play()
                        // Switch to Now Playing tab (-998)
                        selectedTabIndex = -998
                        // Close this overlay
                        isPresented = false
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .focused($playButtonFocused)

                if displayItem.hasEbook, let ebookFile = displayItem.ebookFile {
                    Button {
                        // Set current ebook and switch to Reading tab
                        currentEbook = (item: displayItem, file: ebookFile)
                        selectedTabIndex = -997
                        isPresented = false
                    } label: {
                        Label("Read", systemImage: "book.fill")
                            .font(.title3)
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }

        @ViewBuilder
        private var chapterListSection: some View {
            if !displayItem.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Chapters")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.top, 8)

                    List {
                        ForEach(Array(displayItem.chapters.enumerated()), id: \.offset) { index, chapter in
                            Button {
                                Task {
                                    // Load the item with explicit start time (chapter start)
                                    if audioManager.currentItem?.id != displayItem.id {
                                        await audioManager.loadItem(displayItem, appVM: vm, startTime: chapter.start)
                                    } else {
                                        // Item already loaded, just seek to chapter
                                        audioManager.seek(to: chapter.start)
                                    }
                                    // Start playback
                                    audioManager.play()
                                    // Switch to Now Playing tab
                                    selectedTabIndex = -998
                                    // Close overlay
                                    isPresented = false
                                }
                            } label: {
                                HStack {
                                    Text(chapter.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .multilineTextAlignment(.leading)

                                    Spacer()

                                    Text(durationString(max(0, chapter.end - chapter.start)))
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.1))
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 300)
//                    .scrollContentBackground(.hidden)
                }
            }
        }
        
        private func loadCover() async {
            if let tuple = await vm.loadCover(for: item) {
                coverImage = tuple.0
            }
        }
        
        private func durationString(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
            return String(format: "%d:%02d", m, s)
        }
    }

    #if DEBUG
    private struct DevConfig: Codable {
        let host: String
        let apiKey: String
    }
    #endif

}

