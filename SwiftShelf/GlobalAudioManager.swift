//
//  GlobalAudioManager.swift
//  SwiftShelf
//
//  Created by michaeldvinci on 10/21/25.
//

import SwiftUI
import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class GlobalAudioManager: NSObject, ObservableObject {
    static let shared = GlobalAudioManager()
    
    @Published var currentItem: LibraryItem?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0
    @Published var sleepRemaining: TimeInterval?
    @Published var currentTrackIndex: Int = 0
    @Published var currentTrackTitle: String = ""
    @Published var hasAudioStream: Bool = false
    @Published var loadingStatus: String = "Ready"
    @Published var coverArt: (Image, UIImage)?
    
    @Published var currentChapterStart: Double = 0
    @Published var currentChapterDuration: Double = 0
    
    private var playerViewModel: PlayerViewModel?
    private var cancellables = Set<AnyCancellable>()

    // Cached resume position (seconds) to apply on first play after load
    private var pendingResumeSeconds: Double?

    private weak var appViewModel: ViewModel?

    // Session management (canonical ABS flow)
    private var currentSessionId: String?
    private var lastSyncTime: Date?              // When we last sent a sync
    private var lastSyncPosition: Double = 0     // Position at last sync
    private var sessionSyncTimer: Timer?          // Periodic session sync (15s - matches official app)
    private var progressSyncTimer: Timer?         // Periodic progress PATCH (90s)

    private override init() {
        super.init()
        print("===========================================")
        print("[GlobalAudioManager] 🎬🎬🎬 INITIALIZED v2.0 🎬🎬🎬")
        print("===========================================")
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        print("[GlobalAudioManager] 🎮 Setting up ALL remote commands...")

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: playCommand received")
            Task { @MainActor in
                self?.play()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: pauseCommand received")
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: togglePlayPauseCommand received")
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        // Stop command - some systems send this
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: stopCommand received")
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        // Skip commands
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: skipBackwardCommand received")
            Task { @MainActor in
                self?.skip(-15)
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: skipForwardCommand received")
            Task { @MainActor in
                self?.skip(15)
            }
            return .success
        }

        // Next/Previous track commands
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: nextTrackCommand received")
            Task { @MainActor in
                self?.nextChapter()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            print("[GlobalAudioManager] 🎮 REMOTE: previousTrackCommand received")
            Task { @MainActor in
                self?.previousChapter()
            }
            return .success
        }

        // Change playback position command (scrubbing)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            print("[GlobalAudioManager] 🎮 REMOTE: changePlaybackPositionCommand to \(event.positionTime)s")
            Task { @MainActor in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        print("[GlobalAudioManager] 🎮 Remote commands setup complete")
    }
    
    func loadItem(_ item: LibraryItem, appVM: ViewModel, startTime: Double? = nil) async {
        print("===========================================")
        print("[GlobalAudioManager] 🚀🚀🚀 LOADING ITEM v2.0 🚀🚀🚀")
        print("[GlobalAudioManager] 🚀 Loading item: \(item.title)")
        print("[GlobalAudioManager] 📊 Item ID: \(item.id)")
        print("[GlobalAudioManager] 📊 Duration from item: \(item.duration.map { String($0) } ?? "nil")")
        print("[GlobalAudioManager] 📊 Media present: \(item.media != nil)")
        if let media = item.media {
            print("[GlobalAudioManager] 📊 Media duration: \(media.duration.map { String($0) } ?? "nil")")
        }
        if let startTime = startTime {
            print("[GlobalAudioManager] 🎯 Explicit start time requested: \(startTime)s")
        }
        print("===========================================")

        // If duration is missing, fetch full details
        var itemToUse = item
        if item.duration == nil {
            print("[GlobalAudioManager] ⚠️ Duration missing, fetching full item details...")
            if let fullItem = await appVM.fetchLibraryItemDetails(itemId: item.id) {
                print("[GlobalAudioManager] ✅ Full item fetched, duration: \(fullItem.duration.map { String($0) } ?? "nil")")
                itemToUse = fullItem
            } else {
                print("[GlobalAudioManager] ❌ Failed to fetch full item details")
            }
        }

        // Store reference to appViewModel for progress saving
        self.appViewModel = appVM

        // Stop current playback
        await stopCurrentPlayback()

        // Set new current item (use the one with duration if we fetched it)
        currentItem = itemToUse
        loadingStatus = "Loading \(itemToUse.title)..."

        print("[GlobalAudioManager] 🖼️ Loading cover art...")
        // Load cover art
        if let coverTuple = await appVM.loadCover(for: itemToUse) {
            coverArt = coverTuple
            print("[GlobalAudioManager] ✅ Cover art loaded successfully")
        } else {
            print("[GlobalAudioManager] ❌ Failed to load cover art")
        }

        print("[GlobalAudioManager] 🎵 Creating PlayerViewModel...")
        // Create new player view model
        let newPlayerVM = PlayerViewModel(item: itemToUse, appVM: appVM)
        playerViewModel = newPlayerVM

        // Bind to player view model
        print("[GlobalAudioManager] 🔗 Binding to PlayerViewModel...")
        bindToPlayerViewModel(newPlayerVM)

        // Configure and prepare (but don't auto-play)
        print("[GlobalAudioManager] ⚙️ Configuring and preparing player...")
        await newPlayerVM.configureAndPrepare()

        // Set pending resume position
        if let startTime = startTime {
            // Explicit start time provided (e.g., from chapter selection)
            print("[GlobalAudioManager] 🎯 Using explicit start time: \(startTime)s")
            self.pendingResumeSeconds = startTime
        } else if let last = await appVM.loadProgress(for: itemToUse) {
            // Resume from last position
            let resume = max(0, last - 5)
            print("[GlobalAudioManager] ⏪ Cached resume position: \(resume)s (from server: \(last)s)")
            self.pendingResumeSeconds = resume
        } else {
            self.pendingResumeSeconds = nil
        }

        print("[GlobalAudioManager] ✅ Item loading complete")
    }
    
    func play() {
        print("===========================================")
        print("[GlobalAudioManager] ▶️▶️▶️ PLAY (Canonical ABS Flow) ▶️▶️▶️")
        print("[GlobalAudioManager] currentItem: \(currentItem?.title ?? "nil")")
        print("[GlobalAudioManager] currentItem.id: \(currentItem?.id ?? "nil")")
        print("[GlobalAudioManager] currentItem.duration: \(currentItem?.duration.map { String($0) } ?? "nil")")
        print("[GlobalAudioManager] currentSessionId: \(currentSessionId ?? "nil")")
        print("[GlobalAudioManager] playerViewModel is nil: \(playerViewModel == nil)")
        print("[GlobalAudioManager] playerViewModel?.player is nil: \(playerViewModel?.player == nil)")
        print("===========================================")

        // Apply cached resume position if this is the first play
        if let resume = pendingResumeSeconds, resume > 0 {
            print("[GlobalAudioManager] ⤴️ Applying cached resume before play: \(resume)s")
            playerViewModel?.seek(to: resume)
            pendingResumeSeconds = nil
        }

        print("[GlobalAudioManager] ▶️ Calling playerViewModel?.play()...")
        playerViewModel?.play()
        print("[GlobalAudioManager] ▶️ playerViewModel?.play() returned")

        // Start periodic timers for session sync (20s) and progress PATCH (90s)
        startPeriodicTimers()

        // Start playback session if not already started
        if currentSessionId == nil {
            print("[GlobalAudioManager] 🚀 No session exists, starting playback session...")
            startPlaybackSession()
        } else {
            print("[GlobalAudioManager] ✅ Session already exists: \(currentSessionId!)")
        }
    }

    func pause() {
        print("[GlobalAudioManager] ⏸️ Pause requested")

        playerViewModel?.pause()

        // Stop periodic timers (session stays open - matches official app behavior)
        stopPeriodicTimers()

        // Do final sync with current state before stopping timers
        saveProgressAndSyncSession()

        // Ensure remote commands stay enabled after pause
        // This is critical for tvOS to continue routing play commands to our app
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        print("[GlobalAudioManager] ⏸️ Remote commands confirmed enabled after pause")

        // NOTE: Session stays open during pause. It will close when:
        // - User loads a different item (stopCurrentPlayback)
        // - App terminates
        // This matches the official audiobookshelf-app behavior
    }
    
    func togglePlayPause() {
        print("===========================================")
        print("[GlobalAudioManager] ⏯️⏯️⏯️ TOGGLE PLAY/PAUSE ⏯️⏯️⏯️")
        print("[GlobalAudioManager] ⏯️ isPlaying (GlobalAudioManager): \(isPlaying)")
        print("[GlobalAudioManager] ⏯️ playerViewModel?.isPlaying: \(playerViewModel?.isPlaying ?? false)")
        print("[GlobalAudioManager] ⏯️ playerViewModel is nil: \(playerViewModel == nil)")
        print("===========================================")

        // Directly call play() or pause() based on current state
        // This avoids the state sync issues with delegating to playerViewModel.togglePlayPause()
        if isPlaying {
            print("[GlobalAudioManager] ⏯️ -> Calling pause()")
            pause()
        } else {
            print("[GlobalAudioManager] ⏯️ -> Calling play()")
            play()
        }
    }
    
    func seek(to seconds: Double) {
        print("[GlobalAudioManager] ⏩ Seek to \(seconds)s requested")
        playerViewModel?.seek(to: seconds)

        // Clear pending resume so play() doesn't override this manual seek
        if pendingResumeSeconds != nil {
            print("[GlobalAudioManager] 🧹 Clearing pending resume (was: \(pendingResumeSeconds!)s)")
            pendingResumeSeconds = nil
        }

        // NOTE: Official app does NOT sync immediately on seek
        // It waits for the next periodic sync interval (15s)
        // This prevents spam syncing during rapid seeking
    }
    
    func skip(_ by: Double) {
        print("[GlobalAudioManager] ⏭️ Skip by \(by)s requested")
        playerViewModel?.skip(by)
    }
    
    func previousChapter() {
        print("[GlobalAudioManager] ⏮️ Previous chapter requested")
        playerViewModel?.previousChapter()
    }
    
    func nextChapter() {
        print("[GlobalAudioManager] ⏭️ Next chapter requested")
        playerViewModel?.nextChapter()
    }
    
    func toggleRate() {
        print("[GlobalAudioManager] 🏃‍♂️ Toggle rate requested")
        playerViewModel?.toggleRate()
    }
    
    func setRate(_ newRate: Float) {
        print("[GlobalAudioManager] 🏃‍♂️ Set rate: \(newRate)")
        playerViewModel?.setRate(newRate)
        self.rate = playerViewModel?.rate ?? newRate
    }
    
    func setSleep(minutes: Int) {
        print("[GlobalAudioManager] 😴 Set sleep timer: \(minutes) minutes")
        playerViewModel?.setSleep(minutes: minutes)
    }
    
    func cancelSleepTimer() {
        print("[GlobalAudioManager] ⏰ Cancel sleep timer")
        playerViewModel?.cancelSleepTimer()
    }
    
    var avPlayer: AVPlayer? {
        return playerViewModel?.avPlayer
    }
    
    private func stopCurrentPlayback() async {
        print("[GlobalAudioManager] ⏹️ Stopping current playback")

        // Stop periodic timers
        stopPeriodicTimers()

        // Save final progress and close session
        saveProgressAndSyncSession()
        await closeCurrentSession()

        playerViewModel?.teardown()
        playerViewModel = nil
        cancellables.removeAll()

        // Reset state
        isPlaying = false
        currentTime = 0
        duration = 0
        rate = 1.0
        sleepRemaining = nil
        currentTrackIndex = 0
        currentTrackTitle = ""
        hasAudioStream = false
        pendingResumeSeconds = nil
        currentChapterStart = 0
        currentChapterDuration = 0
        print("[GlobalAudioManager] 🔄 State reset complete")
    }
    
    private func bindToPlayerViewModel(_ playerVM: PlayerViewModel) {
        print("[GlobalAudioManager] 📡 Setting up bindings...")
        cancellables.removeAll()
        
        // Use sink instead of assign for cross-object bindings
        playerVM.$isPlaying
            .sink { [weak self] value in
                self?.isPlaying = value
            }
            .store(in: &cancellables)
        
        playerVM.$currentTime
            .sink { [weak self] value in
                self?.currentTime = value
            }
            .store(in: &cancellables)
        
        playerVM.$duration
            .sink { [weak self] value in
                self?.duration = value
            }
            .store(in: &cancellables)
        
        playerVM.$rate
            .sink { [weak self] value in
                self?.rate = value
            }
            .store(in: &cancellables)
        
        playerVM.$sleepRemaining
            .sink { [weak self] value in
                self?.sleepRemaining = value
            }
            .store(in: &cancellables)
        
        playerVM.$currentTrackIndex
            .sink { [weak self] value in
                self?.currentTrackIndex = value
            }
            .store(in: &cancellables)
        
        playerVM.$currentTrackTitle
            .sink { [weak self] value in
                self?.currentTrackTitle = value
            }
            .store(in: &cancellables)
        
        playerVM.$hasAudioStream
            .sink { [weak self] value in
                self?.hasAudioStream = value
            }
            .store(in: &cancellables)
        
        playerVM.$loadingStatus
            .sink { [weak self] value in
                self?.loadingStatus = value
            }
            .store(in: &cancellables)
        
        playerVM.$currentChapterStart
            .sink { [weak self] value in
                self?.currentChapterStart = value
            }
            .store(in: &cancellables)

        playerVM.$currentChapterDuration
            .sink { [weak self] value in
                self?.currentChapterDuration = value
            }
            .store(in: &cancellables)
        
        print("[GlobalAudioManager] ✅ Bindings setup complete")
    }


    // MARK: - Session Management (Canonical ABS Flow)

    /// Start playback session using canonical /api/items/{id}/play
    private func startPlaybackSession() {
        guard let item = currentItem else {
            print("[GlobalAudioManager] ❌ Cannot start session: no current item")
            return
        }
        guard let appVM = appViewModel else {
            print("[GlobalAudioManager] ❌ Cannot start session: no appViewModel")
            return
        }

        print("[GlobalAudioManager] 🚀🚀🚀 STARTING PLAYBACK SESSION 🚀🚀🚀")
        print("[GlobalAudioManager] Item: \(item.title)")
        print("[GlobalAudioManager] Item ID: \(item.id)")

        Task {
            if let result = await appVM.startPlaybackSession(for: item) {
                currentSessionId = result.sessionId
                lastSyncTime = Date()
                lastSyncPosition = currentTime
                print("[GlobalAudioManager] ✅✅✅ Playback session started: \(result.sessionId)")
            } else {
                print("[GlobalAudioManager] ❌❌❌ Failed to start playback session")
            }
        }
    }

    /// Send periodic sync every 15s with delta timeListened
    private func syncSessionPeriodic() {
        guard let sessionId = currentSessionId else { return }
        guard let appVM = appViewModel else { return }
        guard isPlaying else { return } // Only sync while playing
        guard let item = currentItem else { return }

        let now = Date()
        let currentPosition = currentTime

        // Use player duration, but fallback to item duration if player hasn't loaded yet
        var totalDuration = duration
        if totalDuration <= 0, let itemDuration = item.duration {
            totalDuration = itemDuration
        }

        guard totalDuration > 0 else {
            print("[GlobalAudioManager] ⚠️ Cannot sync session: duration is 0")
            return
        }

        // Calculate delta time listened since last sync
        let deltaTime: Double
        if let lastSync = lastSyncTime {
            deltaTime = now.timeIntervalSince(lastSync)
        } else {
            deltaTime = 0
        }

        print("[GlobalAudioManager] 📤 Periodic session sync: pos=\(currentPosition)s, delta=\(deltaTime)s")

        Task {
            await appVM.syncSession(
                sessionId: sessionId,
                currentTime: currentPosition,
                timeListened: deltaTime,
                duration: totalDuration
            )
        }

        // Update last sync tracking
        lastSyncTime = now
        lastSyncPosition = currentPosition
    }

    /// Save durable progress via PATCH /api/me/progress
    private func saveProgressAndSyncSession() {
        guard let item = currentItem else { return }
        guard let appVM = appViewModel else { return }

        let currentPosition = currentTime

        // Use player duration, but fallback to item duration if player hasn't loaded yet
        var totalDuration = duration
        if totalDuration <= 0, let itemDuration = item.duration {
            totalDuration = itemDuration
        }

        // Still bail if we have no duration at all
        guard totalDuration > 0 else {
            print("[GlobalAudioManager] ⚠️ Cannot save progress: duration is 0")
            return
        }

        print("[GlobalAudioManager] 💾 Saving durable progress: \(currentPosition)s / \(totalDuration)s")

        Task {
            // Save progress to durable storage
            await appVM.saveProgress(for: item, seconds: currentPosition, duration: totalDuration)

            // Also send session sync if session is active
            if let sessionId = currentSessionId {
                let deltaTime: Double
                if let lastSync = lastSyncTime {
                    deltaTime = Date().timeIntervalSince(lastSync)
                } else {
                    deltaTime = 0
                }

                await appVM.syncSession(
                    sessionId: sessionId,
                    currentTime: currentPosition,
                    timeListened: deltaTime,
                    duration: totalDuration
                )

                lastSyncTime = Date()
                lastSyncPosition = currentPosition
            }
        }
    }

    /// Close session with final sync first (matches official app behavior)
    private func closeCurrentSession() async {
        guard let sessionId = currentSessionId else { return }
        guard let appVM = appViewModel else { return }

        let currentPosition = currentTime

        // Use player duration, but fallback to item duration if player hasn't loaded yet
        var totalDuration = duration
        if totalDuration <= 0, let itemDuration = currentItem?.duration {
            totalDuration = itemDuration
        }

        // Calculate final delta
        let deltaTime: Double
        if let lastSync = lastSyncTime {
            deltaTime = Date().timeIntervalSince(lastSync)
        } else {
            deltaTime = 0
        }

        print("[GlobalAudioManager] 📤 Final sync before close: pos=\(currentPosition)s, delta=\(deltaTime)s")

        // Step 1: Do final sync with current state (matches official app)
        if totalDuration > 0 {
            await appVM.syncSession(
                sessionId: sessionId,
                currentTime: currentPosition,
                timeListened: deltaTime,
                duration: totalDuration
            )
        }

        print("[GlobalAudioManager] 📝 Closing session: \(sessionId)")

        // Step 2: Close the session
        await appVM.closeSession(sessionId: sessionId)

        currentSessionId = nil
        lastSyncTime = nil
        lastSyncPosition = 0
        print("[GlobalAudioManager] ✅ Session closed")

        // Diagnostic: Check if session was recorded
        #if DEBUG
        await appVM.fetchListeningSessions(limit: 5)
        #endif
    }

    // MARK: - Periodic Timers

    /// Start periodic timers: session sync (15s), progress PATCH (90s)
    private func startPeriodicTimers() {
        stopPeriodicTimers()

        // Session sync every 15s (matches official audiobookshelf-app)
        sessionSyncTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncSessionPeriodic()
            }
        }

        // Progress PATCH every 90s
        progressSyncTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveProgressAndSyncSession()
            }
        }

        print("[GlobalAudioManager] ⏲️ Periodic timers started: session=15s, progress=90s")
    }

    /// Stop all periodic timers
    private func stopPeriodicTimers() {
        sessionSyncTimer?.invalidate()
        sessionSyncTimer = nil

        progressSyncTimer?.invalidate()
        progressSyncTimer = nil

        print("[GlobalAudioManager] ⏲️ Periodic timers stopped")
    }
}
