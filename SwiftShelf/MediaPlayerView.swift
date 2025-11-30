import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import Combine
import Foundation

// MARK: - Array Extension for Safe Subscripting
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Custom button style to prevent hover/focus bubble from overlapping neighbors
struct BubbledButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    var fill: Color = .accentColor
    var foreground: Color = .white
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(minWidth: 44, minHeight: 44, alignment: .center)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .compositingGroup()
            .clipped()
    }
}

// MARK: - NowPlayingBanner (small tweaks: externalized scrub geometry, added optional speed/sleep)
struct NowPlayingBanner: View {
    let scrubberFocus: FocusState<Bool>.Binding?

    let artwork: Image
    let title: String
    let chapterTitle: String?
    let duration: Double
    let currentTime: Double
    let isPlaying: Bool

    let onPlayPause: () -> Void
    let onRewind: () -> Void
    let onForward: () -> Void
    let onSeek: (Double) -> Void

    // optional controls
    var onPrevChapter: (() -> Void)? = nil
    var onNextChapter: (() -> Void)? = nil
    var rate: Float = 1.0
    var onToggleRate: (() -> Void)? = nil
    var sleepLabel: String? = nil
    var onSetSleep: (() -> Void)? = nil

    @FocusState private var localScrubberFocus: Bool

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    VStack(spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        if let chapter = chapterTitle, !chapter.isEmpty {
                            Text(chapter)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(formatDuration(currentTime))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(minWidth: 72, alignment: .leading)

                        // Timeline scrubber (focusable, left/right moves 10s)
                        Group {
                            GeometryReader { proxy in
                                let trackWidth = max(80, proxy.size.width)
                                let progress = CGFloat(min(max(currentTime / max(duration, 0.0001), 0), 1))
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill((scrubberFocus?.wrappedValue ?? localScrubberFocus) ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25))
                                        .frame(height: 8)
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: max(8, progress * trackWidth), height: 8)
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 20, height: 20)
                                        .offset(x: max(0, min(progress * trackWidth - 10, trackWidth - 10)))
                                }
                            }
                        }
                        .frame(height: 24)
                        .padding(.horizontal, 6)
                        .focusable(true)
                        .modifier(FocusBindingModifier(scrubberFocus: scrubberFocus, localScrubberFocus: $localScrubberFocus))
                        .onMoveCommand { move in
                            switch move {
                            case .left:
                                onSeek(max(currentTime - 10, 0))
                            case .right:
                                onSeek(min(currentTime + 10, duration))
                            default: break
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke((scrubberFocus?.wrappedValue ?? localScrubberFocus) ? Color.accentColor : Color.clear, lineWidth: 2)
                        )

                        Text(formatDuration(duration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)

                    HStack(spacing: 24) {
                        if let onPrevChapter {
                            Button(action: onPrevChapter) {
                                Image(systemName: "backward.end.fill")
                                    .font(.system(size: 18, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled(true)
                            .accessibilityLabel("Previous chapter")
                        }

                        Button(action: onRewind) {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled(true)
                        .accessibilityLabel("Rewind 15 seconds")

                        Button(action: onPlayPause) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled(true)
                        .accessibilityLabel(isPlaying ? "Pause" : "Play")

                        Button(action: onForward) {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled(true)
                        .accessibilityLabel("Forward 15 seconds")

                        if let onNextChapter {
                            Button(action: onNextChapter) {
                                Image(systemName: "forward.end.fill")
                                    .font(.system(size: 18, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled(true)
                            .accessibilityLabel("Next chapter")
                        }

                        if let onToggleRate {
                            Button(action: onToggleRate) {
                                Text(String(format: "%.1fx", rate))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled(true)
                            .accessibilityLabel("Playback speed \(rate)x")
                        }

                        if let onSetSleep {
                            Button(action: onSetSleep) {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 18, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled(true)
                            .accessibilityLabel("Set sleep timer")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: -4)
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(minHeight: 320, maxHeight: 500)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }
}

// Helper modifier for conditional focus binding
fileprivate struct FocusBindingModifier: ViewModifier {
    let scrubberFocus: FocusState<Bool>.Binding?
    let localScrubberFocus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if let scrubberFocus = scrubberFocus {
            content.focused(scrubberFocus)
        } else {
            content.focused(localScrubberFocus)
        }
    }
}

// MARK: - PlayerViewModel (owns AVPlayer so SwiftUI view can be lightweight)
final class PlayerViewModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0
    @Published var sleepRemaining: TimeInterval? = nil
    @Published var currentTrackIndex: Int = 0
    @Published var currentTrackTitle: String = ""
    @Published var hasAudioStream: Bool = true // New flag to indicate if audio stream is available
    @Published var loadingStatus: String = "Initializing..."
    
    @Published var currentChapterStart: Double = 0
    @Published var currentChapterDuration: Double = 0

    // Track the startOffset of the current track for absolute time calculation
    // This is the server-provided canonical absolute timestamp for multi-file audiobooks
    private var currentTrackStartOffset: Double = 0

    // Logging / observer tokens
    private var statusObservations: [NSKeyValueObservation] = []
    private var perItemNotificationTokens: [NSObjectProtocol] = []
    private var playerItemChangeObservation: NSKeyValueObservation?  // Added for currentItem changes

    let item: LibraryItem
    let appVM: ViewModel

    @Published var player: AVPlayer?
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var sleepTimer: Timer?
    var detailedItem: LibraryItem?
    var playlist: [LibraryItem.Track] = []
    var playlistItems: [AVPlayerItem] = []

    init(item: LibraryItem, appVM: ViewModel) {
        self.item = item
        self.appVM = appVM
    }

    func configureAndPlay() async {
        // This method is kept for backward compatibility but now just prepares without auto-playing
        await configureAndPrepare()
        // Only play if explicitly requested by calling play() separately
    }

    func configureAndPrepare() async {
        AppLogger.shared.log("PlayerVM", "configureAndPrepare for item: \(item.title)")
        print("[PlayerViewModel] 🚀 Starting configureAndPrepare for item: \(item.title)")
        
        await MainActor.run {
            self.setupSession()
            self.loadingStatus = "Fetching item details..."

            // Initialize playback rate from global preference
            let preferred = UserDefaults.standard.object(forKey: "preferredPlaybackRate") as? Double ?? 1.0
            self.rate = Float(preferred)
        }

        // First, try to fetch the detailed item to see what endpoints are actually available
        if let fullItem = await appVM.fetchLibraryItemDetails(itemId: item.id) {
            print("[PlayerViewModel] ✅ Successfully fetched detailed item with \(fullItem.tracks.count) tracks and \(fullItem.audioFiles.count) audio files")

            // Build tracks array - either use server-provided tracks or build from audioFiles
            var tracksToUse: [LibraryItem.Track] = []

            if !fullItem.tracks.isEmpty {
                print("[PlayerViewModel] 📚 Using server-provided tracks")
                tracksToUse = fullItem.tracks.sorted { $0.index < $1.index }
            } else if fullItem.audioFiles.count > 1 {
                // Server didn't provide tracks, but we have multiple audio files
                // Build tracks manually from audioFiles
                print("[PlayerViewModel] 🔨 Building tracks from \(fullItem.audioFiles.count) audio files")
                let sortedAudioFiles = fullItem.audioFiles.sorted { $0.index < $1.index }
                var cumulativeOffset: Double = 0

                for audioFile in sortedAudioFiles {
                    let trackDuration = audioFile.duration ?? 0

                    // Build contentUrl path for this audioFile (just the path, not full URL)
                    // The streamURL function will add the host and token
                    let contentUrl = "/api/items/\(fullItem.id)/file/\(audioFile.ino)"

                    let track = LibraryItem.Track(
                        index: audioFile.index,
                        startOffset: cumulativeOffset,
                        duration: trackDuration,
                        title: audioFile.filename ?? "Track \(audioFile.index + 1)",
                        contentUrl: contentUrl,
                        mimeType: audioFile.mimeType,
                        ino: audioFile.ino,
                        metadata: audioFile.metadata.map { audioMeta in
                            LibraryItem.Track.TrackMetadata(
                                filename: audioMeta.filename,
                                ext: audioMeta.ext,
                                path: audioMeta.path,
                                relPath: audioMeta.relPath,
                                size: audioMeta.size,
                                mtimeMs: audioMeta.mtimeMs.map { Double($0) },
                                ctimeMs: audioMeta.ctimeMs.map { Double($0) },
                                birthtimeMs: audioMeta.birthtimeMs.map { Double($0) }
                            )
                        },
                        addedAt: audioFile.addedAt,
                        updatedAt: audioFile.updatedAt,
                        trackNumFromMeta: audioFile.trackNumFromMeta,
                        discNumFromMeta: audioFile.discNumFromMeta,
                        trackNumFromFilename: audioFile.trackNumFromFilename,
                        discNumFromFilename: audioFile.discNumFromFilename,
                        manuallyVerified: audioFile.manuallyVerified,
                        exclude: audioFile.exclude,
                        error: audioFile.error,
                        format: audioFile.format,
                        bitRate: audioFile.bitRate,
                        language: audioFile.language,
                        codec: audioFile.codec,
                        timeBase: audioFile.timeBase,
                        channels: audioFile.channels,
                        channelLayout: audioFile.channelLayout,
                        chapters: nil,
                        embeddedCoverArt: nil,
                        metaTags: nil
                    )

                    tracksToUse.append(track)
                    print("[PlayerViewModel]    Track \(audioFile.index): \(track.title ?? "Untitled") - startOffset=\(cumulativeOffset)s, duration=\(trackDuration)s")

                    cumulativeOffset += trackDuration
                }

                print("[PlayerViewModel] 🔨 Built \(tracksToUse.count) tracks with total duration \(cumulativeOffset)s")
            }

            if !tracksToUse.isEmpty {
                print("[PlayerViewModel] 📚 TRACKS AVAILABLE - Using track-based approach with \(tracksToUse.count) tracks")
                await MainActor.run {
                    self.loadingStatus = "Found \(tracksToUse.count) tracks, building playlist..."
                }
                self.playlist = tracksToUse

                // Build all playlist items
                var playerItems: [AVPlayerItem] = []
                var totalDuration: Double = 0

                for track in playlist {
                    if let url = appVM.streamURL(for: track, in: fullItem) {
                        print("[PlayerViewModel] 🎵 Building track \(track.index): \(track.title ?? "Untitled")")
                        print("[PlayerViewModel]    URL: \(url)")
                        print("[PlayerViewModel]    Duration: \(track.duration ?? 0)s")
                        print("[PlayerViewModel]    StartOffset: \(track.startOffset ?? 0)s")

                        let asset = AVURLAsset(url: url)
                        let playerItem = AVPlayerItem(asset: asset)
                        setupPlayerItemErrorObserver(playerItem)
                        playerItems.append(playerItem)
                        totalDuration += track.duration ?? 0

                        print("[PlayerViewModel] ➕ Added track \(track.index) to playlist")
                    } else {
                        print("[PlayerViewModel] ❌ Failed to create URL for track \(track.index)")
                    }
                }

                print("[PlayerViewModel] 📊 Total tracks in playlist: \(playerItems.count)")
                print("[PlayerViewModel] 📊 Total duration: \(totalDuration)s")

                if !playerItems.isEmpty {
                    await MainActor.run {
                        self.loadingStatus = "Creating player with \(playerItems.count) items..."
                    }

                    let queuePlayer = AVQueuePlayer(items: playerItems)
                    queuePlayer.automaticallyWaitsToMinimizeStalling = true
                    queuePlayer.actionAtItemEnd = .advance  // Explicitly set to advance
                    self.player = queuePlayer
                    self.playlistItems = playerItems

                    print("[PlayerViewModel] 🎬 Created AVQueuePlayer with \(queuePlayer.items().count) items")
                    print("[PlayerViewModel] 🎬 actionAtItemEnd: \(queuePlayer.actionAtItemEnd.rawValue)")

                    // Add KVO for currentItem changes to update UI and re-apply rate
                    setupQueuePlayerObserver(queuePlayer)

                    await MainActor.run {
                        self.duration = totalDuration
                        self.currentTrackTitle = playlist.first?.title ?? "Track 1"
                        self.currentTrackStartOffset = playlist.first?.startOffset ?? 0
                        self.currentChapterStart = playlist.first?.startOffset ?? 0
                        self.currentChapterDuration = self.playlist.first?.duration ?? 0
                        self.hasAudioStream = true
                        self.loadingStatus = "Ready to play!"

                        print("[PlayerViewModel] 📍 Initial track startOffset: \(self.currentTrackStartOffset)s")
                    }

                    setupTimeObserver()
                    setupTrackEndObserver()
                    setupRemoteCommands()
                    updateNowPlaying()
                    
                    print("[PlayerViewModel] ✅ Queue player setup complete")
                    return
                }
            } else if let audioFile = fullItem.audioFiles.first {
                print("[PlayerViewModel] 🎵 No tracks found, using direct file endpoint")
                
                // Handle direct file endpoint
                guard var components = URLComponents(string: appVM.host) else {
                    print("[PlayerViewModel] ❌ Invalid host URL")
                    await MainActor.run { self.hasAudioStream = false }
                    return
                }
                components.path = "/api/items/\(item.id)/file/\(audioFile.ino)"
                let cleanToken = appVM.apiKey.hasPrefix("Bearer ") ? String(appVM.apiKey.dropFirst(7)) : appVM.apiKey
                components.queryItems = [URLQueryItem(name: "token", value: cleanToken)]
                
                if let directURL = components.url {
                    print("[PlayerViewModel] 🎯 Using direct endpoint: \(directURL)")
                    
                    let asset = AVURLAsset(url: directURL)
                    let playerItem = AVPlayerItem(asset: asset)
                    let player = AVPlayer(playerItem: playerItem)
                    player.automaticallyWaitsToMinimizeStalling = true
                    self.player = player
                    setupPlayerItemErrorObserver(playerItem)

                    setupTimeObserver()

                    await MainActor.run {
                        self.duration = audioFile.duration ?? 0
                        self.currentTrackTitle = item.title
                        self.currentChapterStart = 0
                        self.currentChapterDuration = audioFile.duration ?? 0
                        self.hasAudioStream = true
                        self.loadingStatus = "Ready to play!"
                    }
                    
                    setupRemoteCommands()
                    updateNowPlaying()
                    
                    print("[PlayerViewModel] ✅ Direct player setup complete")
                    return
                } else {
                    print("[PlayerViewModel] ❌ Failed to construct direct URL")
                }
            } else {
                print("[PlayerViewModel] ❌ No tracks or audio files found")
            }
        } else {
            print("[PlayerViewModel] ❌ Failed to fetch detailed item")
        }

        // If we reach here, nothing worked
        print("[PlayerViewModel] 💥 Configuration failed - no playable audio found")
        await MainActor.run {
            self.hasAudioStream = false
            self.loadingStatus = "No playable audio found"
        }
    }
    
    func setupTimeObserver() {
        AppLogger.shared.log("PlayerVM", "setupTimeObserver")
        print("[PlayerViewModel] ⏰ Setting up time observer")
        guard let player = player else {
            print("[PlayerViewModel] ❌ No player available for time observer")
            return
        }

        let interval = CMTime(value: 1, timescale: 2) // 0.5s
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] (t: CMTime) in
            guard let self else { return }

            // For multi-track audiobooks, use startOffset for absolute time
            let trackTime = CMTimeGetSeconds(t)
            if !self.playlist.isEmpty {
                // Use the current track's startOffset (server-provided canonical timestamp)
                // This is accurate even if the queue has been manipulated
                self.currentTime = self.currentTrackStartOffset + trackTime
            } else {
                // Single track - just use the time directly
                self.currentTime = trackTime
            }

            self.updateNowPlaying(elapsedOnly: true)
            self.persistProgressIfNeeded()
        }
    }


    func teardown() {
        AppLogger.shared.log("PlayerVM", "Teardown called")
        pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil

        // Remove per-item NotificationCenter tokens
        for token in perItemNotificationTokens { NotificationCenter.default.removeObserver(token) }
        perItemNotificationTokens.removeAll()

        // Invalidate KVO observations
        statusObservations.removeAll()
        playerItemChangeObservation = nil

        player = nil
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // NOTE: Do NOT remove remote command targets here
        // GlobalAudioManager owns the remote command handlers and they should persist
    }

    func setupTrackEndObserver() {
        AppLogger.shared.log("PlayerVM", "setupTrackEndObserver")
        print("[PlayerViewModel] 🔔 Setting up track end observer")

        // For AVQueuePlayer, observe when current item finishes
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let queue = self.player as? AVQueuePlayer else { return }

            // Check if the item that ended is actually from our queue
            guard let endedItem = notification.object as? AVPlayerItem,
                  self.playlistItems.contains(endedItem) else {
                print("[PlayerViewModel] ⚠️ Track ended but not in our playlist, ignoring")
                return
            }

            print("[PlayerViewModel] 🏁 Track ended, checking for next track")
            print("[PlayerViewModel] 🏁 Current queue has \(queue.items().count) items remaining")
            print("[PlayerViewModel] 🏁 Was playing: \(self.isPlaying)")

            // Save playback state
            let wasPlaying = self.isPlaying

            // Small delay to let AVQueuePlayer naturally advance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                print("[PlayerViewModel] 🔍 After delay - queue has \(queue.items().count) items")

                // Check if we have a next item
                if let currentItem = queue.currentItem,
                   let index = self.playlistItems.firstIndex(of: currentItem) {
                    print("[PlayerViewModel] ✅ Advanced to track \(index)")
                    print("[PlayerViewModel] ✅ Track title: \(self.playlist[safe: index]?.title ?? "Unknown")")

                    // Update track info using startOffset
                    self.currentTrackIndex = index
                    self.currentTrackTitle = self.playlist[safe: index]?.title ?? "Track \(index + 1)"

                    let track = self.playlist[safe: index]
                    self.currentTrackStartOffset = track?.startOffset ?? 0
                    self.currentChapterStart = track?.startOffset ?? 0
                    self.currentChapterDuration = track?.duration ?? 0

                    print("[PlayerViewModel] 📍 New track startOffset: \(self.currentTrackStartOffset)s")

                    // Maintain playback if we were playing
                    if wasPlaying {
                        print("[PlayerViewModel] ▶️ Resuming playback at rate \(self.rate)")
                        queue.play()
                        queue.rate = self.rate
                        self.isPlaying = true
                    } else {
                        print("[PlayerViewModel] ⏸️ Was paused, not resuming")
                    }
                } else {
                    // Reached end of queue
                    print("[PlayerViewModel] 🏁 Reached end of audiobook - currentItem is nil")
                    self.isPlaying = false
                }

                self.updateNowPlaying()
            }
        }
    }

    // Helper function to setup KVO observer for AVQueuePlayer currentItem changes
    func setupQueuePlayerObserver(_ queuePlayer: AVQueuePlayer) {
        print("[PlayerViewModel] 🔍 Setting up queue player observer")
        playerItemChangeObservation = queuePlayer.observe(\AVQueuePlayer.currentItem, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let currentItem = queuePlayer.currentItem,
                   let index = self.playlistItems.firstIndex(of: currentItem) {
                    self.currentTrackIndex = index
                    self.currentTrackTitle = self.playlist[safe: index]?.title ?? "Track \(index + 1)"

                    // Use startOffset from the track (server-provided canonical timestamp)
                    let track = self.playlist[safe: index]
                    self.currentTrackStartOffset = track?.startOffset ?? 0
                    self.currentChapterStart = track?.startOffset ?? 0
                    self.currentChapterDuration = track?.duration ?? 0

                    print("[PlayerViewModel] 📍 Track changed to index \(index), startOffset: \(self.currentTrackStartOffset)s")
                }
                if self.isPlaying {
                    queuePlayer.rate = self.rate
                }
                self.updateNowPlaying()
            }
        }
    }

    // MARK: Controls
    func play() {
        print("[PlayerViewModel] ▶️ play() called")
        print("[PlayerViewModel] ▶️ player is nil: \(player == nil)")
        if let player = player {
            print("[PlayerViewModel] ▶️ player.currentItem is nil: \(player.currentItem == nil)")
            print("[PlayerViewModel] ▶️ player.status: \(player.status.rawValue)")
            print("[PlayerViewModel] ▶️ player.timeControlStatus: \(player.timeControlStatus.rawValue)")
            if let currentItem = player.currentItem {
                print("[PlayerViewModel] ▶️ currentItem.status: \(currentItem.status.rawValue)")
            }
        }

        // Ensure we're receiving remote control events
        UIApplication.shared.beginReceivingRemoteControlEvents()

        player?.play()
        player?.rate = rate
        isPlaying = true
        print("[PlayerViewModel] ▶️ After play - timeControlStatus: \(player?.timeControlStatus.rawValue ?? -1)")
        updateNowPlaying()
    }

    func pause() {
        print("[PlayerViewModel] ⏸️ pause() called")
        // Use rate = 0 instead of pause() to maintain player association with Now Playing
        // This helps tvOS continue routing remote commands to our app
        player?.rate = 0
        isPlaying = false
        // Force a full update (not elapsedOnly) to ensure playback rate is set to 0
        updateNowPlaying(elapsedOnly: false)

        // Keep audio session active so remote commands continue to work
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("[PlayerViewModel] ⏸️ Audio session kept active for remote commands")
        } catch {
            print("[PlayerViewModel] ⏸️ Failed to keep audio session active: \(error)")
        }
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard let player = player else { return }

        print("[PlayerViewModel] 🎯 SEEK requested to \(seconds)s")
        print("[PlayerViewModel] 🎯 Current track index: \(currentTrackIndex), startOffset: \(currentTrackStartOffset)")

        // For multi-track audiobooks (AVQueuePlayer), we need to find the correct track
        if let queue = player as? AVQueuePlayer, !playlist.isEmpty {
            let clampedSeconds = max(0, min(seconds, duration))

            print("[PlayerViewModel] 🔍 Searching for track containing \(clampedSeconds)s")
            print("[PlayerViewModel] 🔍 Playlist has \(playlist.count) tracks:")
            for (i, t) in playlist.enumerated() {
                let start = t.startOffset ?? 0
                let dur = t.duration ?? 0
                print("[PlayerViewModel]    Track \(i): \(t.title ?? "Untitled") - start=\(start)s, duration=\(dur)s, end=\(start + dur)s")
            }

            // Find which track contains this absolute time using startOffset
            var targetTrackIndex: Int = 0
            var targetTrack: LibraryItem.Track? = nil
            var timeWithinTrack: Double = clampedSeconds

            for (index, track) in playlist.enumerated() {
                let trackStart = track.startOffset ?? 0
                let trackDuration = track.duration ?? 0
                let trackEnd = trackStart + trackDuration

                if clampedSeconds >= trackStart && clampedSeconds < trackEnd {
                    // Found the target track
                    targetTrackIndex = index
                    targetTrack = track
                    timeWithinTrack = clampedSeconds - trackStart
                    print("[PlayerViewModel] ✅ Found target: Track \(index) (\(track.title ?? "Untitled"))")
                    print("[PlayerViewModel] ✅ Time within track: \(timeWithinTrack)s")
                    break
                }
            }

            // Fallback to last track if beyond all tracks
            if targetTrack == nil && !playlist.isEmpty {
                print("[PlayerViewModel] ⚠️ No track found, using last track")
                targetTrackIndex = playlist.count - 1
                targetTrack = playlist[targetTrackIndex]
                let trackStart = targetTrack?.startOffset ?? 0
                timeWithinTrack = clampedSeconds - trackStart
            }

            guard let track = targetTrack else {
                print("[PlayerViewModel] ❌ Could not find target track for seek")
                return
            }

            // Check if we need to switch tracks
            if targetTrackIndex != currentTrackIndex {
                print("[PlayerViewModel] 🎯 Seek requires track switch: \(currentTrackIndex) -> \(targetTrackIndex)")
                print("[PlayerViewModel]    Seeking to absolute time: \(clampedSeconds)s")
                print("[PlayerViewModel]    Target track startOffset: \(track.startOffset ?? 0)s")
                print("[PlayerViewModel]    Time within track: \(timeWithinTrack)s")

                // Save old index BEFORE updating
                let oldTrackIndex = currentTrackIndex

                // Update track info (before seeking)
                currentTrackIndex = targetTrackIndex
                currentTrackStartOffset = track.startOffset ?? 0
                currentTrackTitle = track.title ?? "Track \(targetTrackIndex + 1)"
                currentChapterStart = track.startOffset ?? 0
                currentChapterDuration = track.duration ?? 0

                // Use AVQueuePlayer's advanceToNextItem to navigate to target track
                // This keeps the full queue intact instead of truncating it
                if targetTrackIndex > oldTrackIndex {
                    // Moving forward - advance to next item(s)
                    let itemsToSkip = targetTrackIndex - oldTrackIndex
                    print("[PlayerViewModel] ➡️ Advancing forward by \(itemsToSkip) track(s)")
                    for _ in 0..<itemsToSkip {
                        queue.advanceToNextItem()
                    }

                    // Seek to position within the target track
                    let targetTime = CMTime(seconds: timeWithinTrack, preferredTimescale: 600)
                    queue.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

                    updateNowPlaying()
                } else {
                    // Moving backward - need to recreate queue from target position
                    // This is unavoidable as AVQueuePlayer can't go backward
                    // But we keep ALL items from target onwards, not just target
                    print("[PlayerViewModel] ⬅️ Moving backward, recreating queue from track \(targetTrackIndex)")

                    guard targetTrackIndex < playlistItems.count else {
                        print("[PlayerViewModel] ❌ Target track index \(targetTrackIndex) out of bounds (playlist has \(playlistItems.count) items)")
                        return
                    }

                    let wasPlaying = isPlaying

                    let newItems = Array(playlistItems[targetTrackIndex...])
                    let newQueue = AVQueuePlayer(items: newItems)
                    newQueue.automaticallyWaitsToMinimizeStalling = true
                    newQueue.actionAtItemEnd = .advance
                    self.player = newQueue

                    // Reinstall observers for the new queue
                    setupTimeObserver()
                    setupTrackEndObserver()
                    setupRemoteCommands()
                    setupQueuePlayerObserver(newQueue)

                    // Seek to position within track
                    let targetTime = CMTime(seconds: timeWithinTrack, preferredTimescale: 600)
                    newQueue.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

                    // Restore playback state
                    if wasPlaying {
                        newQueue.play()
                        newQueue.rate = rate
                    }

                    updateNowPlaying()
                }
            } else {
                // Same track, just seek within it
                print("[PlayerViewModel] 🎯 Seeking within current track to \(timeWithinTrack)s")
                let targetTime = CMTime(seconds: timeWithinTrack, preferredTimescale: 600)
                queue.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                updateNowPlaying(elapsedOnly: true)
            }
        } else {
            // Single-track player: simple seek
            let clampedSeconds = max(0, min(seconds, duration))
            let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = clampedSeconds
            updateNowPlaying(elapsedOnly: true)
        }
    }

    func skip(_ by: Double) { seek(to: max(0, min(currentTime + by, duration))) }
    
    func skip(by seconds: Double) { 
        skip(seconds) 
    }
    
    func nextChapter() {
        // Advance to the next track if using a queue; otherwise, do nothing
        guard let player = player else { return }
        if let queue = player as? AVQueuePlayer {
            // Check if we can advance
            guard currentTrackIndex < playlist.count - 1 else {
                print("[PlayerViewModel] ⏭️ Already at last track")
                return
            }

            print("[PlayerViewModel] ⏭️ Advancing to next track: \(currentTrackIndex) -> \(currentTrackIndex + 1)")

            // Save playback state
            let wasPlaying = isPlaying

            // Use AVQueuePlayer's advanceToNextItem instead of recreating queue
            queue.advanceToNextItem()

            // Update track info
            let newIndex = currentTrackIndex + 1
            currentTrackIndex = newIndex
            let track = playlist[safe: newIndex]
            currentTrackStartOffset = track?.startOffset ?? 0
            currentTrackTitle = track?.title ?? "Track \(newIndex + 1)"
            currentChapterStart = track?.startOffset ?? 0
            currentChapterDuration = track?.duration ?? 0

            print("[PlayerViewModel] 📍 New track startOffset: \(currentTrackStartOffset)s")

            // Restore playback state
            if wasPlaying {
                queue.play()
                queue.rate = rate
                isPlaying = true
            } else {
                isPlaying = false
            }

            updateNowPlaying()
        } else {
            // Single-item player: just seek to end
            seek(to: duration)
            pause()
        }
    }

    func previousChapter() {
        // If far enough into the current track, just restart it; otherwise go to previous
        guard let player = player else { return }
        if player is AVQueuePlayer {
            // If more than 3 seconds into the current track, just restart it
            if currentTime - currentTrackStartOffset > 3 {
                print("[PlayerViewModel] ⏮️ Restarting current track")
                seek(to: currentTrackStartOffset)
                return
            }

            // Otherwise, go to previous track if available
            if currentTrackIndex > 0 {
                print("[PlayerViewModel] ⏮️ Going to previous track: \(currentTrackIndex) -> \(currentTrackIndex - 1)")

                let previousTrack = playlist[safe: currentTrackIndex - 1]
                if let trackStartOffset = previousTrack?.startOffset {
                    // Use seek() which now handles queue recreation properly
                    seek(to: trackStartOffset)
                }
            } else {
                // At the start of the queue — just restart current track
                print("[PlayerViewModel] ⏮️ Already at first track, restarting")
                seek(to: currentTrackStartOffset)
            }
        } else {
            // Single-item player: restart
            seek(to: 0)
        }
    }

    func toggleRate() {
        let options: [Float] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]
        if let idx = options.firstIndex(of: rate) { rate = options[(idx + 1) % options.count] } else { rate = 1.0 }
        player?.rate = isPlaying ? rate : 0
        UserDefaults.standard.set(Double(rate), forKey: "preferredPlaybackRate")
        updateNowPlaying()
    }

    func setRate(_ newRate: Float) {
        let clamped = max(1.0, min(newRate, 2.5))
        rate = clamped
        if isPlaying {
            player?.rate = clamped
        } else {
            player?.rate = 0
        }
        UserDefaults.standard.set(Double(rate), forKey: "preferredPlaybackRate")
        updateNowPlaying()
    }

    func setSleep(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        sleepRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return }
            self.sleepRemaining = max(0, (self.sleepRemaining ?? 0) - 1)
            if self.sleepRemaining == 0 { t.invalidate(); self.pause(); self.sleepRemaining = nil }
        }
    }

    func cancelSleepTimer() { sleepTimer?.invalidate(); sleepTimer = nil; sleepRemaining = nil }

    // MARK: Now Playing / Remote
    func setupSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.allowAirPlay, .allowBluetoothHFP])
            try session.setActive(true)
            // Ensure we receive remote control events
            UIApplication.shared.beginReceivingRemoteControlEvents()
            print("[PlayerViewModel] ✅ Audio session configured and receiving remote events")
        } catch {
            print("[AudioSession] error: \(error)")
        }
    }

    func setupRemoteCommands() {
        // NOTE: Remote commands are now handled by GlobalAudioManager
        // This method is kept for backward compatibility but does nothing
        // GlobalAudioManager.setupRemoteCommands() handles play/pause/toggle
        AppLogger.shared.log("PlayerVM", "setupRemoteCommands - delegating to GlobalAudioManager")
    }

    func updateNowPlaying(elapsedOnly: Bool = false) {
        AppLogger.shared.log("PlayerVM", "updateNowPlaying elapsedOnly=\(elapsedOnly) time=\(currentTime) playing=\(isPlaying) rate=\(rate)")
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if !elapsedOnly {
            info[MPMediaItemPropertyTitle] = item.title
            if let author = item.authorNameLF ?? item.authorName { info[MPMediaItemPropertyArtist] = author }
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // Always update playback rate and elapsed time to maintain Now Playing status
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        // Set default playback rate (what rate to use when play is pressed)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Explicitly set playback state to help tvOS route remote commands correctly
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func setupPlayerItemErrorObserver(_ playerItem: AVPlayerItem) {
        AppLogger.shared.log("PlayerVM", "Adding observers for item: \(String(describing: playerItem))")

        // KVO via NSKeyValueObservation
        let statusObs = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                AppLogger.shared.log("PlayerVM", "KVO status readyToPlay for item")
                if let asset = item.asset as? AVURLAsset {
                    AppLogger.shared.log("PlayerVM", "Asset URL: \(asset.url)")
                }
                DispatchQueue.main.async { self.hasAudioStream = true }
            case .failed:
                AppLogger.shared.log("PlayerVM", "KVO status FAILED for item: \(item.error?.localizedDescription ?? "unknown error")")
                if let asset = item.asset as? AVURLAsset {
                    AppLogger.shared.log("PlayerVM", "Failed asset URL: \(asset.url)")
                }
                DispatchQueue.main.async { self.hasAudioStream = false }
            case .unknown:
                AppLogger.shared.log("PlayerVM", "KVO status unknown for item")
            @unknown default:
                AppLogger.shared.log("PlayerVM", "KVO status unknown default: \(item.status.rawValue)")
            }
        }
        statusObservations.append(statusObs)

        // Notifications — store tokens
        let failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let errDesc = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "nil"
            AppLogger.shared.log("PlayerVM", "AVPlayerItemFailedToPlayToEndTime: \(errDesc)")
            self.hasAudioStream = false
        }
        perItemNotificationTokens.append(failToken)

        let errLogToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { notification in
            if let playerItem = notification.object as? AVPlayerItem,
               let errorLog = playerItem.errorLog() {
                AppLogger.shared.log("PlayerVM", "AVPlayerItemNewErrorLogEntry: \(errorLog)")
            }
        }
        perItemNotificationTokens.append(errLogToken)
    }

    private func testURLAccessibility(_ url: URL, trackTitle: String) async {
        print("[PlayerViewModel] Testing URL accessibility for: \(trackTitle)")

        // Log to file for easy debugging
        let logMessage = "Testing URL: \(url.absoluteString) for track: \(trackTitle)"
        await logToFile(logMessage)

        // Test with query parameter (current approach)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let statusMessage = "URL test result for \(trackTitle) (query param): Status \(httpResponse.statusCode)"
                print("[PlayerViewModel] \(statusMessage)")
                await logToFile(statusMessage)

                if httpResponse.statusCode == 200 {
                    let successMessage = "✅ URL is accessible with query param"
                    print("[PlayerViewModel] \(successMessage)")
                    await logToFile(successMessage)

                    if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                        let typeMessage = "Content-Type: \(contentType)"
                        print("[PlayerViewModel] \(typeMessage)")
                        await logToFile(typeMessage)
                    }
                    if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") {
                        let lengthMessage = "Content-Length: \(contentLength)"
                        print("[PlayerViewModel] \(lengthMessage)")
                        await logToFile(lengthMessage)
                    }
                    return
                } else {
                    let errorMessage = "❌ URL returned status \(httpResponse.statusCode) with query param"
                    print("[PlayerViewModel] \(errorMessage)")
                    await logToFile(errorMessage)
                }
            }
        } catch {
            let errorMessage = "❌ URL test failed for \(trackTitle) with query param: \(error.localizedDescription)"
            print("[PlayerViewModel] \(errorMessage)")
            await logToFile(errorMessage)
        }

        // If query param failed, try with Authorization header
        let urlWithoutToken = url.absoluteString.components(separatedBy: "?").first ?? url.absoluteString
        if let urlWithoutQuery = URL(string: urlWithoutToken) {
            var authRequest = URLRequest(url: urlWithoutQuery)
            authRequest.httpMethod = "HEAD"
            authRequest.timeoutInterval = 5
            authRequest.setValue("Bearer \(appVM.apiKey)", forHTTPHeaderField: "Authorization")

            do {
                let (_, response) = try await URLSession.shared.data(for: authRequest)
                if let httpResponse = response as? HTTPURLResponse {
                    let statusMessage = "URL test result for \(trackTitle) (auth header): Status \(httpResponse.statusCode)"
                    print("[PlayerViewModel] \(statusMessage)")
                    await logToFile(statusMessage)

                    if httpResponse.statusCode == 200 {
                        let successMessage = "✅ URL is accessible with Authorization header"
                        print("[PlayerViewModel] \(successMessage)")
                        await logToFile(successMessage)
                        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                            let typeMessage = "Content-Type: \(contentType)"
                            print("[PlayerViewModel] \(typeMessage)")
                            await logToFile(typeMessage)
                        }
                    } else {
                        let errorMessage = "❌ URL returned status \(httpResponse.statusCode) with auth header"
                        print("[PlayerViewModel] \(errorMessage)")
                        await logToFile(errorMessage)
                    }
                }
            } catch {
                let errorMessage = "❌ URL test failed for \(trackTitle) with auth header: \(error.localizedDescription)"
                print("[PlayerViewModel] \(errorMessage)")
                await logToFile(errorMessage)
            }
        }
    }


    private var lastPersist: TimeInterval = 0
    private func persistProgressIfNeeded() {
        // throttle to ~5s
        let now = Date().timeIntervalSince1970
        guard now - lastPersist > 5 else { return }
        lastPersist = now
        Task { await appVM.saveProgress(for: item, seconds: currentTime) }
    }

    // Log to file for debugging endpoint tests
    private func logToFile(_ message: String) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let logFileURL = documentsDirectory.appendingPathComponent("streaming_debug.log")

        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    // Expose player for embedding
    var avPlayer: AVPlayer? {
        return player
    }
}

// MARK: - MediaPlayerView (SwiftUI) - Uses Global Audio Manager
struct MediaPlayerView: View {
    let item: LibraryItem
    @EnvironmentObject var viewModel: ViewModel
    @EnvironmentObject var audioManager: GlobalAudioManager
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focusMiniPlayer: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !audioManager.hasAudioStream && audioManager.currentItem?.id == item.id {
                // Show error only if this item failed to load
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .foregroundColor(.red)

                    Text("Audio Stream Not Available")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Unable to load playable audio for this item. Please check your connection and try again.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button("Close") {
                        print("[MediaPlayerView] 🚪 Close button tapped")
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(24)
                .shadow(radius: 20)
                .padding(40)
            } else {
                // Popup overlay showing selected item's info. If this item is the active one, show full controls; otherwise offer Play to switch.
                VStack(spacing: 20) {
                    if let img = audioManager.coverArt?.0 {
                        img
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 380)
                            .cornerRadius(16)
                            .shadow(radius: 10)
                    } else {
                        Image(systemName: "music.note")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .foregroundColor(.gray)
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                    }

                    VStack(spacing: 4) {
                        Text(item.title)
                            .font(.title.bold())
                            .foregroundColor(.white)
                        if let author = item.authorNameLF ?? item.authorName {
                            Text(author)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }

                    if audioManager.currentItem?.id == item.id, audioManager.avPlayer != nil {
                        NowPlayingBanner(
                            scrubberFocus: $focusMiniPlayer,
                            artwork: (audioManager.coverArt?.0) ?? Image(systemName: "music.note"),
                            title: item.title,
                            chapterTitle: audioManager.currentTrackTitle,
                            duration: audioManager.duration,
                            currentTime: audioManager.currentTime,
                            isPlaying: audioManager.isPlaying,
                            onPlayPause: { audioManager.togglePlayPause() },
                            onRewind: { audioManager.skip(-15) },
                            onForward: { audioManager.skip(15) },
                            onSeek: { audioManager.seek(to: $0) },
                            onPrevChapter: { audioManager.previousChapter() },
                            onNextChapter: { audioManager.nextChapter() },
                            rate: audioManager.rate,
                            onToggleRate: { audioManager.toggleRate() },
                            sleepLabel: audioManager.sleepRemaining.map { secs in
                                let m = Int(secs) / 60; let s = Int(secs) % 60; return String(format: "%d:%02d", m, s)
                            },
                            onSetSleep: { audioManager.setSleep(minutes: 15) }
                        )
                        .padding(.bottom, 12)
                    } else {
                        VStack(spacing: 12) {
                            Text("This item is not currently active.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            HStack(spacing: 16) {
                                Button("Play") {
                                    Task {
                                        print("[MediaPlayerView] ▶️ Play selected item from overlay: \(item.title)")
                                        await audioManager.loadItem(item, appVM: viewModel)
                                        if let last = await viewModel.loadProgress(for: item) {
                                            print("[MediaPlayerView] ⏭️ Restoring progress to: \(last)s")
                                            audioManager.seek(to: last)
                                        }
                                        audioManager.togglePlayPause()
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Close") {
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
        .task {
            AppLogger.shared.log("PlayerUI", "initialLoad for item: \(item.title)")
            await initialLoad()
        }
        .onAppear {
            print("[MediaPlayerView] 👀 MediaPlayerView appeared for item: \(item.title)")
        }
        .onDisappear {
            print("[MediaPlayerView] 👋 MediaPlayerView disappeared")
        }
        .onMoveCommand { move in
            if move == .down {
                focusMiniPlayer = true
            }
        }
        .onPlayPauseCommand {
            print("[MediaPlayerView] 🎮 onPlayPauseCommand received")
            audioManager.togglePlayPause()
        }
    }

    private func initialLoad() async {
        print("[MediaPlayerView] 🚀 Initial load starting for item: \(item.title)")
        print("[MediaPlayerView] 🔍 Current item in audioManager: \(audioManager.currentItem?.title ?? "None")")
        
        // Only load if there's no current item; don't auto-switch from an existing mini player item
        if audioManager.currentItem == nil {
            print("[MediaPlayerView] 🆕 No current item — loading selected item into audioManager")
            await audioManager.loadItem(item, appVM: viewModel)

            // Restore last position from server
            if let last = await viewModel.loadProgress(for: item) {
                print("[MediaPlayerView] ⏭️ Restoring progress to: \(last)s")
                audioManager.seek(to: last)
            }
        } else if audioManager.currentItem?.id == item.id {
            print("[MediaPlayerView] ✅ Item already loaded in audioManager")
        } else {
            print("[MediaPlayerView] ⏸️ Different item is already in mini player — not auto-switching")
        }
        
        print("[MediaPlayerView] ✅ Initial load complete")
    }
}

// MARK: - Global Player View with Artwork
struct GlobalPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let artwork: UIImage?
    let item: LibraryItem

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        controller.view.backgroundColor = .black
        
        // Ensure proper view hierarchy setup
        controller.view.translatesAutoresizingMaskIntoConstraints = false

        print("[GlobalPlayerView] Creating player view controller")
        if artwork != nil {
            print("[GlobalPlayerView] ✅ Artwork available: \(artwork!.size)")
        } else {
            print("[GlobalPlayerView] ❌ No artwork")
        }

        // Defer metadata configuration to avoid early view hierarchy issues
        DispatchQueue.main.async {
            self.configureMetadata(for: controller)
        }
        
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Only update if actually different to avoid unnecessary updates
        if uiViewController.player !== player {
            uiViewController.player = player
            
            // Defer metadata configuration to avoid view hierarchy issues
            DispatchQueue.main.async {
                self.configureMetadata(for: uiViewController)
            }
        }
    }

    private func configureMetadata(for controller: AVPlayerViewController) {
        AppLogger.shared.log("PlayerUI", "configureMetadata for item: \(item.title)")
        // Create external metadata for tvOS
        var metadata: [AVMetadataItem] = []

        // Title
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = item.title as NSString
        titleItem.extendedLanguageTag = "und"
        metadata.append(titleItem)

        // Artist/Author
        if let author = item.authorNameLF ?? item.authorName {
            let artistItem = AVMutableMetadataItem()
            artistItem.identifier = .commonIdentifierArtist
            artistItem.value = author as NSString
            artistItem.extendedLanguageTag = "und"
            metadata.append(artistItem)
        }

        // Artwork - try JPEG first, then PNG
        if let artworkImage = artwork {
            let artworkItem = AVMutableMetadataItem()
            artworkItem.identifier = .commonIdentifierArtwork

            if let jpegData = artworkImage.jpegData(compressionQuality: 0.9) {
                artworkItem.value = jpegData as NSData
                artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
                metadata.append(artworkItem)
            } else if let pngData = artworkImage.pngData() {
                artworkItem.value = pngData as NSData
                artworkItem.dataType = kCMMetadataBaseDataType_PNG as String
                metadata.append(artworkItem)
            }
        }

        // Description
        if let series = item.seriesName {
            let descriptionItem = AVMutableMetadataItem()
            descriptionItem.identifier = .commonIdentifierDescription
            descriptionItem.value = series as NSString
            descriptionItem.extendedLanguageTag = "und"
            metadata.append(descriptionItem)
        }

        // Apply metadata to ALL player items in queue
        if let queuePlayer = player as? AVQueuePlayer {
            for item in queuePlayer.items() {
                item.externalMetadata = metadata
            }
        } else if let currentItem = player.currentItem {
            currentItem.externalMetadata = metadata
        }
    }
}

