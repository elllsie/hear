# Podcast 多来源 V1 Pipeline

> 当前主流程已改为能力检测驱动。下方旧的手工命令仅作单步调试参考。

首次使用请在 Supabase SQL Editor 依次执行：

1. `supabase/sql/podcast_content_schema.sql`
2. `supabase/sql/podcast_sentences_schema.sql`
3. `supabase/sql/podcast_pipeline_v1_upgrade.sql`
4. `supabase/sql/podcast_audio_mirror.sql`（仅在获得音频再托管授权并启用镜像时）
5. `supabase/sql/podcast_ai_insights_access.sql`（创建 AI 内容表后执行）
6. `supabase/sql/podcast_multilanguage_upgrade.sql`（启用德语 Podcast）
7. `supabase/sql/user_app_state.sql`（账号跨设备同步语境词、Podcast 单词和偏好设置）

完整流水线：

```bash
pip install -r requirements.txt
pip install -r requirements-transcription.txt
python scripts/process_podcast_content.py --limit 20
```

流水线自动执行 RSS 导入、音频能力检测、VTT/SRT 解析、Whisper fallback、可选中译和发布质量验证。新增节目只需修改 `config/rss_sources.json`。

当来源配置包含 `"audio_mirror": {"enabled": true}` 时，流水线会在能力检测后将音频上传到公开的 `podcast-audio` Storage bucket，并把 `episodes.audio_url` 切换为稳定的 Supabase URL。原始发布方地址保存在 `original_audio_url`，RSS 更新时会自动使旧镜像失效并等待重新镜像。只应对明确拥有再托管权的节目启用此选项。

后台中译使用可选的 LibreTranslate-compatible API：

```dotenv
TRANSLATION_API_URL=https://translator.example/translate
TRANSLATION_API_KEY=
```

未配置时由 iOS 18+ 系统翻译 fallback。发布前如强制要求已审核中译，运行 `validate_podcast_episodes.py --require-chinese`。

AI 总结和难词在后端预生成，密钥不会进入 iOS App：

```dotenv
AI_PROVIDER=openai
AI_BASE_URL=https://api.openai.com/v1
AI_API_KEY=
AI_MODEL=
```

使用其他 OpenAI-compatible 服务时，将 `AI_PROVIDER` 改为
`openai_compatible`，并填写该服务的 `AI_BASE_URL`、`AI_API_KEY` 和 `AI_MODEL`。
未配置 `AI_API_KEY` 时主流水线会自动跳过此阶段。单独重新生成：

```bash
python scripts/generate_podcast_ai_insights.py --limit 5 --force
```

---

# 旧版单步命令（调试参考）

当前只同步 RSS 元数据到 Supabase：Podcast、Episode、发布方音频 URL。它不会下载音频、生成字幕，或自动把内容发布给 iOS 用户。

## 1. 本地环境

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

在 `.env` 中填写 Supabase `service_role` key。此密钥只能留在后端本机，不能放入 Swift 代码或提交到 Git。

## 2. 先试运行

```bash
python scripts/sync_podcasts.py --dry-run --limit 5
```

试运行只读取 RSS，不写数据库。也可以只检查一个来源：

```bash
python scripts/sync_podcasts.py --dry-run --source bbc_6_minute_english --limit 5
```

## 3. 写入 Supabase

```bash
python scripts/sync_podcasts.py --limit 20
```

重复执行是安全的：程序按 Podcast RSS URL 和 Episode GUID 去重，不覆盖已有 Episode 的审核与字幕状态。

## 4. 人工审核后发布

新 Podcast 的 `rights_status` 默认为 `unknown`，新 Episode 的 `editorial_status` 默认为 `imported`，因此 iOS 客户端暂时看不到它们。确认内容与授权状态后，在 Supabase 中人工改为 `approved` 和 `published`。

## 5. 本地生成同步字幕

先在 Supabase SQL Editor 执行 `supabase/sql/podcast_sentences_schema.sql`，然后安装一次本地转录依赖：

```bash
pip install -r requirements-transcription.txt
```

先生成最新一集 BBC 的英文时间戳字幕：

```bash
python scripts/transcribe_podcasts.py --podcast-name "BBC 6 Minute English" --limit 1
```

首次运行会下载并缓存 `tiny.en` 模型。如果网络中断，重新执行同一命令即可继续。单集验证后批量处理其余已发布 BBC 内容：

```bash
python scripts/transcribe_podcasts.py --podcast-name "BBC 6 Minute English" --limit 5
```

脚本只在本机转录，音频临时文件结束后自动删除；模型缓存在 `backend/.models`，不会提交到 Git。

## 6. 新节目复用流程

节目统一配置在 `config/rss_sources.json`。`transcript.strategy` 支持：

- `bbc_official_pdf`：BBC 官方 PDF，文本准确、时间轴近似。
- `overthink_timestamped_html`：Overthink 官网逐字稿，使用官方精确时间戳。
- `whisper_local`：没有官方逐字稿时，本地 Whisper 生成时间轴。
- `none`：只同步节目与音频，不生成字幕。

同步 RSS 并按配置处理字幕：

```bash
python scripts/process_podcast_content.py
```

只处理一个节目、跳过 RSS：

```bash
python scripts/process_podcast_content.py --source overthink --skip-rss
```

iOS 始终只读取统一的 `episodes` 与 `episode_sentences`，新增节目不需要修改播放器和字幕页面。

## 本地内容管理网页

项目根目录双击 `启动内容管理台.command`，或运行：

```bash
backend/.venv/bin/python -B -m backend.local_admin.server --open
```

提供词书与音频检查、草稿生成、发布备份、问题标记、播客处理、文章 AI 总结和任务日志。仅监听本机回环地址并要求登录。完整操作说明见 [本地内容工作室](../docs/local_content_studio.md)。
