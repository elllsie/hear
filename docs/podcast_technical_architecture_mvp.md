# 听会儿 Podcast 技术架构与分阶段实施方案（MVP）

> 日期：2026-10-03  
> 适用项目：现有 SwiftUI + Supabase「听会儿」App  
> 核心闭环：听 → 遇 → 收 → 听  
> 原则：单体、少依赖、人工精选、按需加工、每阶段可独立验证。

## 0. 当前项目与目标差距

当前项目已有：

- Supabase Auth；
- `learning_progress` 与 `favorite_words`；
- SwiftUI 单词播放；
- Podcast 原型 UI、AVPlayer、RSS 客户端解析与本地语境收藏。

当前 Podcast 原型仍有两个临时实现：

1. iOS 直接抓取 10 个 RSS；
2. Podcast 语境词保存在 `UserDefaults`，没有进入现有云端英语单词库。

目标是逐步替换为：Python 负责内容获取和加工，Supabase 负责数据库与 REST，iOS 只负责展示、播放和用户交互。

---

# 1. 系统架构图

```text
                         管理员（独立开发者）
                                  │
                         手动执行 CLI / 精选单集
                                  │
              ┌───────────────────┴──────────────────┐
              │                                      │
      Podcast Collector                      Podcast Processor
      Python + feedparser                   Python + STT + 翻译
              │                                      │
公开 RSS ─────┤                                      │
              │                                      │
              └──────────────┬───────────────────────┘
                             │ service role
                             ▼
                 ┌────────────────────────┐
                 │       Supabase         │
                 │ Postgres + Auth + RLS  │
                 │                        │
                 │ podcasts               │
                 │ episodes               │
                 │ sentences              │
                 │ words                  │
                 │ favorite_words         │
                 │ favorite_word_sources  │
                 │ episode_progress       │
                 └───────────┬────────────┘
                             │ REST / HTTPS
                             ▼
                 ┌────────────────────────┐
                 │      SwiftUI App       │
                 │ Repository + AVPlayer  │
                 │ 字幕同步 + 点词 + 收藏   │
                 └────────────────────────┘
```

MVP 不增加独立 Web Server。Supabase PostgREST 就是 REST API；Python 脚本仅在开发者电脑或简单定时环境中运行。未来确实需要隐藏复杂业务逻辑时，再增加单个 FastAPI 服务或 Supabase Edge Function。

---

# 2. 完整数据流

## 2.1 内容获取

```text
人工维护 rss_sources.json
→ sync_podcasts.py
→ feedparser 读取 RSS
→ 规范化 Podcast 元数据
→ 按 podcast.rss_url upsert podcasts
→ 按 (podcast_id, guid) upsert episodes
→ 新 Episode transcript_status = none
→ 完成同步报告：新增 / 已存在 / 失败
```

RSS 同步只保存 metadata，不下载 MP3，不自动调用 AI。

## 2.2 内容加工

```text
管理员将某 Episode 标记 selected
→ process_episode.py --episode-id <uuid>
→ transcript_status: none → processing
→ 下载临时音频到系统临时目录
→ STT 生成 sentence/segment 时间戳
→ 英文断句清洗
→ 批量翻译中文
→ 人工抽检
→ transaction 写入 sentences
→ transcript_status = ready
→ 删除临时音频
```

失败时写 `transcript_status = failed` 与内部错误信息；App 不展示内部错误，只显示“字幕准备中/暂不可用”。

## 2.3 App 播放与学习

```text
GET podcasts / episodes
→ 用户进入单集
→ GET episode + sentences
→ AVPlayer 播放 episode.audio_url
→ currentTime 匹配 Sentence
→ 高亮当前英文和中文句
→ 用户点击英文词
→ 本地/服务端词典查询
→ Bottom Sheet
→ POST favorite_words + favorite_word_sources
→ 我的单词
→ 播放单词 / 原句
→ AVPlayer seek(sentence.start_time)
```

---

# 3. 数据库表结构

## 3.1 `podcasts`

| 字段 | 类型 | 约束/用途 |
|---|---|---|
| id | uuid | PK，默认 `gen_random_uuid()` |
| name | text | 非空 |
| description | text | 节目简介 |
| rss_url | text | 非空、唯一 |
| website_url | text | 官方页面 |
| cover_url | text | 远端封面 |
| language | text | MVP 固定 `en` |
| category | text | `easy/thinking/world/future` |
| host | text | 主持人 |
| region | text | 国家/地区 |
| level | text | A2/B1/B2/C1 |
| rights_status | text | `unknown/reviewed/approved/rejected` |
| is_active | boolean | 是否继续抓取 |
| created_at | timestamptz | 创建时间 |
| updated_at | timestamptz | 更新时间 |

MVP 约束：`unique(rss_url)`。

## 3.2 `episodes`

| 字段 | 类型 | 约束/用途 |
|---|---|---|
| id | uuid | PK |
| podcast_id | uuid | FK → podcasts |
| guid | text | RSS 稳定标识 |
| title | text | 非空 |
| description | text | RSS 简介 |
| audio_url | text | AVPlayer 原始音频 URL |
| source_url | text | 官方单集页面 |
| cover_url | text | 单集封面，可空 |
| duration_seconds | integer | 可空 |
| publish_date | timestamptz | 发布时间 |
| transcript_status | text | `none/processing/ready/failed` |
| editorial_status | text | `imported/selected/published/archived` |
| processing_error | text | 仅后台读取 |
| audio_fingerprint | text | V2 用，MVP 可空 |
| created_at | timestamptz | 创建时间 |
| updated_at | timestamptz | 更新时间 |

核心唯一约束：`unique(podcast_id, guid)`。若 RSS 没有 guid，Collector 使用规范化后的 `audio_url` 哈希作为 fallback guid。

## 3.3 `sentences`

| 字段 | 类型 | 约束/用途 |
|---|---|---|
| id | uuid | PK |
| episode_id | uuid | FK → episodes，cascade delete |
| sequence | integer | 从 0 开始 |
| start_time | numeric(10,3) | 秒 |
| end_time | numeric(10,3) | 秒 |
| english | text | 审核后的英文句 |
| chinese | text | 中文翻译，可空 |
| created_at | timestamptz | 创建时间 |

约束：

- `unique(episode_id, sequence)`；
- `start_time >= 0`；
- `end_time > start_time`；
- 索引 `(episode_id, start_time)`。

## 3.4 `words`

现有 `Word` 主要来自本地 JSON。为了 Podcast 点词，建议建立轻量云端规范词典：

| 字段 | 类型 | 用途 |
|---|---|---|
| id | uuid | PK |
| language | text | `en/de` |
| lemma | text | 规范词元 |
| display_text | text | 展示形式 |
| phonetic | text | IPA，可空 |
| meaning_zh | text | 中文义 |
| meaning_en | text | 英文义，可空 |
| audio_url | text | 单词发音，可空 |

唯一约束：`unique(language, lemma)`。

## 3.5 `favorite_words` 的兼容升级

当前表为：`user_id + book_id + word_id`。不要直接破坏旧版本，第一阶段增加可空字段：

| 新字段 | 类型 | 用途 |
|---|---|---|
| dictionary_word_id | uuid | FK → words，可空 |
| source_type | text | `wordbook/podcast`，默认 `wordbook` |
| first_seen_at | timestamptz | 首次收藏 |
| updated_at | timestamptz | 同步冲突依据 |

旧词书收藏继续使用 `book_id + word_id`；Podcast 收藏使用 `dictionary_word_id`。数据库用两个 partial unique index 分别防重复，避免把两种 ID 强行塞进同一个字段语义。

## 3.6 `favorite_word_sources`

该表保存“这个词在哪里遇到”，不是第二套生词本。

| 字段 | 类型 | 用途 |
|---|---|---|
| id | uuid | PK |
| favorite_word_id | uuid | FK → favorite_words |
| episode_id | uuid | FK → episodes |
| sentence_id | uuid | FK → sentences |
| surface_form | text | 用户实际点击的词形 |
| created_at | timestamptz | 收藏时间 |

唯一约束：`unique(favorite_word_id, sentence_id)`。同一规范词可保留多个 Podcast 语境。

## 3.7 `episode_progress`

| 字段 | 类型 | 用途 |
|---|---|---|
| user_id | uuid | 联合 PK，FK → auth.users |
| episode_id | uuid | 联合 PK |
| position_seconds | numeric(10,3) | 最后播放位置 |
| is_completed | boolean | 播放达到 90% |
| updated_at | timestamptz | 更新时间 |

## 3.8 RLS

- `podcasts/episodes/sentences/words`：匿名与登录用户只读 `published/ready` 内容；写入只允许 service role。
- `favorite_words/favorite_word_sources/episode_progress`：仅允许 `auth.uid() = user_id` 的数据。
- `processing_error` 不通过公开 API 返回。

---

# 4. REST API 设计

MVP 直接使用 Supabase REST，不额外维护 FastAPI。

## 4.1 内容 API

### `GET /podcasts`

内部映射：

```http
GET /rest/v1/podcasts
  ?is_active=eq.true
  &rights_status=eq.approved
  &select=id,name,description,cover_url,category,host,region,level
  &order=name.asc
```

### `GET /podcasts/{id}/episodes`

```http
GET /rest/v1/episodes
  ?podcast_id=eq.{id}
  &editorial_status=eq.published
  &select=id,title,description,audio_url,cover_url,duration_seconds,publish_date,transcript_status
  &order=publish_date.desc
```

### `GET /episodes/{id}`

返回单集和必要的 Podcast 信息。不要默认把全部字幕嵌在响应里。

### `GET /episodes/{id}/sentences`

```http
GET /rest/v1/sentences
  ?episode_id=eq.{id}
  &select=id,sequence,start_time,end_time,english,chinese
  &order=sequence.asc
```

客户端 DTO 可映射成：

```json
{
  "id": "...",
  "sequence": 12,
  "start": 12.3,
  "end": 16.8,
  "en": "We tend to overthink our decisions.",
  "zh": "我们往往会过度思考自己的决定。"
}
```

## 4.2 用户 API

### 收藏单词

客户端执行一次业务动作，Repository 内分两步：

1. upsert `favorite_words`；
2. upsert `favorite_word_sources`。

若希望强原子性，后续增加一个 Supabase Database Function `save_podcast_word(...)`；MVP 可以先用两次 REST 请求和幂等唯一约束。

### `GET /words`

读取当前用户的 `favorite_words`，并展开 `dictionary_word_id` 与最新 `favorite_word_sources`。词书来源和 Podcast 来源在同一页面展示，UI 用来源标签区分，不分成两套数据。

### 播放进度

`POST /rest/v1/episode_progress`，使用 `Prefer: resolution=merge-duplicates` upsert。每 10–15 秒节流一次，退出播放器时立即保存。

---

# 5. Python Podcast Collector

## 5.1 文件边界

```text
backend/
├─ requirements.txt
├─ .env.example
├─ config/
│  └─ rss_sources.json
├─ podcast_collector/
│  ├─ models.py
│  ├─ parser.py
│  ├─ repository.py
│  └─ service.py
└─ scripts/
   └─ sync_podcasts.py
```

第一阶段甚至可以压缩成一个 `sync_podcasts.py`，但函数仍分成：`load_sources`、`fetch_feed`、`normalize_episode`、`upsert_podcast`、`upsert_episode`，方便测试。

## 5.2 依赖

- `feedparser`：解析 RSS/Atom；
- `httpx`：带 timeout 的 HTTP；
- `supabase` 或直接 `httpx` 调 Supabase REST；
- `python-dotenv`：仅本地加载环境变量。

不要把 Supabase service role key 写入仓库或 iOS App。

## 5.3 去重算法

```text
guid 存在且非空 → guid
否则 enclosure/audio_url 存在 → sha256(normalized_audio_url)
否则 source_url → sha256(source_url)
都没有 → 跳过并记录错误
```

规范化 URL 时只移除明确的跟踪参数，不能随意删除可能决定音频版本的 query。

## 5.4 单次同步输出

```text
BBC 6 Minute English: added=2 existing=18 failed=0
Overthink: added=1 existing=19 failed=0
The Daily: feed_timeout
TOTAL: added=3 existing=37 failed_feeds=1
```

单个 Feed 失败不能中断全批次。退出码：全部成功为 0；部分失败为 2；数据库整体不可用为 1。

## 5.5 Phase 1 验收

- 手动执行一条命令可导入 10 个 Podcast；
- 重复执行不会产生重复 Episode；
- 单个 RSS 超时不影响其他 RSS；
- 新 Episode 均为 `transcript_status=none`；
- App 暂时不必改动也能在 Supabase Table Editor 查看数据。

---

# 6. Podcast Processor

## 6.1 文件边界

```text
backend/podcast_processor/
├─ audio.py
├─ stt.py
├─ segmenter.py
├─ translator.py
├─ validator.py
├─ repository.py
└─ service.py

backend/scripts/
└─ process_episode.py
```

命令：

```text
python -m scripts.process_episode --episode-id <uuid>
```

## 6.2 状态机

```text
none ──开始──> processing ──成功──> ready
  ▲                 │
  └────人工重试──── failed
```

用数据库条件更新抢占任务：只有当前状态是 `none` 或 `failed` 才能改为 `processing`，防止重复执行。

## 6.3 临时音频

- 下载到系统临时目录；
- 限制最大文件大小和最大时长；
- 校验 Content-Type；
- 处理结束后无论成功失败都删除；
- 不上传到自己的永久存储，除非已取得授权。

---

# 7. STT + 翻译流程

```text
audio_url
→ 下载临时文件
→ ffprobe 获取真实时长
→ 必要时 ffmpeg 转为 STT 支持格式
→ STT（sentence/segment timestamps）
→ 清理重复片段、广告噪声、无意义短片段
→ 断句合并
→ 批量翻译（例如每批 20–50 句）
→ 时间轴校验
→ 人工试听抽检
→ transaction replace sentences
```

校验规则：

- 时间戳单调递增；
- `end > start`；
- 句子不为空；
- 最后一句不得明显超过音频时长；
- 相邻句大范围重叠视为失败；
- 翻译数量必须与英文句数量一致。

V1 不做 word timestamp，不做 official transcript alignment。

V2 有官方 transcript 时：用 STT 提供时间骨架，用 forced alignment 将官方文字映射到时间轴，最终仍需人工抽检。

---

# 8. SwiftUI 数据模型

建议把当前单文件 `PodcastFeature.swift` 逐步拆分，不需要引入复杂架构框架。

```swift
struct PodcastDTO: Decodable, Identifiable {
    let id: UUID
    let name: String
    let description: String
    let coverURL: URL?
    let category: PodcastCategory
    let level: String
}

struct EpisodeDTO: Decodable, Identifiable {
    let id: UUID
    let podcastID: UUID
    let title: String
    let description: String
    let audioURL: URL
    let coverURL: URL?
    let durationSeconds: Int?
    let publishDate: Date?
    let transcriptStatus: TranscriptStatus
}

struct SentenceDTO: Decodable, Identifiable {
    let id: UUID
    let sequence: Int
    let startTime: Double
    let endTime: Double
    let english: String
    let chinese: String?
}

enum TranscriptStatus: String, Decodable {
    case none, processing, ready, failed
}
```

Repository：

```text
PodcastRepository
├─ fetchPodcasts()
├─ fetchEpisodes(podcastID)
└─ fetchEpisode(id)

TranscriptRepository
└─ fetchSentences(episodeID)

WordRepository
├─ lookup(surfaceForm, sentenceID)
├─ savePodcastWord(...)
└─ fetchMyWords()

EpisodeProgressRepository
└─ upsertProgress(...)
```

保留“缓存优先、后台刷新”，但缓存的是 REST 响应，不再由 iOS 解析 RSS。

---

# 9. AVPlayer 设计

```text
EpisodePlayerStore (@MainActor)
├─ AVPlayer
├─ currentTime
├─ duration
├─ isPlaying
├─ playbackRate
├─ currentSentenceIndex
├─ load(episode)
├─ play/pause
├─ seek(seconds)
├─ skip(±15)
└─ playSentence(sentence)
```

关键点：

- 使用 `.playback` + `.spokenAudio` Audio Session；
- `addPeriodicTimeObserver` 间隔 0.25–0.5 秒；
- 支持后台和锁屏控制；
- 播放进度节流写入；
- 退出播放器时移除 observer；
- 网络错误提供重试，不自动从头播放；
- `playSentence` seek 到 `start_time`，到 `end_time + 0.3s` 自动暂停。

播放器只持有音频状态；字幕匹配和页面导航不要全部塞入一个巨型 Manager。

---

# 10. 字幕同步

字幕已按 `start_time` 排序。每次 currentTime 更新时使用二分查找，复杂度 O(log n)：

```text
找到最后一个 start_time <= currentTime 的 Sentence
若 currentTime < sentence.end_time → 当前句
否则 → 空档，不切到下一句
```

UI：

- 当前句：品牌色背景 + 左边线；
- 上一句/下一句：降低透明度；
- 当前句变化时滚动到中心；
- 用户手动滚动时暂停自动滚动，显示“回到当前句”；
- 点某句可 seek 到该句开始。

不要对 RSS description 伪造时间轴。只有 `transcript_status=ready` 才展示“同步字幕”。

---

# 11. 点词与收藏流程

```text
用户点字幕 token
→ 播放暂停
→ 规范化 surface form
→ 查本地缓存词典
→ 未命中则 GET words?lemma=...
→ Bottom Sheet
→ Save Word
→ 乐观显示“已收藏”
→ upsert favorite_words
→ upsert favorite_word_sources
→ 成功：保持已收藏
→ 失败：回滚并显示重试
→ 关闭 Sheet / 继续播放
```

Bottom Sheet MVP 字段：

- 单词；
- 音标；
- 中文释义；
- Explanation Language 为 English 时显示英文释义；
- Podcast 原句；
- 单词发音；
- Save Word。

不添加选择词书、标签或熟悉度。

---

# 12. 与现有单词系统集成

“我的单词”只有一个入口：

```text
My Words
├─ 词书收藏
└─ Podcast 收藏
```

Podcast 收藏卡增加来源区：

```text
overthink /ˌoʊvərˈθɪŋk/
过度思考

Source · Overthink
Why We Overthink
“We tend to overthink our decisions.”

[播放单词] [播放原句]
```

播放原句：

```text
favorite_word_source.sentence_id
→ Sentence.start_time / end_time
→ Episode.audio_url
→ 打开轻量播放器或 EpisodePlayer
→ seek(start_time)
→ 播放到 end_time
```

现有单词连续播放可以先播放单词发音与释义；Podcast 原句作为卡片上的显式按钮。第一版不强行把长音频切片混入现有单词播放队列，降低改造风险。

---

# 13. 异常处理

| 场景 | 后台处理 | App 处理 |
|---|---|---|
| RSS 超时 | 单源失败，继续其他源 | 无感知，展示数据库旧数据 |
| RSS guid 改变 | audio/source 哈希辅助审计 | 无 |
| audio_url 失效 | Episode 标记 unavailable | 禁止播放，显示来源页 |
| STT 失败 | status=failed，可手动重试 | 显示“暂无字幕”，仍可播放 |
| 翻译失败 | 不发布半成品，保持 processing/failed | 不展示不完整字幕 |
| 字幕漂移 | QA 失败，不设 published | 提供“字幕问题反馈”可延后 |
| 收藏第一步成功、来源失败 | 幂等重试 source | 单词仍在 My Words，来源显示同步中 |
| 用户未登录 | 可本地暂存，登录后迁移 | 不阻断首次点词 |
| 网络断开 | 不删除缓存 | 展示缓存和离线提示 |
| AVPlayer 中断 | 保存进度并暂停 | 恢复后由用户继续 |

所有后台命令必须幂等，可安全重复执行。

---

# 14. AI 成本控制

MVP 最重要的成本开关是 `editorial_status`：

```text
imported → 只存 metadata，成本近似 0
selected → 允许人工执行 Processor
published → App 可见
```

措施：

- 默认不处理新 Episode；
- 每周人工选择少量 5–15 分钟单集；
- 处理前检查是否已有 ready sentences；
- STT 结果按 Episode 保存，失败重试不重复处理成功步骤；
- 翻译批量请求，不逐句调用；
- 开发阶段只处理 2–3 个授权清晰的样例；
- 记录每集音频分钟数、STT 成本、翻译字符数；
- 设置月度软预算，超过后脚本拒绝新任务，除非显式 `--force`。

不根据“用户打开列表”自动触发 STT；V2 的用户需求触发也必须去重并有限流。

---

# 15. Dynamic Ad Insertion 与音频稳定性

## 问题

同一 `audio_url` 可能依据地区、时间或用户返回不同广告。STT 时下载的版本可能有 60 秒广告，而用户播放时只有 30 秒或广告位置不同，导致广告之后所有字幕整体偏移。

## MVP 可接受方案

- 优先选择无动态广告、教育类短节目；
- 入选前从不同时间/网络抽样播放；
- Processor 记录处理时的时长、Content-Length、ETag/Last-Modified（若有）和文件哈希；
- App 播放时比较 AVPlayer 实际 duration 与数据库 duration；差异超过阈值则关闭同步字幕，只保留音频播放；
- 发现漂移的节目从精选池移除；
- 不承诺所有候选 Podcast 都能提供同步字幕。

## 商业化稳定方案

优先与内容方签署授权并获得稳定、无动态广告的音频文件或固定媒体 URL；在许可范围内自托管该授权版本，并对同一版本生成字幕。若只能播放动态源，则需要音频指纹/广告段检测与动态时间轴校正，复杂度高，不属于 MVP。

---

# 16. 版权与授权

公开 RSS 代表“可被订阅发现”，不自动代表可以：

- 永久复制 MP3；
- 生成并公开完整 transcript；
- 翻译并再发布全文；
- 商业展示节目封面；
- 删除广告或修改音频；
- 用内容训练模型。

每个节目建立 rights checklist：

```text
RSS 播放允许？
App 内嵌播放允许？
封面展示允许？
全文转录允许？
中文翻译允许？
商业使用允许？
音频临时处理允许？
音频自托管允许？
要求怎样署名与跳转？
```

没有明确授权时：最多将其作为内部研究源；不要公开全文字幕和翻译。首批正式上线内容优先选自有内容、开放许可内容或已取得书面授权的内容。

---

# 17. MVP 开发任务与优先级

## Phase 1：RSS → Database

目标：把 iOS 直接抓 RSS 替换为可控的后台内容池。

任务：

- 建 `podcasts`、`episodes` 表和 RLS；
- 建 `rss_sources.json`；
- 实现 `sync_podcasts.py`；
- guid/fallback 去重；
- 导入 2 个测试节目，再扩到 10 个；
- 记录版权审核状态。

验收：重复执行无重复；单源失败不影响全局；Table Editor 能看到元数据。

## Phase 2：Database → SwiftUI → 可播放

任务：

- 建 `PodcastRepository`；
- iOS 从 Supabase 获取 Podcast/Episode；
- 保留本地缓存优先；
- AVPlayer 播放、暂停、seek、后台、进度；
- 移除客户端 RSS 抓取主路径，保留开发 fallback 一版后删除。

验收：App 只发起自己的 Supabase 请求；选一集可以稳定播放；恢复上次位置。

## Phase 3：Audio → STT → 字幕

任务：

- 建 `sentences` 表；
- 实现 `process_episode.py`；
- 完成临时下载、STT、翻译、验证、写库；
- 只处理 1 个授权样例；
- iOS 二分匹配字幕并高亮。

验收：一个 Episode 可从命令行处理到 ready；真机字幕主观同步，异常时自动关闭字幕而不影响播放。

## Phase 4：字幕 → 点词 → 收藏

任务：

- 建/导入最小 `words` 词典；
- 英文 token 点击；
- Bottom Sheet；
- 升级 `favorite_words`；
- 新建 `favorite_word_sources`；
- 本地乐观更新和失败回滚。

验收：从字幕点词到收藏不超过两次点击；收藏后在现有 My Words 出现。

## Phase 5：My Words → 原句回听

任务：

- My Words 展示 Podcast 来源、原句和节目；
- 实现 `playSentence`；
- 从收藏跳回 Episode 对应位置；
- 登录前本地收藏迁移到云端。

验收：用户可从单词卡播放原句，并返回完整节目继续收听，闭环完成。

---

# 18. 推荐的下一步（只做一个可验证步骤）

下一步只实施 Phase 1 的最小切片：

1. 创建 `podcasts` 与 `episodes` 两张表；
2. 只配置 BBC 6 Minute English 和一个版权可控测试源；
3. 编写 `sync_podcasts.py`；
4. 手动执行两次，验证第二次 `added=0`；
5. 暂时不修改 iOS、不调用 STT。

验证通过后，再进入 Phase 2。这样发生问题时，只需要排查 RSS、Collector 或数据库三者之一，不会同时调试播放器、AI 和字幕。

