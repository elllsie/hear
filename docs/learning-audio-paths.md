# 学习音频路径与 Supabase 存储说明

## 1. 用途

本文档说明英语、德语单词音频和中文释义音频从词书数据到本地文件、Supabase Storage、客户端缓存的完整路径。

当前 Supabase 项目：

```text
https://frljmdtogeyajpbwjavv.supabase.co
```

当前 Storage Bucket：

```text
learning-audio
```

Bucket 为公开读取，文件的基础 URL 为：

```text
https://frljmdtogeyajpbwjavv.supabase.co/storage/v1/object/public/learning-audio/
```

URL 中的 `storage/v1` 是 Supabase Storage API 版本，不是音频业务版本。

## 2. 词书数据来源

词书 JSON 位于：

```text
听会儿/data/
```

主要文件：

```text
听会儿/data/KaoYan_2.json
听会儿/data/IELTS_9400.json
听会儿/data/A1.json
听会儿/data/A2.json
听会儿/data/B1.json
听会儿/data/12yue.json
```

每个词条的关键字段：

```json
{
  "id": "1324",
  "text": "abandon",
  "meaningZh": "n. 放任；狂热；v. 遗弃；放弃"
}
```

`text` 和 `id` 用于生成单词音频文件名；`meaningZh` 用于生成中文释义音频键。

## 3. 本地音频目录

### 3.1 考研英语单词

```text
backend/generated/learning-audio/v2/words/en-US/KaoYan_2/
```

文件名规则：

```text
<安全化单词>_<词条ID>.mp3
```

例如：

```text
abandon_1324.mp3
```

### 3.2 雅思英语单词

```text
backend/generated/learning-audio/v2/words/en-US/IELTS_9400/
```

### 3.3 德语单词

```text
backend/generated/learning-audio/v2/words/de-DE/<词书>/
```

词书目录包括：

```text
12yue
A1
A2
B1
```

### 3.4 中文释义

```text
backend/generated/learning-audio/meanings/zh/
```

中文释义不按单词名命名，而是按“清洗后的释义文本 + FNV-1a 哈希”命名。

例如 `abandon` 的考研释义：

```text
原始：n. 放任；狂热；v. 遗弃；放弃
朗读：放任；狂热；遗弃；放弃
本地：放任_狂热_遗弃_放弃_0d2c4ddf.mp3
```

多个词条如果清洗后的中文释义相同，会共用同一个音频对象。

## 4. Supabase Storage 目录

### 4.1 考研英语

```text
learning-audio/v2/words/en-us/kaoyan_2/
```

例如：

```text
learning-audio/v2/words/en-us/kaoyan_2/abandon_1324.mp3
```

公开 URL：

```text
https://frljmdtogeyajpbwjavv.supabase.co/storage/v1/object/public/learning-audio/v2/words/en-us/kaoyan_2/abandon_1324.mp3
```

### 4.2 雅思英语

```text
learning-audio/v2/words/en-us/ielts_9400/
```

### 4.3 德语

```text
learning-audio/v2/words/de-de/<小写词书>/
```

### 4.4 中文释义

```text
learning-audio/meanings/zh/
```

中文文件名上传时会转为 ASCII 安全键。中文文本部分变为下划线并被压缩、裁剪，最终通常只保留哈希：

```text
本地：放任_狂热_遗弃_放弃_0d2c4ddf.mp3
云端：meanings/zh/0d2c4ddf.mp3
```

公开 URL：

```text
https://frljmdtogeyajpbwjavv.supabase.co/storage/v1/object/public/learning-audio/meanings/zh/0d2c4ddf.mp3
```

## 5. 本地路径到 Supabase 路径的转换

路径转换实现在：

```text
backend/scripts/learning_audio_key.py
```

主要规则：

1. 全部转小写。
2. `ä/ö/ü/ß` 转换为 `ae/oe/ue/ss`。
3. 不安全字符转换为下划线。
4. 连续下划线压缩为一个。
5. 删除文件名首尾的下划线和句点。

因此：

```text
本地：v2/words/en-US/KaoYan_2/abandon_1324.mp3
云端：v2/words/en-us/kaoyan_2/abandon_1324.mp3
```

## 6. 客户端从哪里取路径

### 6.1 Supabase 项目与音频版本

文件：

```text
听会儿/SupabaseConfig.swift
```

关键配置：

```swift
englishWordAudioVersion = "v2"
germanWordAudioVersion = "v2"
projectURL = "https://frljmdtogeyajpbwjavv.supabase.co"
learningAudioBucket = "learning-audio"
```

### 6.2 设置当前词书

文件：

```text
听会儿/ContentView.swift
```

播放前会设置：

```swift
AudioPlayerManager.shared.audioFolderName = book.bookId
```

考研英语的 `bookId` 为 `KaoYan_2`，雅思为 `IELTS_9400`。

### 6.3 生成单词文件名

文件：

```text
听会儿/AudioPlayerManager.swift
```

单词文件名：

```swift
"\(safeWord)_\(safeID).mp3"
```

中文释义文件名：

```swift
"\(safeMeaningPrefix)_\(fnvHash).mp3"
```

### 6.4 生成远程路径

`AudioPlayerManager.remotePath(...)` 负责生成对象路径。

考研和雅思：

```text
v2/words/en-us/<小写词书>/<文件名>
```

中文释义：

```text
meanings/zh/<哈希>.mp3
```

`AudioPlayerManager.remoteAudioURL(...)` 再把对象路径追加到 Bucket 公开 URL，并增加按小时轮换的 `audioVersion` 查询参数。

## 7. 播放和兜底顺序

客户端播放顺序：

1. 请求 Supabase 最新自然音频。
2. 校验 HTTP 状态、文件大小和音频可解码性。
3. 成功后写入 `TingHuiErAudioV4` 本地缓存。
4. 网络失败时播放已有有效缓存。
5. 没有有效缓存时使用 iOS 系统语音兜底。

同一对象每小时最多主动检查一次远程版本。CDN 穿透参数也按小时轮换，后端同路径覆盖后，App 不需发布新版本即可在下一刷新周期获取新音频。

## 8. 查询一个单词的所有音频路径

考研英语：

```bash
backend/.venv/bin/python backend/scripts/lookup_learning_audio.py \
  --book KaoYan_2 \
  --word abandon
```

雅思：

```bash
backend/.venv/bin/python backend/scripts/lookup_learning_audio.py \
  --book IELTS_9400 \
  --word ability
```

输出包括：

- 词条 ID。
- 原始中文释义。
- 实际朗读文本。
- 单词本地文件。
- 单词 Supabase 路径和 URL。
- 中文释义本地文件。
- 中文释义 Supabase 路径和 URL。

## 9. 生成、上传和校验脚本

### 生成音频

```text
backend/scripts/generate_word_audio_replacements.py
```

### 生成自然英语单词音频

```text
backend/scripts/generate_kokoro_word_audio.py
```

### 上传 Supabase

```text
backend/scripts/upload_learning_audio.py
```

重新生成音频后如需覆盖云端原对象，必须使用：

```text
--overwrite
```

### 校验 Supabase

```text
backend/scripts/verify_learning_audio.py
```

`--compare-content` 会绕过 CDN 缓存并比较云端与本地文件内容，比只做 HEAD 存在性检查更严格。

## 10. Supabase Dashboard 中查看

1. 登录 Supabase Dashboard。
2. 进入项目 `frljmdtogeyajpbwjavv`。
3. 打开 `Storage` → `Files`。
4. 打开 Bucket `learning-audio`。
5. 按上述目录进入单词或中文释义文件。

查看中文释义时，先用 `lookup_learning_audio.py` 查出哈希文件名，再到 `meanings/zh` 中搜索。

## 11. 后续维护约定

1. 只调整某个音频的声音时，优先原路径覆盖，不创建重复对象。
2. 原路径覆盖后必须用 `--compare-content` 复核。
3. 不要随意修改词条 `id`，否则单词音频文件名会变化。
4. 不要单独修改 Swift 或 Python 的安全文件名/哈希算法，两端必须保持一致。
5. 只覆盖同路径音频时无需重新发布 App。
6. 更换 Bucket、路径层级或业务版本目录时，需同步修改客户端并发布新版本。
