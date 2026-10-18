# 单词音频：gTTS + Supabase 工作流程

这份文档用于以后维护或新增英语、德语单词音频。当前方案是：扫描 App 中缺少音频的内容，用 gTTS 生成 MP3，上传到 Supabase Storage；App 优先播放缓存、本地或 Supabase 音频，均不可用时才临时使用 iOS 系统 TTS。

## 当前设计

- 音频服务：gTTS（默认），Azure 仅保留为可选项。
- 云端存储：Supabase Storage 的公开 Bucket `learning-audio`。
- 数据库：不需要新增业务表。
- 本地生成目录：`backend/generated/learning-audio`。
- App 缓存目录：`Library/Caches/TingHuiErAudio`，上限约 300 MB，由 App 自动清理旧文件。
- 文件路径由单词或释义稳定生成，因此无需在数据库中逐条保存音频 URL。上传时会把云端对象名转换为 ASCII：德语变音符号转换为 `ae/oe/ue/ss`，中文等其他字符折叠为下划线；Swift 远程查找使用完全相同的规则。本地 `Audio.bundle` 文件名保持不变。

加载优先级：

1. App 已下载的缓存音频
2. App 包内的 `Audio.bundle`
3. Supabase `learning-audio` 中同路径音频
4. iOS `AVSpeechSynthesizer` 临时系统朗读

## 首次配置

### 1. 安装 Python 依赖

```bash
backend/.venv/bin/pip install -r backend/requirements.txt
```

### 2. 配置 Supabase 环境变量

在 `backend/.env` 中确认存在：

```dotenv
SUPABASE_URL=https://你的项目.supabase.co
SUPABASE_SERVICE_ROLE_KEY=你的服务端密钥
```

`SUPABASE_SERVICE_ROLE_KEY` 只能保存在本地或可信服务端，不能写入 iOS App、提交到 Git，或暴露给用户。

### 3. 创建 Storage Bucket

在 Supabase SQL Editor 执行：

```text
supabase/sql/learning_audio_storage.sql
```

该 SQL 会创建或更新公开 Bucket `learning-audio`，并添加公开读取策略。上传脚本也会在 Bucket 不存在时尝试自动创建它。

> 当前音频是可公开读取的学习素材。以后若音频本身也必须仅限付费用户，应改为私有 Bucket，并通过后端签发短期 Signed URL；不要只依靠 App 页面隐藏。

## 标准更新流程

### 第一步：筛选仍会使用系统 TTS 的内容

```bash
backend/.venv/bin/python backend/scripts/audit_word_audio.py
```

输出：

- `backend/reports/audio/system_tts_fallbacks.json`：供生成脚本读取。
- `backend/reports/audio/system_tts_fallbacks.csv`：方便人工查看和筛选。

审计会检查当前词书数据与 `Audio.bundle`。即使对应音频已经在生成目录或 Supabase 中，审计结果仍可能列出它；后续生成命令会自动跳过本地已经生成的文件。

只检查指定词书：

```bash
backend/.venv/bin/python backend/scripts/audit_word_audio.py --books A1 A2 B1 KaoYan_2
```

当前语言规则：

- 德语单词：`de-DE`
- 考研英语单词：`en-US`
- 中文释义：`zh-CN`
- 英文释义：`en-US`

### 第二步：先小批量试听

建议每次变更生成规则后先生成少量样本：

```bash
backend/.venv/bin/python backend/scripts/generate_word_audio_replacements.py \
  --provider gtts \
  --limit 10 \
  --overwrite
```

检查语种、语速、释义清洗和音质无误后，再生成全部音频。

### 第三步：生成全部缺失音频

```bash
backend/.venv/bin/python backend/scripts/generate_word_audio_replacements.py \
  --provider gtts
```

默认行为：

- 已存在的目标文件会跳过，可安全续跑。
- 每个请求之间间隔 0.2 秒。
- 失败请求最多尝试 3 次。
- 输出写入 `backend/generated/learning-audio`。

网络不稳定或出现限流时，可降低速度后重新运行：

```bash
backend/.venv/bin/python backend/scripts/generate_word_audio_replacements.py \
  --provider gtts \
  --delay 1 \
  --retries 5
```

需要强制重新生成已有文件时才使用：

```bash
backend/.venv/bin/python backend/scripts/generate_word_audio_replacements.py \
  --provider gtts \
  --overwrite
```

### 第四步：上传到 Supabase

先预览待上传路径，不产生云端修改：

```bash
backend/.venv/bin/python backend/scripts/upload_learning_audio.py --dry-run
```

确认后上传：

```bash
backend/.venv/bin/python backend/scripts/upload_learning_audio.py
```

脚本采用“仅创建”模式，不会覆盖 Supabase 中已经存在的对象。同一路径再次上传会显示为 `skipped`；上传中断时可以直接重新执行，只补传缺失文件。

网络不稳定时减少并发：

```bash
backend/.venv/bin/python backend/scripts/upload_learning_audio.py --workers 2
```

只上传某个目录：

```bash
backend/.venv/bin/python backend/scripts/upload_learning_audio.py \
  --prefix words/KaoYan_2
```

### 第五步：验证云端音频

验证本次生成目录中的文件是否都能公开访问：

```bash
backend/.venv/bin/python backend/scripts/verify_learning_audio.py \
  --source backend/generated/learning-audio
```

缺失路径会写入：

```text
backend/reports/audio/supabase_missing.txt
```

如果结果不为零，重新上传即可。也可以同时使用相同的 `--prefix` 缩小检查范围。

## 后续新增单词或词书

1. 将单词数据加入对应 JSON 词书，并保证 `id` 唯一。
2. 确认审计脚本的 `DEFAULT_BOOKS` 包含新词书；或运行时通过 `--books` 指定。
3. 如果新词书不是德语，需要在 `audit_word_audio.py` 中为单词设置正确的语言代码和目标目录，不能继续套用默认 `de-DE`。
4. 重新执行“审计 → 小批试听 → 全量生成 → 上传 → 验证”。
5. 不需要修改 Supabase 表，也不需要把 MP3 加入 Xcode 工程。

## 后续替换或修正发音

如果只修正少量音频，优先从 CSV 找到对应 `target_path`：

1. 修正词书文本或生成规则。
2. 使用 `--overwrite` 重新生成。
3. 上传脚本会覆盖 Supabase 中的同路径文件。
4. App 端可能仍有旧缓存。测试时卸载 App、清除缓存，或等待缓存被淘汰。

如果改变了文件命名规则，旧云端文件不会自动删除，而且 App 必须同时使用新规则。此类调整应先核对 Swift 与 Python 的路径生成逻辑，再迁移文件。

## 常见问题

### gTTS 是真人录音吗？

不是。gTTS 仍然是合成语音，但比设备临时系统朗读更统一，也能提前生成和缓存。它不能像 Azure Neural TTS 那样自由选择发音人，批量调用也可能被限流。

### 是否需要新增 Supabase 表？

当前不需要。只有需要管理发音人、音频版本、审核状态、生成成本、更新时间，或多套声音时，才建议新增 `word_audio_assets` 元数据表。

### 为什么 App 仍然播放系统声音？

依次检查：

1. 审计 JSON 中是否存在该内容。
2. 生成目录中是否存在对应 `target_path`。
3. 上传时是否有失败记录。
4. 验证脚本是否报告该路径缺失。
5. Supabase Bucket 是否为公开读取。
6. Swift 和 Python 生成的文件名、大小写、语言目录是否完全一致。
7. App 是否缓存了旧结果；测试时可清理缓存或重装 App。

### 是否需要 Clean Build Folder 或卸载 App？

- 仅更新 Supabase 音频：通常都不需要。
- 修改 Swift 加载逻辑或资源引用异常：可先 Clean Build Folder。
- 需要清除旧音频缓存、登录状态或本地数据库：才考虑卸载重装。

## 相关文件

- `backend/scripts/audit_word_audio.py`：扫描系统 TTS 回退项。
- `backend/scripts/generate_word_audio_replacements.py`：使用 gTTS/Azure 生成音频。
- `backend/scripts/upload_learning_audio.py`：上传 Supabase Storage。
- `backend/scripts/verify_learning_audio.py`：检查云端文件是否可访问。
- `supabase/sql/learning_audio_storage.sql`：Bucket 与读取策略。
- `听会儿/AudioPlayerManager.swift`：App 音频查找、下载、缓存和系统 TTS 回退。
- `听会儿/SupabaseConfig.swift`：Supabase 音频 Bucket 配置。
