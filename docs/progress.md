你是一名资深移动端架构师、Python 后端工程师和 iOS SwiftUI 开发工程师。

我正在已有的语言学习 App 中增加英文 Podcast 功能。

请基于以下产品和技术逻辑，帮我设计并逐步实现 Podcast 内容获取、存储、加工、API 和 iOS 播放流程。

====================
一、产品背景
====================

我已经有一个上线的语言学习 App。

当前支持：

1. 用户登录
2. 选择学习语言
   - English
   - Deutsch
3. 英语单词学习/播放
4. 德语单词学习/播放
5. 用户自己的单词库

现在准备新增：

English Podcast

第一阶段：
- 只有 English 支持 Podcast
- Deutsch 暂时保持原来的单词功能

Podcast 的核心学习闭环：

听 Podcast
↓
遇到不认识的单词
↓
点击查看释义
↓
收藏到现有英语单词库
↓
通过已有单词播放功能复习
↓
可以重新播放 Podcast 中出现这个单词的原句

即：

「听 → 遇 → 收 → 听」


====================
二、总体技术架构
====================

希望采用：

Podcast RSS
↓
Python Backend
↓
Database
↓
REST API
↓
SwiftUI App

不要让 SwiftUI App 直接负责所有 RSS 抓取和内容加工。

App 主要负责：

- 获取 Podcast 数据
- 展示 Podcast
- 播放音频
- 展示同步字幕
- 查询单词
- 收藏单词


====================
三、Podcast 内容获取
====================

Podcast 内容优先通过公开 RSS Feed 获取。

第一阶段不做复杂的全网 Podcast 搜索。

先人工维护大约 10 个 Podcast RSS，例如：

- Overthink
- BBC 6 Minute English
- Hidden Brain
- Luke's English Podcast
- All Ears English
- TED Talks Daily
- Stuff You Should Know
- The Psychology Podcast
- The Daily
- The Diary Of A CEO

注意：

这些名称只是候选内容源。

实际接入前需要确认：
- RSS 是否公开
- 是否允许第三方播放器使用
- transcript 是否允许加工/展示
- 是否涉及商业使用和版权问题

不要默认“公开 RSS = 可以任意复制、翻译、重新发布”。


====================
四、Podcast Collector
====================

后台设计一个：

Podcast Collector

职责：

读取 RSS Feed。

建议 Python 使用：

feedparser

获取：

Podcast：

- name
- description
- cover_url
- rss_url
- language
- category


Episode：

- title
- description
- publish_date
- duration
- audio_url
- cover_url
- episode_guid


流程：

人工添加 Podcast RSS
↓
Python 读取 RSS
↓
解析 Podcast
↓
解析 Episodes
↓
检查数据库
↓
如果 Episode 已存在：
忽略

如果 Episode 不存在：
新增 Episode


使用：

episode_guid

或稳定唯一标识进行去重。

第一版允许：

手动运行同步脚本

例如：

sync_podcasts.py

后续再增加定时任务。


====================
五、数据库设计
====================

MVP 只设计必要的数据结构。

核心包含：

1. Podcast
2. Episode
3. Sentence
4. UserWord


Podcast 示例字段：

id
name
description
rss_url
cover_url
language
category
created_at


Episode 示例字段：

id
podcast_id
guid
title
description
audio_url
cover_url
duration
publish_date

transcript_status

transcript_status 可以包含：

none
processing
ready
failed


Sentence 示例字段：

id
episode_id

sequence

start_time
end_time

english
chinese


UserWord：

尽量复用现有单词系统。

Podcast 收藏的单词额外记录：

source_type = podcast

episode_id
sentence_id

从而知道：

这个单词来自哪个 Podcast
来自哪一期 Episode
来自哪一句话。


====================
六、Podcast Processor
====================

设计第二个后台模块：

Podcast Processor

职责：

对 Episode 进行语言学习内容加工。


流程：

Episode
↓
获取 audio_url
↓
Speech-to-Text
↓
生成英文 Transcript
↓
获得时间戳
↓
英文分句
↓
中文翻译
↓
保存 Sentence


重要原则：

以实际 Podcast 音频作为时间轴基准。

不要默认网上现成 transcript 和 audio 时间完全一致。


最终 Sentence：

{
    "start_time": 12.3,
    "end_time": 16.8,
    "english": "We tend to overthink our decisions.",
    "chinese": "我们往往会过度思考自己的决定。"
}


第一版本：

只要求 sentence-level timestamp。

暂时不要实现：

word-level timestamp。


====================
七、字幕同步
====================

SwiftUI 播放器使用 AVPlayer。

播放过程中获取：

currentTime

根据：

start_time <= currentTime < end_time

找到当前 Sentence。

例如：

currentTime = 13.5

匹配：

start_time = 12.3
end_time = 16.8

则高亮：

We tend to overthink our decisions.

我们往往会过度思考自己的决定。


当前句突出显示。

上一句和下一句弱化显示。


====================
八、单词点击
====================

用户可以点击英文字幕中的单词。

例如：

overthink


点击后：

不要跳转新页面。

使用 Bottom Sheet 展示：

overthink

音标

中文释义

英文释义（如果当前 Explanation Language = English）

Podcast 原句

单词发音

+ Save Word


第一版本要求：

点击 Save Word 后直接收藏。

不要增加：

- 选择单词本
- 标签
- 熟悉程度
- 收藏分类

降低操作成本。


====================
九、单词收藏
====================

Podcast 收藏的单词进入现有英语单词库。

不要建立单独的：

“Podcast 生词本”。


例如：

overthink

过度思考


Source:

Overthink
Why We Overthink


"We tend to overthink our decisions."


支持：

Play Word

Play Original Sentence


Play Original Sentence 的逻辑：

UserWord
↓
sentence_id
↓
Sentence.start_time
↓
Episode.audio_url
↓
AVPlayer seek
↓
从对应时间开始播放


====================
十、App API
====================

设计简单 REST API。


例如：

GET /podcasts

返回 Podcast 列表。


GET /podcasts/{podcast_id}/episodes

返回某个 Podcast 的 Episodes。


GET /episodes/{episode_id}

返回：

Episode 信息
audio_url
transcript_status


GET /episodes/{episode_id}/sentences

返回：

[
    {
        "start": 12.3,
        "end": 16.8,
        "en": "...",
        "zh": "..."
    }
]


POST /words

收藏单词。


GET /words

获取当前用户单词。


要求：

第一版 API 简单、RESTful、容易维护。

不要过度设计微服务。


====================
十一、Podcast 音频存储策略
====================

第一版本：

数据库不直接存 MP3。

优先保存：

audio_url

App 使用 AVPlayer 播放原始 Podcast 音频。

即：

Episode
↓
audio_url
↓
AVPlayer


但是需要考虑：

部分 Podcast 可能存在 Dynamic Ad Insertion。

同一个 audio_url 在不同时间可能返回不同广告版本，从而造成：

字幕时间戳
≠
用户实际播放时间


请在技术设计中：

1. 解释这个问题
2. 给出 MVP 可以接受的处理方法
3. 给出未来正式商业化版本更稳定的解决方案

同时考虑版权和内容授权，不要默认可以将第三方 MP3 永久保存到自己的服务器。


====================
十二、Transcript 策略
====================

V1：

直接：

Podcast Audio
↓
STT
↓
Timestamp Transcript
↓
翻译


优点：

字幕时间与音频来源一致。


V2：

如果 Podcast 提供官方 transcript：

Audio
↓
STT Timestamp

+

Official Transcript

↓

Forced Alignment / Transcript Alignment

↓

官方准确文字
+
音频时间戳


第一版暂时不要实现复杂 Alignment。


====================
十三、AI 成本控制
====================

不要自动处理抓取到的所有 Podcast Episode。

第一阶段：

RSS 抓到 Episode
↓
只保存 metadata

不要立即 STT。


只有：

1. 管理员精选 Episode

或者

2. 用户真正需要某一期


才进入：

processing
↓
STT
↓
翻译
↓
保存字幕


避免大量无效 AI API 成本。


====================
十四、第一版本完整数据流
====================

请严格按照以下逻辑设计：


【内容获取】

Podcast RSS

↓

Podcast Collector

↓

Podcast

↓

Episode metadata

↓

Database



【内容加工】

精选 Episode

↓

Podcast Processor

↓

Audio

↓

STT

↓

English Transcript

↓

Sentence Timestamp

↓

Chinese Translation

↓

Sentence Database



【App】

SwiftUI

↓

GET /podcasts

↓

Podcast List

↓

Episode List

↓

Episode Player

↓

AVPlayer + Sentence Timestamp

↓

同步字幕



【学习】

Podcast

↓

听

↓

点击陌生单词

↓

查看释义

↓

Save Word

↓

现有 My Words

↓

单词播放

↓

Podcast Original Sentence

↓

重新听懂


核心闭环：

听 → 遇 → 收 → 听


====================
十五、第一版本不要做
====================

暂时不要：

- AI Chat
- AI Teacher
- 自动 Quiz
- 社区
- 评论
- 排行榜
- 推荐算法
- 全网 Podcast 搜索
- 用户上传 Podcast
- Word-level 字幕高亮
- 自动处理全部 Podcast
- 微服务
- 复杂消息队列
- 复杂内容推荐系统


优先：

简单
稳定
可以上线
方便以后扩展。


====================
十六、请你输出
====================

请基于以上需求，从 MVP 角度帮我输出：

1. 系统架构图
2. 数据流图
3. 数据库表结构
4. REST API 设计
5. Python Podcast Collector 设计
6. Podcast Processor 设计
7. STT + 翻译处理流程
8. SwiftUI Podcast 数据模型
9. AVPlayer 播放器设计
10. 字幕同步实现方案
11. 点击单词和收藏流程
12. 与现有单词系统的集成方式
13. 异常处理方案
14. AI API 成本控制方案
15. 版权/授权需要注意的问题
16. MVP 开发任务拆解

最后按照开发优先级拆成：

Phase 1
RSS → Database

Phase 2
Database → SwiftUI → Podcast 可以播放

Phase 3
Audio → STT → 字幕

Phase 4
字幕 → 点击单词 → 收藏

Phase 5
My Words → Podcast 原句回听


重要：

我是独立开发者，并且主要通过 AI / Vibe Coding 辅助开发。

因此：

- 不要过度设计
- 不要一次生成大量复杂代码
- 优先选择成熟、简单、容易调试的方案
- 每一个阶段都应该可以独立运行和验证
- 如果存在多种技术方案，请优先推荐最简单可靠的方案
- 在写代码之前先解释架构和数据流
- 每次只实现一个可以验证的小步骤