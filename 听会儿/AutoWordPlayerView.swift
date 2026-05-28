import SwiftUI
import AVFoundation

struct AutoWordPlayerView: View {
    @State private var words: [Word] = []
    @State private var currentIndex: Int = 0
    @State private var isPlaying: Bool = false
    @State private var playbackDelegate: AutoPlaybackDelegate?  // 持有 delegate 以防被释放
    @State private var slideOffset: CGFloat = 0
    @State private var opacity: Double = 1.0
    @State private var autoAdvanceTask: DispatchWorkItem?  // 用于取消待处理的自动跳转任务

    let interval: TimeInterval = 6.0
    let startDelay: TimeInterval = 1.0

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                
                ZStack {
                    RoundedRectangle(cornerRadius: 40)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 360, height: 640)
                        .overlay(
                            RoundedRectangle(cornerRadius: 40)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                    
                    VStack {
                        Spacer()
                        
                        if !words.isEmpty && words.indices.contains(currentIndex) {
                            let word = words[currentIndex]
                            VStack(spacing: 8) {
                                Text(word.word)
                                    .font(.system(size: 44, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                if let phonetic = word.phonetic, !phonetic.isEmpty {
                                    Text(phonetic)
                                        .font(.system(size: 18))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                                
                                Text(word.translation)
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.85))
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 20)
                            .offset(y: slideOffset)
                            .opacity(opacity)
                            .animation(.easeInOut(duration: 0.6), value: slideOffset)
                            .animation(.easeInOut(duration: 0.6), value: opacity)
                        } else {
                            Text("Loading...")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        Spacer()
                    }
                    .frame(width: 360, height: 640)
                }
                
                Spacer()
                
                // 播放控制按钮
                HStack(spacing: 20) {
                    if isPlaying {
                        Button(action: pausePlayback) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 20))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        
                        Button(action: resumePlayback) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    } else {
                        Button(action: startPlaying) {
                            Text("开始")
                                .font(.system(size: 18))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            loadWords()
        }
        .onDisappear {
            // 清理：取消所有待处理任务
            autoAdvanceTask?.cancel()
            autoAdvanceTask = nil
            AudioPlayerManager.shared.stop()
        }
    }
    
    private func loadWords() {
        do {
            let book = try DataLoader.loadBook(named: "A1")
            words = book.words
        } catch {
            print("Failed to load words: \(error)")
        }
    }
    
    private func startPlaying() {
        isPlaying = true
        currentIndex = 0
        showCurrentWord()
    }
    
    private func pausePlayback() {
        // 取消待处理的自动跳转任务
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        AudioPlayerManager.shared.pause()
        isPlaying = false
        print("⏸ Paused playback at index \(currentIndex)")
    }
    
    private func resumePlayback() {
        AudioPlayerManager.shared.resume()
        isPlaying = true
        print("▶️ Resumed playback at index \(currentIndex)")
    }
    
    private func showCurrentWord() {
        guard words.indices.contains(currentIndex) else { return }
        
        // 重置动画
        slideOffset = 0
        opacity = 1.0
        
        let word = words[currentIndex]
        print("\n🎵 Playing word \(currentIndex + 1)/\(words.count): \(word.word)")
        
        // 先停止之前的播放，避免混合
        AudioPlayerManager.shared.stop()
        
        // 取消之前的自动跳转任务
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        
        // 创建新的自动跳转任务（但暂不执行）
        let task = DispatchWorkItem {
            print("✅ Auto-advancing to next word")
            if self.currentIndex < self.words.count - 1 {
                self.nextWord()
            } else {
                print("✅ Reached end of list")
                self.isPlaying = false
            }
        }
        self.autoAdvanceTask = task
        
        // 设置 delegate 来处理播放完成事件
        let newDelegate = AutoPlaybackDelegate(
            onPlaybackCompleted: {
                print("✅ Playback completed for: \(word.word)")
                // 延迟2秒后执行自动跳转
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: task)
            }
        )
        
        // 持有 delegate 以防被释放
        self.playbackDelegate = newDelegate
        AudioPlayerManager.shared.delegate = newDelegate
        AudioPlayerManager.shared.play(word: word)
    }
    
    private func nextWord() {
        // 取消待处理的自动跳转任务，避免重复跳转
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        
        // Slide out
        slideOffset = -40
        opacity = 0.0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.currentIndex = min(self.currentIndex + 1, self.words.count - 1)
            self.showCurrentWord()
            
            // Slide in
            self.slideOffset = 40
            self.opacity = 0.0
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.slideOffset = 0
                self.opacity = 1.0
            }
        }
    }
}

// Helper class for auto playback delegate
class AutoPlaybackDelegate: AudioPlayerManagerDelegate {
    let onPlaybackCompleted: () -> Void
    private var hasCalledCompletion = false
    
    init(onPlaybackCompleted: @escaping () -> Void) {
        self.onPlaybackCompleted = onPlaybackCompleted
    }
    
    func audioPlayerManager(didStartPlaying itemDescription: String) {
        print("▶️ Started: \(itemDescription)")
    }
    
    func audioPlayerManager(didFinishPlaying itemDescription: String) {
        print("✓ Finished: \(itemDescription)")
    }
    
    func audioPlayerManager(didUpdateState isPlaying: Bool) {
        print("📢 Auto player state: \(isPlaying ? "Playing" : "Stopped")")
        // 只有当完全停止且水播放完成时，才调用一次回调
        if !isPlaying && !hasCalledCompletion {
            hasCalledCompletion = true
            onPlaybackCompleted()
        }
    }
    
    func audioPlayerManager(didEncounter error: Error) {
        print("❌ Error: \(error)")
        if !hasCalledCompletion {
            hasCalledCompletion = true
            onPlaybackCompleted()
        }
    }
}

#Preview {
    AutoWordPlayerView()
}