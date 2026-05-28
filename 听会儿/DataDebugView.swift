import SwiftUI

struct DataDebugView: View {
    @State private var debugInfo: String = "加载中..."
    
    var body: some View {
        VStack {
            Text("数据加载诊断")
                .font(.title2)
                .fontWeight(.bold)
                .padding()
            
            ScrollView {
                Text(debugInfo)
                    .font(.system(size: 12, design: .monospaced))
                    .padding()
                    .textSelection(.enabled)
            }
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding()
            
            Spacer()
        }
        .onAppear {
            testDataLoading()
        }
    }
    
    private func testDataLoading() {
        var info = "=== 数据加载测试 ===\n\n"
        
        // 测试加载 12yue
        do {
            info += "尝试加载 12yue.json...\n"
            let book = try DataLoader.loadBook(named: "12yue")
            info += "✓ 成功加载\n"
            info += "词书ID: \(book.bookId)\n"
            info += "标题: \(book.title)\n"
            info += "单词数: \(book.words.count)\n\n"
            
            if !book.words.isEmpty {
                info += "前5个单词:\n"
                for (i, word) in book.words.prefix(5).enumerated() {
                    info += "\(i+1). ID:\(word.id) Text:\(word.word)\n"
                    info += "   翻译: \(word.translation)\n"
                    info += "   音标: \(word.phonetic ?? "无")\n\n"
                }
            }
        } catch {
            info += "❌ 加载失败: \(error)\n"
        }
        
        // 测试加载 A1
        info += "\n=== 尝试加载 A1.json ===\n"
        do {
            let book = try DataLoader.loadBook(named: "A1")
            info += "✓ 成功加载 \(book.words.count) 个单词\n"
        } catch {
            info += "❌ 失败: \(error)\n"
        }
        
        // 检查 Bundle 中的文件
        info += "\n=== 检查 Bundle 中的 data/ 文件夹 ===\n"
        if let dataPath = Bundle.main.url(forResource: nil, withExtension: nil, subdirectory: "data") {
            info += "✓ 找到 data 文件夹: \(dataPath)\n"
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dataPath.path)
                info += "文件列表:\n"
                for file in files {
                    info += "  - \(file)\n"
                }
            } catch {
                info += "❌ 无法列出文件: \(error)\n"
            }
        } else {
            info += "❌ 找不到 data 文件夹\n"
        }
        
        debugInfo = info
    }
}

#Preview {
    DataDebugView()
}
