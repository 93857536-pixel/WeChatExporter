# 多平台功能 SPEC v2.19（三端对齐：macOS / Windows / Linux）

本文件是「全文搜索、定时增量、脱敏导出、过滤导出、年度报告、日历提取」6 项功能
的**唯一事实来源**。三端实现必须遵守本文档的数据格式、设置键、CLI 参数与产物命名。
UI 样式可以按平台习惯调整，但功能行为、产物文件名、设置语义必须完全一致。

## 0. 通用约定
- 所有产物默认生成在「导出根目录」（用户选择的导出路径）。
- 时区：统一 Asia/Shanghai（报告展示）；.ics 用 TZID=Asia/Shanghai 的本地时间。
- 时间戳：Unix 秒（10 位）。消息来源字段与 ChatStatsReport 的解析口径一致
  （chat.json 行：time/timestamp/sender/type/typeName/content；
  wx-cli 行可能是嵌套 message 对象，按现有 intField/stringField 口径取）。
- 设置持久化：macOS=UserDefaults（键名见下）、Windows=LocalAppData/settings.json、
  Linux=$XDG_CONFIG_HOME/wechat-exporter/settings.json（默认 ~/.config/...）。
- 设置键（跨平台同名，各平台存储位置不同）：

| 键 | 类型 | 默认 | 含义 |
|---|---|---|---|
| export.searchIndex | bool | true | 导出时在根目录生成 wce-search.sqlite 搜索索引 |
| export.autoSync.enabled | bool | false | 定时增量导出总开关 |
| export.autoSync.intervalMinutes | int | 60 | 定时间隔（分钟，≥5） |
| export.autoSync.exportDir | string | 导出根目录 | 定时任务目标目录 |
| export.autoSync.contactIDs | string(json array) | [] | 会话子集（空=上次 UI 选中的全部/全部会话） |
| export.autoSync.lastRun | string | "" | 上次运行时间（ISO 本地） |
| export.anon.enabled | bool | false | 脱敏导出总开关 |
| export.anon.maskPii | bool | true | 同时模糊化手机号/身份证/邮箱 |
| export.anon.keepMapping | bool | true | 保留映射文件（可逆）；false=导出后销毁 |
| export.filter.enabled | bool | false | 过滤导出总开关 |
| export.filter.fromDate | string yyyy-MM-dd | "" | 起始日期（含，空=不限） |
| export.filter.toDate | string yyyy-MM-dd | "" | 结束日期（含，空=不限） |
| export.filter.keywords | string（逗号分隔） | "" | 关键词（空=不过滤内容） |
| export.annualReport | bool | true | 生成年度可视化报告 HTML |
| export.calendarExtract | bool | true | 生成日历事件 .ics/.json |

## 1. 全文搜索（P0-A）
产物：导出根目录 `wce-search.sqlite`
- SQLite 数据库，两张表：
  - `meta(key TEXT PRIMARY KEY, value TEXT)` —— 记录 schema_version=1、generated_at、message_count。
  - 优先 FTS5 虚拟表：
    `CREATE VIRTUAL TABLE wce_fts USING fts5(chat TEXT, ts UNINDEXED, sender TEXT, content TEXT)`
  - FTS5 不可用时降级：`CREATE TABLE wce_rows(chat TEXT, ts INTEGER, sender TEXT, content TEXT)` + LIKE 查询。
- 每个会话一行一条消息入库：chat=会话显示名，ts，sender，content（仅文本类消息 content；
  媒体类存 "[图片]"/"[视频]" 占位）。
- 生成时机：导出流程最后（与 index.html 同层），受 export.searchIndex 开关控制。
- App 搜索面板：打开最近一次导出目录的 wce-search.sqlite（没有则提示先导出）；
  输入关键词 → 查询（FTS5 MATCH，含转义；降级 LIKE `%kw%`）→ 按 ts 倒序取前 200 条，
  展示：会话名 / 时间 / 发言人 / 内容摘要（±40 字符，命中词高亮）；点击结果 → 用系统
  程序打开对应会话目录的 chat.txt（或定位行）。
- CLI 无头搜索：`wce search <kw> [--dir <导出根>]`（见 §7）输出前 20 条文本。

## 2. 定时增量导出（P0-B）
- 语义：每隔 intervalMinutes 跑一次**增量导出**（复用现有 IncrementalExport 游标机制，
  只导新增；无新增则该次静默结束，写日志行 "no-change"）。
- 三端安装器（设置里一键装/卸，显示当前状态与上次运行时间）：
  - macOS：`~/Library/LaunchAgents/com.wce.autosync.plist`，
    `ProgramArguments=[<app 可执行文件路径>, wce, --auto-sync]`，
    StartInterval=intervalMinutes*60；日志 → ~/Library/Logs/wce-autosync.log。
    安装=写 plist + `launchctl bootstrap`；卸载=`launchctl bootout` + 删 plist。
  - Windows：`schtasks /Create /SC MINUTE /MO n /TN "WCE AutoSync" /TR "<exe> wce --auto-sync"`；
    删除=`schtasks /Delete /TN "WCE AutoSync"`。日志 → %LocalAppData%/WCE/autosync.log。
  - Linux：systemd user timer+service：`~/.config/systemd/user/wce-autosync.{service,timer}`，
    OnUnitActiveSec=间隔；`systemctl --user daemon-reload && enable --now wce-autosync.timer`；
    日志 → ~/.local/state/wce/autosync.log（journal 亦可）。
- 无头 `wce --auto-sync` 行为：读设置 → 若 autoSync.enabled=false 直接退出 0；
  对 contactIDs 子集（空=全部已知会话）逐个做增量导出到 autoSync.exportDir；
  走完整后处理管线（索引/脱敏/过滤/报告/日历按各自开关）；
  结束写 export.autoSync.lastRun；全程日志追加写 autosync.log；退出码 0=成功、1=失败。
- GUI 不依赖任务也能手动跑；任务只是「无人值守」入口。

## 3. 脱敏导出（P1-A）
- 作用点：对导出根目录下的文本产物（chat.txt / chat.csv / chat.json / 单文件 HTML /
  统计 HTML / 年度报告 HTML）做替换；媒体文件名不脱敏。
- 名称伪化：所有出现的会话名/发言人 → `用户{A,B,C...}`（按名称排序确定性分配，
  A-Z 后转 AA-AB）；群成员单独按会话内排序。
- PII 模糊化（export.anon.maskPii）：
  - 手机号（11 位，1[3-9] 开头）→ `138****5678`
  - 身份证 18 位 → 保留前 6 位 + 后 2 位，中间 `*`
  - 邮箱 → 保留首字符 + `***` + `@域名`
- 映射文件 `anonymization-map.json`（导出根目录）：
  `{"version":1,"generated_at":...,"name_map":{"<原名>":"用户A",...},"note":"删除此文件即不可逆"}`
  keepMapping=false 时写文件→导出完成后删除。
- 顺序：过滤（§4）→ 脱敏（§3）→ 索引（§1）→ 报告/日历（§5/§6）。
  即脱敏后产物入索引与进报告，报告里也看不到真名。
- UI：设置卡片「脱敏导出」三个开关；导出摘要行提示「已脱敏（映射文件在根目录）」或
  「已脱敏（不可逆，映射已销毁）」。

## 4. 过滤导出（P1-B）
- 语义：export.filter.enabled 时，所有消息级处理只保留
  `fromDate ≤ 消息日期 ≤ toDate` 且（keywords 为空 或 content 命中任一关键词，
  不区分大小写）的消息。
- 实现：在「生成文本产物之后、其他产物之前」对 chat.json 做行级过滤并重写
  chat.txt / chat.csv（保持一致）；HTML 类产物从过滤后的 json 生成。
- 媒体剪枝（尽力而为）：被删消息引用的媒体文件从产物中删除；未引用的保留。
- 导出摘要行提示：「过滤后保留 X / Y 条（区间 .. ~ ..，关键词 n 个）」。
- 过滤+脱敏同时开：先过滤后脱敏（§3 顺序）。

## 5. 年度报告（P2-A）
产物：导出根目录 `年度报告_<YYYY>.html`（YYYY=按消息时间戳取覆盖的最大年份；
无时间戳则取生成年）。单文件、纯内嵌 CSS、无外部依赖、暗色科技风（与统计报告同
主题：--bg #0b1026 / --cyan #00f5ff / --purple #7b61ff），含水印层（若开）。
数据来源：扫描导出根目录所有会话的 chat.json（或 wx-cli json 目录），聚合：
- 概览卡：会话数 / 消息总数 / 媒体总数 / 活跃天数（出现过消息的 distinct 日期数）/ 峰值月份
- 月度消息量柱状图（12 列或按数据）
- 月度×星期 热力图（5 列行=周一~周日，12 列月，CSS 网格，深浅=当月该星期消息占比）
- 词频 Top 30：拉丁按单词切分、CJK 按 bigram 切分，去停用词（的了我你是在等有等），
  条形展示
- 跨会话发言排行 Top 10（条形）
- 24 小时活跃分布（柱状）
- 全部数据内嵌为 JSON 供页面交互；离线可打开。

## 6. 日历提取（P2-B）
产物：导出根目录 `日历事件.json` + `日历事件.ics`。
- 提取规则（启发式，基于每条消息的 timestamp 做相对解析）：
  - 绝对：`YYYY-MM-DD` / `YYYY/MM/DD` / `M月D日`（默认当年；若 < 消息月份则 +1 年）
  - 相对：`明天/后天/大后天`、`周X/星期X`（取最近的未来那一天）、`下周一~日`
  - 时间：`上午/早上 N点`（N 点）、`下午 N点`（N+12，N<12）、`晚上 N点`（N+12）；
    `N点` 裸值按字面；只有日期无时间 → 09:00 默认。
  - 事件时长默认 60 分钟。
  - 每条事件：`{session, message_ts, summary(≤60字消息摘要), start("YYYY-MM-DD HH:MM"), 
    end, raw(原句)}`。
- .ics 格式：VCALENDAR 2.0 / PRODID=-//WeChatExporter//CN / CALSCALE GREGORIAN /
  TZID Asia/Shanghai（X-WR-TIMEZONE）；每个事件 VEVENT：UID=sha1(session|ts|start)@wce、
  DTSTAMP=now UTC、DTSTART/DTEND 带 TZID、SUMMARY=「[会话名] 摘要」；CRLF 换行。
- UI：开关 + 「打开日历文件」按钮；导出摘要行「日历事件 N 条」。

## 7. CLI 无头接口（三端同名参数；macOS/Windows 复用 GUI 可执行文件，
Linux 由 Tauri 内置 wce CLI）
```
wce --auto-sync                     # 跑一次定时增量（读设置）
wce search <kw> [--dir <导出根>]    # 无头搜索，stdout 打印前 20 条
wce index [--dir <导出根>]          # 重建搜索索引（不导出）
wce report [--dir <导出根>]         # 重生成年度报告+日历（不导出）
wce --version / wce --help
```
- 有 GUI 参数的调用不变；检测到 `wce` 子命令即走无头分支，不启动 UI。
- 退出码：0 成功；2 参数/文件错误；1 运行失败。

## 8. 平台差异（允许）
- 数据源：macOS/Windows 用 wx-cli（内置二进制）+ 原生解密双后端（现状）；
  Linux 无 wx-cli，后端=「用户指定已解密 SQLite 目录」（与 macOS native 后端同构：
  contact.db + message*.db，表名 Msg_<md5(会话id)>，列 message_content/compress_content，
  Name2Id 表解析发送者——与 macOS ChatExporter 完全同口径）。
- 定时安装器：launchd / schtasks / systemd user（§2），UI 统一「安装/卸载定时任务」
  按钮 + 状态行。
- Linux PDF 文档版：生成打印版 HTML（Linux 无原生 PDF 渲染管线，UI 标注「打印版」）。
- 语音转文字/图片 OCR：三端均为「有工具才做」的可选增强（Linux 默认跳过，
  允许外部 whisper 二进制路径设置）。

## 9. 验收（每功能三端各一条）
1. 导出含 ≥3 会话数据 → 根目录出现 wce-search.sqlite，App 面板搜「关键词」出结果可跳转；`wce search` 有 stdout。
2. 装定时任务（60 分钟或 5 分钟试）→ 日志出现运行行；增量游标推进；无新增时 "no-change"。
3. 开脱敏导出 → 产物中无原始昵称，anonymization-map.json 存在（或销毁提示）；手机号为 138****5678 形。
4. 过滤（区间+关键词）→ 产物条数=保留数，摘要行显示 X/Y。
5. 年度报告 HTML 离线打开：热力图/词频/排行渲染正常。
6. 日历 .ics 可导入系统日历，事件时间在消息时间 +1 年规则正确。
