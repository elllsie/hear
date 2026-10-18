# 播客新增与发布流程

当前项目已经具备完整的播客上新流水线。正常情况下，新增播客无需修改 iOS 代码，只需添加 RSS 配置、运行处理脚本、人工审核并发布。

## 一、首次准备

进入后端目录并创建环境：

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt
pip install -r requirements-transcription.txt

cp .env.example .env
```

在 `backend/.env` 填写：

```dotenv
SUPABASE_URL=https://frljmdtogeyajpbwjavv.supabase.co
SUPABASE_SERVICE_ROLE_KEY=你的_service_role_key
```

`service_role` 只能放在本地后台，不能写入 Swift 或提交到 Git。如果已经配置过，这一步不需要重复。

## 二、新增播客源

编辑 `backend/config/rss_sources.json`，增加一项：

```json
{
  "key": "new_podcast",
  "name": "New Podcast",
  "rss_url": "https://example.com/podcast.rss",
  "website_url": "https://example.com/",
  "language": "en",
  "category": "thinking",
  "host": "Podcast Host",
  "region": "United States",
  "level": "B2",
  "audio_mirror": {
    "enabled": false,
    "bucket": "podcast-audio"
  },
  "transcript": {
    "strategy": "auto"
  },
  "is_active": true
}
```

`category` 决定 App 中的分区：

| 配置值 | App 分区 |
| --- | --- |
| `easy` | Easy Start |
| `thinking` | Deep Thinking |
| `world` | Real World English |
| `future` | Future & Technology |

`language` 决定节目只出现在对应的学习语言中：`en` 为英语，`de` 为德语。第一次接入德语节目前，需在 Supabase SQL Editor 执行 `supabase/sql/podcast_multilanguage_upgrade.sql`。

新节目建议先设置：

```json
"audio_mirror": { "enabled": false }
```

只有确认获得音频再托管授权后，才可以开启 Supabase 音频镜像。

## 三、试运行 RSS

只检查新源，不写入数据库：

```bash
backend/.venv/bin/python backend/scripts/sync_podcasts.py \
  --dry-run \
  --source new_podcast \
  --limit 3
```

重点确认：

- RSS 可以正常访问。
- 能读取单集标题、发布日期和音频地址。
- 音频链接对应完整节目。
- 没有导入预告、广告或重复单集。
- 封面和官网地址正确。

## 四、运行完整处理流水线

确认 RSS 正常后：

```bash
backend/.venv/bin/python backend/scripts/process_podcast_content.py \
  --source new_podcast \
  --limit 3
```

该命令会依次执行：

```text
同步 RSS
  ↓
检测音频格式与可用性
  ↓
读取 RSS 中的 VTT/SRT 字幕
  ↓
没有可用字幕时使用本地 Whisper 转录
  ↓
生成中文字幕（配置翻译服务时）
  ↓
生成 AI 总结和难词（配置 AI 服务时）
  ↓
检查音频、字幕数量和时间轴
```

第一次使用 Whisper 时会下载模型，之后模型保存在 `backend/.models`。

如果还没有配置 AI，可以先跳过：

```bash
backend/.venv/bin/python backend/scripts/process_podcast_content.py \
  --source new_podcast \
  --limit 3 \
  --skip-ai
```

## 五、查看质检结果

流水线会自动运行质量检查。也可以单独重新检查：

```bash
backend/.venv/bin/python backend/scripts/validate_podcast_episodes.py \
  --podcast-name "New Podcast" \
  --limit 3
```

如果要求每句都有中文：

```bash
backend/.venv/bin/python backend/scripts/validate_podcast_episodes.py \
  --podcast-name "New Podcast" \
  --limit 3 \
  --require-chinese
```

通过检查的单集应满足：

- `audio_status = available`
- `transcript_status = ready`
- `validation_status = passed`
- 字幕至少有两句。
- 字幕时间顺序正常。
- 字幕结束时间与音频时长误差不超过 5% 或 30 秒。
- `editorial_status` 从 `imported` 进入 `selected`。

## 六、人工审核

查看候选内容：

```bash
backend/.venv/bin/python backend/scripts/review_podcast_content.py \
  --limit 20
```

发布前建议人工试听至少一集，检查：

- 标题和封面是否正确。
- 音频是否能完整播放和拖动。
- 字幕是否与声音基本同步。
- Whisper 是否存在严重误识别。
- 内容是否适合学习。
- AI 总结和难词是否有明显错误。
- 是否拥有展示字幕、翻译和音频镜像的权利。

## 七、正式发布

确认审核后，发布最新一集：

```bash
backend/.venv/bin/python backend/scripts/publish_latest_podcast.py \
  --podcast-name "New Podcast" \
  --latest 1 \
  --confirm-reviewed
```

发布最新三集：

```bash
backend/.venv/bin/python backend/scripts/publish_latest_podcast.py \
  --podcast-name "New Podcast" \
  --latest 3 \
  --confirm-reviewed
```

这个脚本会：

- 将播客的 `rights_status` 改为 `approved`。
- 将通过检查的单集改为 `editorial_status = published`。
- 不会发布音频、字幕或验证未通过的单集。

## 八、App 展示条件

iOS App 只展示同时满足以下条件的内容：

```text
Podcast:
is_active = true
rights_status = approved

Episode:
editorial_status = published
transcript_status = ready
```

发布后，在 App 的播客合集页面点“重试”或重新进入页面即可读取，不需要重新打包 App。

## 九、后续更新新单集

同一节目以后有新单集，再次运行：

```bash
backend/.venv/bin/python backend/scripts/process_podcast_content.py \
  --source new_podcast \
  --limit 5
```

审核完成后再运行：

```bash
backend/.venv/bin/python backend/scripts/publish_latest_podcast.py \
  --podcast-name "New Podcast" \
  --latest 1 \
  --confirm-reviewed
```

脚本会按照 RSS URL 和 Episode GUID 去重，重复运行不会重复创建同一集。

## 十、建议运营节奏

```text
每周同步新单集
  ↓
自动生成字幕、翻译和 AI 内容
  ↓
自动质检
  ↓
人工抽查
  ↓
发布
```
