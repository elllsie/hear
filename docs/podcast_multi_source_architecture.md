# 英文 Podcast 多来源接入与字幕同步方案

## 1. 目标

为现有语言学习 App 增加英文 Podcast 功能，并解决两个核心问题：

1. 不同 Podcast 的音频获取方式不一致。
2. Podcast 音频与字幕/Transcript 时间轴不一致。

核心原则：**不要针对每个 Podcast 单独开发抓取逻辑，而是建立统一的内容接入层，把不同来源最终标准化成 App 能识别的一种数据格式。**

---

## 2. 总体架构

```text
各种 Podcast 来源
        ↓
┌─────────────────────────┐
│ Podcast 内容接入层       │
│ RSS / 官方 API / 授权源  │
└────────────┬────────────┘
             ↓
        标准 Episode
             ↓
┌─────────────────────────┐
│ 统一音频 / 字幕处理流程   │
└────────────┬────────────┘
             ↓
    audio_url + Sentence[]
             ↓
          Database
             ↓
            API
             ↓
        SwiftUI App
```

SwiftUI App 不需要知道 Overthink、BBC、Hidden Brain 分别是如何获取的，只处理标准化后的数据。

---

## 3. 音频获取策略

### 3.1 第一优先级：RSS `enclosure`

优先从 Podcast RSS Feed 的 `<enclosure>` 中获取音频地址。

```xml
<enclosure
    url="https://example.com/episode123.mp3"
    length="43829102"
    type="audio/mpeg"
/>
```

标准流程：

```text
RSS
 ↓
读取 enclosure
 ↓
获取 audio_url
 ↓
检测 URL 是否可访问/播放
 ↓
成功 → AVAILABLE
```

### 3.2 第二优先级：官方 API / 官方授权来源

如果 RSS 没有可用音频，再检查是否存在官方 API、官方 Feed 或其他明确授权的内容来源。

### 3.3 不建议 V1 做复杂网页爬取

如果一个 Podcast：

- 只有网页播放器
- 依赖复杂 JavaScript
- 需要登录或 Token
- 有明显反爬措施
- 无法通过标准 RSS / 官方接口获得

则 V1 直接标记为：

```text
UNSUPPORTED
```

不要为了一个节目写大量特殊代码。

### 3.4 音频状态建议

```text
AVAILABLE
UNAVAILABLE
REQUIRES_AUTH
UNSUPPORTED
```

---

## 4. 字幕获取策略

字幕采用分级 fallback，而不是所有 Podcast 都使用同一种方法。

### Level 1：官方带时间戳 Transcript

如果 RSS 或官方来源提供：

- WebVTT (`.vtt`)
- SRT (`.srt`)
- 其他带时间码格式

优先直接使用。

例如：

```text
00:12.300 --> 00:16.800
We tend to overthink our decisions.
```

优点：

- 成本低
- 不需要重新 STT
- 通常文字质量高
- 已经有时间轴

### Level 2：官方纯文本 + Forced Alignment（V2）

如果有官方 Transcript，但是没有时间戳：

```text
Podcast Audio
      +
Official Transcript
      ↓
Forced Alignment
      ↓
带时间戳的 Transcript
```

可以后续使用 WhisperX 等工具进行音频与文本强制对齐。

V1 暂时不做这一层。

### Level 3：STT 自动生成字幕

如果没有可用的 timed transcript：

```text
Podcast Audio
      ↓
Speech-to-Text
      ↓
英文 Transcript + Timestamp
      ↓
分句
      ↓
中文翻译
```

这是 V1 最重要的通用 fallback。

---

## 5. 音频字幕同步原则

### Audio 是唯一时间基准（Source of Truth）

不要假设网上找到的 Transcript 天然与音频同步。

可能出现偏移的原因包括：

- 开头广告不同
- Dynamic Ad Insertion（动态广告插入）
- Intro 不同
- 音频后期重新剪辑
- Transcript 删除口头语
- Transcript 是编辑稿而非逐字稿
- 不同地区/时间返回不同音频版本

因此最终字幕必须与**实际播放的 Audio Timeline** 对齐。

---

## 6. V1 推荐的字幕 Pipeline

第一版只保留两条路线：

```text
                  Episode
                     ↓
            有 timed transcript？
               /            \
             YES             NO
              ↓               ↓
          VTT / SRT          STT
              ↓               ↓
            Parse         Timestamp
               \             /
                \           /
                  Normalize
                     ↓
                 Sentence[]
```

暂时不要做：

- Word-level timestamp
- 复杂 Forced Alignment
- 针对单个 Podcast 定制字幕逻辑

---

## 7. 标准化（Normalization）

无论字幕来自 VTT、SRT、STT 或未来的 Forced Alignment，进入数据库以后全部转换成统一格式。

```json
{
  "episode_id": "123",
  "sentences": [
    {
      "start": 12.3,
      "end": 16.8,
      "english": "We tend to overthink our decisions.",
      "chinese": "我们往往会过度思考自己的决定。"
    },
    {
      "start": 16.8,
      "end": 21.2,
      "english": "But thinking isn't necessarily bad.",
      "chinese": "但思考本身并不一定是坏事。"
    }
  ]
}
```

SwiftUI App 永远只处理：

```text
audio_url
+
Sentence[]
```

App 不需要知道字幕究竟来自 STT 还是 VTT。

---

## 8. 音频数据也统一标准化

不同 Podcast 可能提供 MP3、M4A 等不同格式，但 Episode 在你的系统中统一表示为：

```json
{
  "id": 123,
  "title": "Why We Overthink",
  "audio": {
    "url": "https://example.com/audio.mp3",
    "mime_type": "audio/mpeg",
    "duration": 2850
  },
  "transcript_status": "ready"
}
```

播放由 iOS `AVPlayer` 负责。

---

## 9. Adapter（适配器）思想

可以把 Adapter 理解成“万能转换插头”。

### Audio Adapter

```text
RSS enclosure ──────┐
官方 API ───────────┤
其他授权来源 ───────┤
                    ↓
              Audio Adapter
                    ↓
                audio_url
```

### Transcript Adapter

```text
VTT ────────────────┐
SRT ────────────────┤
STT ────────────────┤
Forced Alignment ───┤
                    ↓
            Transcript Adapter
                    ↓
                Sentence[]
```

因此以后增加 Podcast 的目标应该是：

> 添加一个内容源，而不是修改一次 App。

---

## 10. Capability Detection（能力检测）

新增 Podcast 时，后台先自动检测它支持什么能力。

例如 Overthink：

```text
✓ RSS available
✓ Audio available
✕ Timed transcript
✓ Audio format supported
✓ Cover available

Audio Source: RSS
Transcript: STT_REQUIRED
```

另一个 Podcast 可能是：

```text
✓ RSS available
✓ Audio available
✓ Timed transcript (VTT)

Audio Source: RSS
Transcript: VTT
Processing: NOT_REQUIRED
```

如果：

```text
✕ Audio unavailable
```

则：

```text
Audio: UNSUPPORTED
```

暂时不进入 App 内容库。

---

## 11. 完整 Pipeline

```text
                     Podcast RSS
                          ↓
                    Feed Parser
                          ↓
                       Episode
                          ↓
                 ┌────────────────┐
                 │ Capability检测 │
                 └───────┬────────┘
                         ↓
                ┌────────────────┐
                │ AUDIO PIPELINE │
                └───────┬────────┘
                        ↓
              RSS enclosure
                    OR
              官方授权来源
                        ↓
                   audio_url
                        │
                ┌───────┴────────┐
                │                │
                ↓                ↓
       Timed Transcript?         NO
                │                │
               YES               ↓
                │               STT
           VTT / SRT             │
                │                │
                └───────┬────────┘
                        ↓
                    Normalize
                        ↓
              ┌──────────────────┐
              │ Sentence[]       │
              │ start            │
              │ end              │
              │ english          │
              │ chinese          │
              └────────┬─────────┘
                       ↓
                    Database
                       ↓
                      API
                       ↓
                 SwiftUI App
                       ↓
             AVPlayer + 同步字幕
```

---

## 12. SwiftUI 字幕同步

App 播放音频时持续获取：

```text
currentTime
```

例如：

```text
currentTime = 14.2s
```

寻找：

```text
start <= 14.2 < end
```

如果匹配：

```text
start = 12.3
end = 16.8
```

则高亮：

```text
We tend to overthink our decisions.
我们往往会过度思考自己的决定。
```

因此 SwiftUI 不需要理解复杂的 STT 或字幕来源，只负责：

```text
AVPlayer currentTime
        +
Sentence[]
        ↓
当前字幕
```

---

## 13. V1 技术原则

### 原则 1：不针对单个 Podcast 写特殊爬虫

标准 RSS / 官方授权来源支持不了的，V1 暂不支持。

### 原则 2：RSS `enclosure` 是主要音频入口

优先采用 Podcast 生态标准方式获取 Episode 音频 URL。

### 原则 3：字幕采用两级 fallback

```text
VTT / SRT
   ↓ 不存在
STT
```

### 原则 4：Audio 是唯一时间基准

所有字幕最终都必须对应实际播放的音频时间轴。

### 原则 5：统一输出格式

所有内容最终统一为：

```text
audio_url + Sentence[]
```

SwiftUI 只处理这一种数据结构。

### 原则 6：Forced Alignment 放到 V2

只有真正遇到“官方 Transcript 很准确但没有时间戳”的 Podcast，再加入 Forced Alignment。

---

## 14. V1 与 V2 边界

### V1

```text
RSS
↓
Episode
↓
Audio URL
↓
VTT/SRT（有则使用）
↓ 无
STT
↓
Sentence Timestamp
↓
中文翻译
↓
Database
↓
SwiftUI
```

目标：**先稳定支持一批标准 Podcast。**

### V2

增加：

- Official Transcript + Forced Alignment
- 更准确的 Word-level timestamp
- Dynamic Ad Insertion 处理
- 更多 Audio Adapter
- 自动内容质量检测
- 更完善的版权/授权控制

---

## 15. 最终核心思想

不要再思考：

> “Overthink 怎么抓？”
>
> “BBC 怎么抓？”
>
> “Hidden Brain 怎么抓？”

而是建立一套标准：

> **这个 Podcast 是否符合我的接入协议？**

流程统一为：

```text
添加 Podcast
      ↓
能力检测
      ↓
RSS 音频可用？
      ↓
字幕可用？
   ↙      ↘
 VTT/SRT   STT
   ↘      ↙
   Normalize
      ↓
audio_url + Sentence[]
      ↓
     App
```

符合标准 → 自动接入。

标准字幕不存在 → STT fallback。

标准音频也无法获得 → 暂不支持。

**通过 Adapter + Capability Detection + Normalization，把不同 Podcast 的差异留在后台，让 App 永远面对统一的数据格式。**
