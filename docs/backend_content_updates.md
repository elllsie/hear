# 纯后端内容更新说明

## 当前能力

- 词书：App 先读取安装包内的 A1、A2、B1、考研和雅思词书，再后台读取 Supabase `word_books` 目录。远端数据验证成功才替换；失败使用内置数据或最后一次成功缓存。
- 发音：每本远端词书可通过 `audio_path_prefix` 指向自己的 Supabase Storage 路径。MP3 获取失败时保留系统发音兜底。
- 播客：列表、单集、逐句文本都已从 Supabase 动态读取，并支持页面下拉刷新。
- AI 总结：`episode_ai_insights` 和 `episode_difficult_words` 已动态读取，无需发布 App。

## 首次启用远端词书

1. 在 Supabase SQL Editor 执行 `supabase/sql/word_books_remote_catalog.sql`。
2. 先用 dry-run 验证词书：

```bash
backend/.venv/bin/python backend/scripts/publish_word_book.py \
  --book-id A1 --title A1 --language german \
  --source 听会儿/data/A1.json --content-version 2026-10-21 \
  --audio-path-prefix v2/words/de-de/a1 --dry-run
```

3. 去掉 `--dry-run` 上传，但先不加 `--activate`。脚本只上传并校验版本文件，不修改线上目录，因此不影响用户。
4. 验收 Storage 中的 JSON 和音频后，用相同命令加 `--activate` 发布。

英语示例的音频前缀为 `v2/words/en-us/kaoyan_2` 或 `v2/words/en-us/ielts_9400`。

## 后续新增或修改词书

- 新增：使用新的稳定 `book-id` 发布，设置语言、标题、JSON 和音频前缀；激活后已安装新版 App 的用户会自动看到。
- 修改：保留 `book-id`，提高 `content-version` 并上传新的 JSON。不要覆盖旧版本对象，便于回滚。
- 下线：将 `word_books.is_active` 改为 `false`。内置的五本词书不会因此消失，它们始终是离线兜底。
- 回滚：把目录行的 `content_version`、`data_url` 和 `audio_path_prefix` 指回已经验收的旧版本。

## 防损坏规则

- 只接受 HTTPS 数据地址、合法音频前缀、非空且不重复的单词 ID，以及不超过 25 MB/10 万条的 JSON。
- 新数据下载或解析失败时不覆盖成功缓存。
- 目录不可用时读取最后一次成功缓存；首次安装且无缓存时读取安装包内数据。
- 正在播放的词书不会被远端刷新强制切换；下一次打开词书时使用新内容。
- 发布脚本默认不激活。必须显式使用 `--activate` 才对客户端可见。

## 内容与发音的更新时效

- 词书目录和 JSON：每次 App 进入主界面并加载词书时检查。
- 词书 JSON：按 `content_version` 保存为独立缓存；新版本验证成功后使用。
- 发音：继续使用现有 `TingHuiErAudioV4` 缓存、内容修订号和定时刷新机制；远端失败时使用系统音。
- 播客与 AI 总结：页面重新进入或下拉刷新后读取后台新内容。
