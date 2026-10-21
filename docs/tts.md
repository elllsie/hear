## 当前 App 使用的模型与音频链路汇总

| 内容 | 当前模型/声音 | 生成方式 | 播放失败兜底 |
|---|---|---|---|
| 英语单词 | Kokoro v1.0 / `af_heart` | 后端本地生成 MP3，上传 Supabase | iOS `AVSpeechSynthesizer` 英语声音 |
| 德语单词 | Kokoro German / `Victoria` | 后端本地生成 MP3，上传 Supabase | iOS `AVSpeechSynthesizer` 德语声音 |
| 中文释义 | Edge TTS / `zh-CN-XiaoxiaoNeural` | 后端联网生成 MP3，上传 Supabase | iOS 中文系统声音 |
| 英文释义 | Edge TTS / `en-US-AriaNeural` | 后端联网生成 MP3，上传 Supabase | iOS 英语系统声音 |
| 播客正文音频 | 播客发布方真人原音 | 从 RSS/发布方地址获取，部分可镜像到 Supabase | 不使用 AI 配音替换 |
| 播客转写 | `faster-whisper`，不可用时 `openai-whisper` | 后端本地转写 | 优先直接使用官方 VTT/SRT 字幕 |
| 播客翻译 | `deepseek-v4.1-flash` | OpenAI-compatible API | iOS 18 可使用 Apple Translation |
| 播客摘要、难词等 AI 分析 | `deepseek-v4.1-flash` | OpenAI-compatible API | 失败时不影响播客原音播放 |
| 播客页面点读单词 | iOS `AVSpeechSynthesizer` | 手机即时合成 | 本身就是系统声音 |

### 1. 英语单词

当前标准是：

```text
模型：Kokoro v1.0
声音：af_heart
语言：en-US
```

模型文件：

```text
backend/.local/kokoro-models/english/kokoro-v1_0.pth
```

声音文件：

```text
backend/.local/kokoro-models/english/voices/af_heart.pt
```

生成脚本：

```text
backend/scripts/generate_kokoro_word_audio.py
```

最近重新处理的 `abandon`、`storage` 等异常英语单词，仍然使用同一套 Kokoro + `af_heart`，只是针对结尾截断调整了生成速度和停顿，没有更换声音模型。

### 2. 德语单词

当前标准是：

```text
模型：Kokoro German
模型文件：kikiri_german_victoria_ep10.pth
声音：Victoria
语言：de-DE
```

对应文件：

```text
backend/.local/kokoro-models/german/kikiri_german_victoria_ep10.pth
backend/.local/kokoro-models/german/voices/victoria.pt
```

德语和英语单词都通过同一个 Kokoro 生成脚本处理。

### 3. 中文释义

当前标准是：

```text
服务：Microsoft Edge TTS
声音：zh-CN-XiaoxiaoNeural
```

适用于雅思、考研等单词的中文释义音频。当前中文释义播放速度规则为：

```text
用户设置速度 × 1.5
```

考研和雅思出现相同英文单词时，可以复用相同中文释义音频；不存在的释义再使用 `XiaoxiaoNeural` 单独生成。

### 4. 英文释义

当前生成配置为：

```text
服务：Microsoft Edge TTS
声音：en-US-AriaNeural
```

需要注意：这是现在以及后续补生成使用的标准。历史遗留的英文释义文件，可能包含早期 gTTS 或 Azure 版本。如果需要保证所有英文释义绝对统一，需要再做一次完整存量审计。

### 5. 系统声音兜底

远程自然音频的播放顺序是：

```text
内存/本地缓存
    ↓ 没有
Supabase 自然音频
    ↓ 下载或播放失败
iOS AVSpeechSynthesizer
```

系统声音选择顺序：

```text
Premium 高品质声音
    ↓ 没有
Enhanced 增强声音
    ↓ 没有
对应语言的默认系统声音
```

语言分别使用：

```text
英语：en-US
德语：de-DE
中文：zh-CN
```

具体是哪一个 Apple 声音，取决于用户手机系统版本以及是否下载了高品质语音包，因此系统兜底音在不同手机上可能略有不同。

### 6. 播客

播客长音频不是 AI 生成，而是：

```text
RSS/播客发布方真人原音
```

App 使用 `AVPlayer` 播放。Supabase 只负责保存或镜像文件，不负责生成播客声音。

播客字幕处理顺序：

```text
官方 VTT/SRT
    ↓ 没有字幕
faster-whisper
    ↓ 不可用
openai-whisper
```

默认 Whisper 模型：

```text
英语：tiny.en
德语/多语言：tiny
```

播客翻译、摘要和难词分析当前环境配置的 AI 模型是：

```text
deepseek-v4.1-flash
```

### 7. 仍保留但不是当前主方案的模型

以下能力还在代码或本地文件中，但不属于现在的主要生产方案：

- gTTS：早期单词/释义生成方案，当前不作为自然音频主方案。
- Azure Speech：脚本仍支持，默认包含 `JennyNeural`、`KatjaNeural`、`XiaoxiaoNeural`，但当前释义主要走 Edge TTS。
- Piper German：本地存在德语 Piper 模型，但当前德语 V2 单词使用 Kokoro Victoria。
- Apple 系统 TTS：主要作为异常兜底；但播客页面的单词点读目前仍直接使用它。

一句话概括当前正式标准：

```text
英语单词：Kokoro af_heart
德语单词：Kokoro Victoria
中文释义：Edge TTS XiaoxiaoNeural
英文释义：Edge TTS AriaNeural
播客音频：发布方真人原音
播客转写：Whisper
播客翻译与分析：deepseek-v4.1-flash
异常兜底：iOS AVSpeechSynthesizer
```