//
//  CompactPlayerView.swift
//  SwiftShelf
//
//  Created by michaeldvinci on 10/21/25.
//

import SwiftUI
import Combine

struct CompactPlayerView: View {
    @EnvironmentObject var audioManager: GlobalAudioManager
    @EnvironmentObject var viewModel: ViewModel
    @State private var localRate: Float = 1.0
    @State private var cancellable: AnyCancellable?
    
    @AppStorage("miniPlayerProgressScope") private var progressScopeRaw: String = "book"
    private enum ProgressScope: String { case book, chapter }
    private var progressScope: ProgressScope { ProgressScope(rawValue: progressScopeRaw) ?? .book }
    
    var body: some View {
        if let currentItem = audioManager.currentItem {
            VStack(spacing: 0) {
                // Top row: artwork + title/author + status on the left, but keep it compact
                HStack(spacing: 12) {
                    if let artwork = audioManager.coverArt?.0 {
                        artwork
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentItem.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let author = currentItem.authorNameLF ?? currentItem.authorName {
                            Text(author)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Text(audioManager.hasAudioStream ? (audioManager.isPlaying ? "Playing" : "Paused") : "Loading...")
                            .font(.caption2)
                            .foregroundColor(audioManager.hasAudioStream ? (audioManager.isPlaying ? .green : .secondary) : .orange)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Seek bar with timestamps on far left/right
                VStack(spacing: 6) {
                    HStack {
                        Text(formatTime(progressScope == .chapter ? max(0, audioManager.currentTime - audioManager.currentChapterStart) : audioManager.currentTime))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(progressScope == .chapter ? audioManager.currentChapterDuration : audioManager.duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)

                    Button(action: { progressScopeRaw = (progressScope == .book) ? ProgressScope.chapter.rawValue : ProgressScope.book.rawValue }) {
                        Text(progressScope == .book ? "Book" : "Chapter")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    GeometryReader { geometry in
                        // Compute timing values as constants to keep ViewBuilder returning a single View
                        let totalDuration: Double = {
                            if progressScope == .chapter && audioManager.currentChapterDuration > 0 {
                                return audioManager.currentChapterDuration
                            } else {
                                return audioManager.duration
                            }
                        }()

                        let elapsed: Double = {
                            if progressScope == .chapter && audioManager.currentChapterDuration > 0 {
                                return max(0, audioManager.currentTime - audioManager.currentChapterStart)
                            } else {
                                return audioManager.currentTime
                            }
                        }()

                        let progress: Double = totalDuration > 0 ? min(max(elapsed / totalDuration, 0), 1) : 0

                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(height: 6)

                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * CGFloat(progress), height: 6)
                        }
                    }
                    .frame(height: 6)
                }

                // Centered transport + speed controls
                HStack(spacing: 16) {
                    Spacer()

                    Button(action: { audioManager.previousChapter() }) {
                        Image(systemName: "backward.end.fill").font(.system(size: 18, weight: .bold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)

                    Button(action: { audioManager.skip(-15) }) {
                        Image(systemName: "gobackward.15").font(.system(size: 18, weight: .bold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)

                    Button(action: { audioManager.togglePlayPause() }) {
                        Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22, weight: .bold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)

                    Button(action: { audioManager.skip(15) }) {
                        Image(systemName: "goforward.15").font(.system(size: 18, weight: .bold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)

                    Button(action: { audioManager.nextChapter() }) {
                        Image(systemName: "forward.end.fill").font(.system(size: 18, weight: .bold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)

                    // Speed controls in center cluster
                    HStack(spacing: 8) {
                        Button(action: {
                            let newRate = max(1.0, audioManager.rate - 0.1)
                            audioManager.setRate(Float((Double(newRate) * 10).rounded() / 10))
                            localRate = audioManager.rate
                        }) { Image(systemName: "minus.circle") }
                        .frame(minWidth: 36, minHeight: 36)
                        .buttonStyle(.plain)

                        Text(String(format: "%.1fx", audioManager.rate))
                            .font(.caption).monospacedDigit()
                            .frame(minWidth: 44, alignment: .center)

                        Button(action: {
                            let newRate = min(2.5, audioManager.rate + 0.1)
                            audioManager.setRate(Float((Double(newRate) * 10).rounded() / 10))
                            localRate = audioManager.rate
                        }) { Image(systemName: "plus.circle") }
                        .frame(minWidth: 36, minHeight: 36)
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.sRGB, red: 0.08, green: 0.08, blue: 0.1, opacity: 1.0))
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: -2)
            .onAppear { localRate = audioManager.rate }
            .onPlayPauseCommand {
                print("[CompactPlayerView] 🎮 onPlayPauseCommand received")
                audioManager.togglePlayPause()
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

#Preview {
    CompactPlayerView()
        .environmentObject(GlobalAudioManager.shared)
}
