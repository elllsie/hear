import SwiftUI
import AVFoundation
import Combine

class WordCardViewModel: ObservableObject {
    @Published var words: [Word] = []
    @Published var isLoading: Bool = true
    
    let dataSetName: String
    
    init(dataSetName: String) {
        self.dataSetName = dataSetName
        loadWords()
    }
    
    func loadWords() {
        print("📂 Loading \(dataSetName).json...")
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let book = try DataLoader.loadBook(named: self.dataSetName)
                print("✅ Loaded book with \(book.words.count) words")
                
                DispatchQueue.main.async {
                    self.words = book.words
                    self.isLoading = false
                    print("✅ ViewModel state updated: \(self.words.count) words")
                    if !self.words.isEmpty {
                        print("✅ First word: '\(self.words[0].word)'")
                    }
                }
            } catch {
                print("❌ Failed to load words: \(error)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
}

struct WordCardPlayerView: View {
    let dataSetName: String
    let audioFolder: String
    
    @StateObject private var viewModel: WordCardViewModel
    @State private var currentIndex: Int = 0
    @State private var isPlaying: Bool = false
    @State private var playbackDelegate: PlaybackDelegate?  // 持有 delegate 以防被释放
    @State private var autoAdvanceTask: DispatchWorkItem?  // 用于取消待处理的自动跳转任务
    
    init(dataSetName: String, audioFolder: String) {
        self.dataSetName = dataSetName
        self.audioFolder = audioFolder
        _viewModel = StateObject(wrappedValue: WordCardViewModel(dataSetName: dataSetName))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(dataSetName)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if viewModel.isLoading {
                    Text("加载中...")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else {
                    Text("\(currentIndex + 1)/\(viewModel.words.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            
            // Word Card
            if viewModel.isLoading {
                VStack {
                    ProgressView()
                    Text("加载中...")
                        .padding(.top, 12)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .cornerRadius(12)
                .padding()
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    
                    // 单词显示（包含冠词）
                    Text(viewModel.words[currentIndex].word)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    
                    // 音标
                    if let phonetic = viewModel.words[currentIndex].phonetic, !phonetic.isEmpty {
                        Text(phonetic)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(.blue)
                    }
                    
                    // 翻译
                    Text(viewModel.words[currentIndex].translation)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.black)
                    
                    // 例句（如果有）
                    if let example = viewModel.words[currentIndex].example, !example.isEmpty {
                        Text(example)
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                    
                    Spacer()
                    
                    // 播放/暂停/恢复按钮
                    HStack(spacing: 12) {
                        if isPlaying {
                            Button(action: pausePlayback) {
                                HStack {
                                    Image(systemName: "pause.fill")
                                    Text("暂停")
                                }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.orange)
                                .cornerRadius(8)
                            }
                            
                            Button(action: resumePlayback) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("继续")
                                }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.green)
                                .cornerRadius(8)
                            }
                        } else {
                            Button(action: playAudio) {
                                HStack {
                                    Image(systemName: "speaker.wave.2.fill")
                                    Text("播放")
                                }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.blue)
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding(24)
                .background(Color.white)
                .cornerRadius(12)
                .padding()
            }
            
            // Navigation Controls
            HStack(spacing: 12) {
                Button(action: previousWord) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("上一个")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.gray)
                    .cornerRadius(6)
                }
                .disabled(currentIndex == 0 || isPlaying)
                .opacity(currentIndex == 0 || isPlaying ? 0.5 : 1.0)
                
                Button(action: nextWord) {
                    HStack {
                        Text("下一个")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.blue)
                    .cornerRadius(6)
                }
                .disabled(currentIndex >= viewModel.words.count - 1 || isPlaying)
                .opacity(currentIndex >= viewModel.words.count - 1 || isPlaying ? 0.5 : 1.0)
            }
            .padding()
            
            Spacer()
        }
        .background(Color(.systemBackground))
        .onAppear {
            print("=== WordCardPlayerView Appeared ===")
            print("Data set: \(dataSetName), Audio folder: \(audioFolder)")
            print("ViewModel words count: \(viewModel.words.count)")
        }
        .onDisappear {
            // 清理：取消所有待处理任务
            autoAdvanceTask?.cancel()
            autoAdvanceTask = nil
            AudioPlayerManager.shared.stop()
        }
        .id(dataSetName)
        .navigationTitle(dataSetName)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func playAudio() {
        guard !viewModel.words.isEmpty && viewModel.words.indices.contains(currentIndex) else { return }
        
        let word = viewModel.words[currentIndex]
        print("\n🔊 Playing word \(currentIndex + 1)/\(viewModel.words.count): \(word.word)")
        
        // 先停止之前的播放，避免混合
        AudioPlayerManager.shared.stop()
        
        // 取消之前的自动跳转任务
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        
        // 创建新的自动跳转任务（但暂不执行）
        let task = DispatchWorkItem {
            print("✅ Auto-advancing to next word")
            if self.currentIndex < self.viewModel.words.count - 1 {
                self.currentIndex += 1
                self.playAudio()
            } else {
                print("✅ Reached end of list")
                self.isPlaying = false
            }
        }
        self.autoAdvanceTask = task
        
        // 使用 AudioPlayerManager 播放单词两遍加释义
        let newDelegate = PlaybackDelegate(
            onPlaybackCompleted: {
                print("✅ Playback completed for: \(word.word)")
                // 延迟1秒后执行自动跳转
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
            }
        )
        
        // 持有 delegate 以防被释放
        self.playbackDelegate = newDelegate
        AudioPlayerManager.shared.delegate = newDelegate
        AudioPlayerManager.shared.play(word: word)
        isPlaying = true
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
    
    private func nextWord() {
        // 取消待处理的自动跳转任务，避免重复跳转
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        AudioPlayerManager.shared.stop()
        isPlaying = false
        currentIndex = min(viewModel.words.count - 1, currentIndex + 1)
    }
    
    private func previousWord() {
        // 取消待处理的自动跳转任务
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        AudioPlayerManager.shared.stop()
        isPlaying = false
        currentIndex = max(0, currentIndex - 1)
    }
}

// Helper class to handle audio manager delegate
class PlaybackDelegate: AudioPlayerManagerDelegate {
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
        print("📢 State: \(isPlaying ? "Playing" : "Stopped")")
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
    NavigationView {
        WordCardPlayerView(dataSetName: "12yue", audioFolder: "12yue")
    }
}
