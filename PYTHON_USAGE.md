# Python 使用速查

本文档记录项目里 `generate_word_audio.py` 的常用方法。默认在项目根目录运行：

```bash
cd /Users/pengying/听会儿
```

## 安装依赖

首次使用前安装 `gTTS`：

```bash
python3 -m pip install gTTS
```

## 查看帮助

```bash
python3 generate_word_audio.py --help
```

## 生成德语单词音频

生成单个词书：

```bash
python3 generate_word_audio.py A1
```

生成多个词书：

```bash
python3 generate_word_audio.py A1 A2 B1
```

使用 glob 生成全部 JSON：

```bash
python3 generate_word_audio.py '听会儿/data/*.json'
```

默认输出到：

```text
听会儿/audio/words/
```

## 生成中英文释义音频

只生成 `meaningZh` 和 `meaningEn` 对应的释义音频：

```bash
python3 generate_word_audio.py A1 A2 B1 --only-meanings
```

输出目录：

```text
听会儿/audio/meanings/zh/
听会儿/audio/meanings/en/
```

## 同时生成单词和释义音频

```bash
python3 generate_word_audio.py A1 A2 B1 --include-meanings
```

会同时写入：

```text
听会儿/audio/words/
听会儿/audio/meanings/zh/
听会儿/audio/meanings/en/
```

## 重新生成已有音频

默认已有 `.mp3` 会跳过。需要强制覆盖时加 `--overwrite`：

```bash
python3 generate_word_audio.py A1 A2 B1 --include-meanings --overwrite
```

## 慢速发音

```bash
python3 generate_word_audio.py A1 --slow
```

释义音频也可以慢速：

```bash
python3 generate_word_audio.py A1 --only-meanings --slow
```

## 指定输出目录

德语单词音频可指定目录：

```bash
python3 generate_word_audio.py A1 --audio-dir 听会儿/audio/words
```

`--only-meanings` 的中英文释义目录是固定的：

```text
听会儿/audio/meanings/zh/
听会儿/audio/meanings/en/
```

## 不复用旧音频

脚本默认会尝试从旧的 `听会儿/audio/` 子目录里复用同名单词音频。想完全重新按当前逻辑生成时：

```bash
python3 generate_word_audio.py A1 A2 B1 --no-reuse-existing
```

## 语言代码

德语单词默认使用：

```text
--lang de
```

可以手动指定其他 gTTS 语言代码：

```bash
python3 generate_word_audio.py A1 --lang de
```

释义音频固定使用：

```text
meaningZh -> zh-CN
meaningEn -> en
```

## 推荐日常命令

第一次完整生成：

```bash
python3 generate_word_audio.py A1 A2 B1 --include-meanings
```

只补中英文释义：

```bash
python3 generate_word_audio.py A1 A2 B1 --only-meanings
```

数据改过后强制重做全部：

```bash
python3 generate_word_audio.py A1 A2 B1 --include-meanings --overwrite
```

## 简单校验

检查 Python 文件语法：

```bash
python3 -B -m py_compile generate_word_audio.py
```

查看当前会识别哪些参数：

```bash
python3 generate_word_audio.py A1 --help
```

