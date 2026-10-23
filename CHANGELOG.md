# Changelog

All notable changes to this project are documented in this file.

## [2.21.3] - 2026-10-22

### Fixed（三端复审 + 主会话自查，2 轮深度代码审计后的剩余项）

**安全（high）**
- 🔴 **macOS AutoSyncScheduler shell 注入**：`run()` 把 launchctl 参数数组
  `joined(" ")` 后经 `/bin/sh -c` 执行；导出目录/联系人 JSON 等用户可控值若含
  `; $ ` |` 等 shell 元字符即任意命令执行。修法：直接 exec（第一个参数按
  PATH 解析为绝对可执行文件，其余参数原样传 array），完全不经 shell。
- 🔴 **Windows .wxenc 解密 zip-slip**：`EncryptedExport.DecryptFile` 对 blob 内
  条目路径只做 `Path.Combine`，`../evil` 会越出目标目录写任意位置。
  修法：`Path.GetFullPath` 后校验以目标目录为前缀，否则抛异常。
- 🔴 **macOS .wxenc 解密 zip-slip（主会话自查补漏）**：Swift 版
  `EncryptedExport.decryptFile` 与 C# 同型缺陷（上轮只修了 Rust），
  同样加 `standardizedFileURL` 前缀校验。

**稳定性/数据（med）**
- 🟠 **macOS UpdateService 误删父目录**：`clearPendingInstall` 删的是
  待安装 .app 的父目录（pending-update-<version>/）而非 .app 本身，
  语义过激且与 prepareSilentUpdate 的整目录清理重复。改为只删 .app。
- 🟠 **macOS 云备份取消后状态不一致**：上传/下载 Task 被用户停止后
  仍调 `refresh()` 刷新文件列表（进度条已隐藏）。加 `Task.isCancelled` 守卫。
- 🟠 **macOS 云备份加密产物 0 字节假成功**：`encryptDirectory` 用
  `try?` 读 size 得 0 后继续上传空文件且报「提交完成」。改为属性读取
  失败即抛错、size=0 抛错并清理临时文件。
- 🟠 **Windows HeadlessCli 自动同步阻塞死锁隐患**：`RunAutoSync` 在
  `OnStartup` 早于 WPF 安装同步上下文的阶段调用 async 方法
  `.GetAwaiter().GetResult()`，当前路径不可复现，但若将来调用点移到
  已安装 SynchronizationContext 的环境（UI 线程/Dispatcher）即死锁。
  修法：阻塞段前显式 `SetSynchronizationContext(null)`（finally 还原），
  async 续体落线程池，阻塞调用永久安全。

**健壮性（low）**
- ⚪ **macOS 单文件导出 media 相对路径**：`mediaRoot.path + "/"` 字符串前缀
  匹配在末尾无斜杠的构造方式下算错 rel → 图片 404。改用 URL 标准化前缀差。
- ⚪ **macOS ExportMode 大小写静默回退**：UserDefaults 存入 `"ALL"`/
  `"Categorized"` 等异常值时静默回退 `.categorized`。统一小写匹配。
- ⚪ **macOS wx-cli 子进程继承全量环境变量**（WxCliService + DatImageDecoder
  两处）：父进程代理变量（HTTP_PROXY 等）可能干扰 wx-cli 密钥/缓存定位。
  只传 PATH/HOME。
- ⚪ **macOS DatImageDecoder 静默吞错**：wx-cli 解码失败不回传 stderr/
  启动异常。补日志（退出码 + stderr 文本）。

- 版本号：6 处 → 2.21.3（macOS APP_VERSION / Win csproj / Linux Cargo.toml +
  tauri.conf.json + package.json）

## [2.21.2] - 2026-10-21

### Fixed（三端全量审计修复，macOS/Windows/Linux）

**数据丢失（high）**
- 🔴 **增量导出覆盖历史会话**：`FilterArtifacts` 把临时 chat.json 重写为「仅增量」子集后，
  `CopyTextArtifacts` 以 File.Delete+Copy 覆盖 base 会话目录 → 第二次 auto-sync 起该会话
  只剩本轮增量、历史丢失（下游全文搜索/统计/年报/日历全基于残缺数据）。
  修法：新增无副作用的 `HasIncremental` 评估（Win/mac），4 个调用点（Win GUI + Win auto-sync +
  mac GUI×2 + mac auto-sync）改「先判后写」——无增量直接跳过，base 历史产物永不被覆盖。
- 🔴 **Linux .wxenc 解密路径穿越（zip-slip，high）**：条目路径来自加密文件内容（不可信输入），
  `../../x` 或绝对路径可越界写任意文件（潜在 RCE）。修法：拒绝 `..` 段/绝对路径 +
  canonicalize 后校验仍在目标目录内 + 越界条目跳过并记日志；补 `path_traversal_rejected` 回归测试。

**功能失效（med）**
- **FTS5 中文搜索必空（Win/mac）**：建表无 `tokenize='trigram'`（Linux 已有，跨端分歧），
  unicode61 默认分词把连续 CJK 当一个 token，短语 MATCH 不中。修法：Win/mac 建表对齐 trigram。
- **毫秒时间戳丢失（Win ChatStatsReport / SearchIndex 入库）**：`GetInt` 用 `TryGetInt32`，
  13 位毫秒全 null → 时间维度统计整列为空；入库未归一 → 搜索时间显示「约 5 万年后」。
  修法：Int64 + `>100_000_000_000 → /1000` 毫秒归一（与 mac `dateFromTimestamp` 同口径）。
- **schtasks /TR 双引号叠加（Win）**：`""exe" wce --auto-sync"` 嵌套后 CommandLineToArgvW
  把 `""` 当转义引号，路径含空格必中（任务建失败或丢参数）。修法：内层引号反斜杠转义 +
  安装后 `schtasks /Query /XML` 回读校验。
- **encrypturl 被当明文 URL（Win/mac）**：候选链含 encrypturl 时主 fetch 拿到密文（非 null），
  `data is null` 的 AES 解密兜底永不触发 → 加密图静默下载失败。修法：明文候选链移除 encrypturl，
  只走加密通道。
- **Linux auto-sync 数据源错键**：`run_auto_sync` 从不读 `settings.export.data_dir`，
  回退到 `last_dir`（实为导出输出目录，无 session.db）→ 定时任务永远报「会话数据库不存在」。
  修法：优先级 WCE_DATA_DIR 环境变量 → data_dir → last_dir。
- **Linux 定时任务假成功**：`install_timer` 吞掉 systemctl 失败（非 systemd 发行版照样报「已安装」），
  且 auto-sync.enabled 无入口置 true（enabled 永 false，定时器空转）。修法：校验 systemctl 返回码 +
  安装时同步开 enabled / 卸载时关，失败如实报错。

**正确性（low）**
- **日历非法日期崩溃（Win）**：`ParseDay` 只校验 `dy<=31`，`new DateTime(4月,31日)` 抛异常且行循环无
  try/catch → `wce report` / auto-sync 整条管线崩。修法：`ValidDay`（闰年感知，对齐 mac Foundation
  Calendar）+ 行级 try/catch；mac/Linux 同步对齐口径（Linux 结束时间 23 点 +1h 不再产生 24:xx 非法 ICS）。
- **ICS 属性未转义 + 无 75 字节行折叠（Win/mac）**：SUMMARY/DESCRIPTION 的 `; , \ 换行`未转义、
  裸 LF、长行不折叠 → 不合规 ICS 多数客户端解析失败。修法：`IcsEscape` + `FoldIcsLine`（UTF-8 75 octet）。
- **过滤 0 命中保留全量产物（Win/mac，隐私）**：无命中时 early-return 不写盘，用户期望过滤掉的
  完整聊天记录原样留在导出目录。修法：0 命中写空产物。
- **LIKE 降级 `%/_` 未转义（Win/mac）**：搜 `100%` / `a_b` 时通配符失控。修法：ESCAPE 子句 + 转义。
- **`wce report` 空结果退 1（Win/mac）**：目录无数据 / 日历 0 事件（都属正常）被当失败。
  修法：无数据=正常退 0，仅「有数据但年报写失败」退 1。
- **游标写非原子（Win）**：auto-sync 与 GUI 并发时读-改-写互相覆盖。修法：进程锁 + tmp 原子重命名。
- **DiagnosticUploader 版本硬编码 2.14.0（Win）**：改为读程序集版本（随构建自动同步）。
- **VoiceTranscriber 管道死锁 + 模型半成品误判（Win）**：先读 stdout 再读 stderr（whisper-cli
  stderr 填满 4KB 管道互卡）；模型下载中断残留的几 MB 残片下次被「已存在」误判。修法：双路并行
  异步读 + `.part` 下载 + 50MB 下限校验后才落正式名。
- **Linux 小项**：Name2Id `query` 路径 panic 改容错；FTS5 降级时 DELETE batch 半途失败导致
  旧索引累积（两条 DELETE 独立执行）。

### Version / Sync
- 版本号：Win csproj + mac build_app.sh + CHANGELOG → 2.21.2（build 37）
- Linux 三处（Cargo.toml / tauri.conf.json / package.json）从 2.19.2 对齐到 2.21.2
  （v2.19.3–v2.21.1 发版时 Linux 端版本一直未随主版本同步，本次补上；
  后续发版三处需与 AGENTS.md 版本同步清单一起改）

### 验证
- macOS `swift build -c release`：0 错
- Windows `dotnet build -c Release`（EnableWindowsTargeting）：0 错
- Linux `cargo test`：23 通过（含新 `path_traversal_rejected` zip-slip 回归测试）
- 已知边界：macOS/Windows 侧修复经编译 + 行为断言覆盖；真实微信端到端（密钥提取→解密→导出）
  仍依赖真实用户实测反馈（#42/#43 同类，无法在无微信环境复现）

## [2.21.1] - 2026-10-20


### Fixed
- **🔴 Windows「准备数据」卡在 30% / 无法解密 session.db（#42，微信 4.1.11.55）**：
  当内置 wx-cli 无法从微信进程内存提取到密钥时，`init` 会「假成功」（读到旧 config 就报已初始化），
  随后 `PrepareDataAsync` 直接跳到「数据准备完成」，加载会话时 `sessions` 命令挂满 300 秒超时、
  UI 冻在 30%。现在**新初始化路径末尾追加一次真实读取探测（`sessions -n 1`）**，
  确认保存的密钥确实能解开数据库；校验失败时抛出带可操作指引的明确异常（彻底退出微信→管理员重开→重新登录→重试），
  不再让流程"静默通过"。同时改进内存扫描 0 匹配时的日志，逐项列出排查步骤（登录态/管理员/升级微信后重登/更新版本）。
- **🔴 macOS 微信 4.1.15 下 LLDB 捕获超时 / task_for_pid 失败，密钥提取无可用诊断（#43）**：
  `key extract` 失败时此前只把原始错误抛回，用户看到 `task_for_pid failed (kern_return=5)` 或
  `LLDB capture timed out` 不知道该查什么。现在针对三类失败分别给出可操作诊断：
  - `task_for_pid` / `kern_return` → 依次核对 SIP / `DevToolsSecurity -enable` / `_developer` 组 / 管理员运行；
  - `LLDB capture timed out` / `did you log in` → 确认已在弹出的登录框完成登录、微信保持前台、新版微信符号可能已变化；
  - `no key for account` / `NoPbkdfCalls` → 确认该账号在 Mac 上有本地聊天记录（云端未同步的账号无法提本地密钥）。

## [2.21.0] - 2026-10-17

### Fixed
- **🔴 Intel Mac 上无法导出：内置 wx-cli 实为 arm64 单架构，报"CPU 类型不正确"（#41）**：
  仓库 `vendor/macos/wx-cli` 在 v2.20.0 里实际是 **arm64 单架构**（Mach-O cputype=0x0100000C），
  Intel 芯片无法执行，点「准备数据」/导出时抛「无法启动 wx-cli：可执行文件中的CPU类型不正确」。
  根因是当时内置的 wx-cli 只编译了 Apple Silicon 切片。现升级内置 wx-cli 为 **universal（x86_64 + arm64 双切片）**：
  - 上游 `pandorafuture/wx-cli` 现为开源 Rust 项目，本机分别以 `--target x86_64-apple-darwin` 与 arm64 交叉编译后 `lipo` 合成双架构二进制替换 vendor 副本；
  - `build_app.sh` 产物校验与 `ci.yml` / `release.yml` 均新增「内置 wx-cli 必须是 universal」的 `lipo -archs` 双重切片校验，杜绝单架构回归；
  - App 启动时检测内置/自选 wx-cli 的 CPU 架构，与当前系统不匹配时不再静默，而是打印人话提示并自动回退到内置原生解密后端（LLDB 密钥捕获）。
  - 同步修正 `vendor/README.md` 与 UI/文档中「仅 x86_64 / 支持 4.1.7–4.1.11」的过时描述。

### Changed
- 内置 wx-cli 升级到上游主线（`v0.7.4` 起，已移除固定版本 allowlist）：密钥提取现支持 **微信 4.1.7 及以上**（含 4.1.12/4.1.13 等新版），macOS 端不再受 4.1.11 上限约束。

## [2.20.0] - 2026-10-05

### Added
- **云端 E2EE 备份（双端，Windows WPF + macOS SwiftUI）**：App 设置页新增「云备份」卡——登录后自动上传/管理/下载加密备份（密码由用户本地输入，服务器永不接触明文），支持分块大文件传输、配额管理（单用户默认 1GB）、同名覆盖与 skip 去重；后端服务 `wce.linminhao.top/api/backup` 已部署上线

## [2.19.3] - 2026-10-05

### Fixed
- **🔴 Windows 准备数据时窗口「未响应」、进度冻在 8%（#39，微信 4.1.15.13 用户实测）**：微信版本过新时内置 wx-cli 提不到密钥，应用层兜底链路上的重活（数据目录全盘扫描、微信进程内存模式扫描 + 候选密钥校验、逐库 PBKDF2-SHA512 密钥派生、逐库全量解密、超大 JSON 解析）全部**同步跑在 UI 线程** → 分钟级吃满 → 窗口冻结成「未响应」，进度停在 Warmup 起步值 8%，连关闭按钮都点不动。现在这些环节全部下沉线程池执行，窗口保持可交互；逐库解密时显示「解密数据库 N/M」进度日志。
- **长任务支持「取消」**：准备数据 / 刷新 / 导出进行中，工具栏出现「取消」按钮，点击后后台线程快速中止、UI 恢复可交互（不再只能杀进程）。
- 导出尾部的后处理管线（HTML 单文件生成 / 统计报告 / EPUB / 语音转写 / OCR / 索引 / 脱敏 / 年报 / 水印 / 整体加密）与「解密导出」同样下沉线程池，大数据量导出时窗口不再卡顿。
- **macOS 同款隐患**：native 后端的逐库 PBKDF2 密钥派生 + 全量解密、会话列表加载（SQLite 全量查询）、wx-cli 缓存同步（quick_check + 拷贝）此前跑在主线程，大数据量时同样会冻 UI，现下沉后台线程。

## [2.19.2] - 2026-09-29

### Fixed
- **🔴 加密导出会把产物和原有数据一起删掉（Windows + macOS，影响 v2.17.0 起所有版本）**：导出时填了密码的情况下，归档 `.wxenc` 被写在导出根目录**内部**，紧接着的「删除明文目录」递归删除把归档连同全部明文（含该目录里以前的导出结果）一起删掉了——用户既拿不到加密包、又丢掉原有数据，界面却提示「已加密为 …」。现在：
  - 归档写到导出根目录**之外**（同级 `导出目录名.wxenc`，重名自动加时间戳），再无被自己删除的可能；
  - **删除明文前做完整性校验**（解密归档并比对文件条目数），校验不过则保留明文并明确报错，绝不让用户两头空；
  - 导出目录为磁盘根目录时拒绝执行（防误删整盘）；
  - 提示与日志改为指向真实存在的归档路径。
- **🔴 脱敏导出可能静默失效（Windows）**：写回判定用的是「文本长度是否变化」，而 3 字姓名（如「张三丰」→「用户A」）与手机号/身份证掩码都是**等长替换**，长度不变 → 文件不写回 → 产物里保留真实姓名与手机号，日志却显示「脱敏完成」。现改为按**内容是否变化**判定（与 macOS 端一致），并补充回归测试。
- **单文件导出的「时间」列可能整列为空（Windows）**：时间戳解析用 `TryGetInt32`，毫秒级时间戳（约 1.7e12，13 位）与 2038 年后的秒级值都超出 Int32 而静默丢弃 → 时间列为空。现改用 Int64 并自动识别毫秒（与 `WxCliService.FormatTime` 同口径）；macOS 端同步补齐毫秒归一。

## [2.19.1] - 2026-09-29

### Fixed
- **Windows：微信升级后「无法解密 session.db」死循环（#38）**：wx-cli 的 `init` 只要读到 `config.json` / `all_keys.json` 就会报「已初始化」，密钥与数据库不匹配时（微信升级 / 重装 / 换号导致 rawKey 轮换）不报错，直到 `sessions` / `export` 才失败并输出「错误: 无法解密 &lt;db&gt;」。旧版此时只会把错误抛给用户，而「准备数据」又走同一条缓存路径（继续用那份失效密钥），于是「准备数据 → 无法解密」无限空转、无法自愈。现在：
  - 「准备数据」在缓存路径上追加**真实读取探测**（`sessions --json -n 1`），探测到「无法解密」即判定缓存密钥失效，自动清除 `all_keys.json` / `config.json` 里的 `keys_file`·`your_wxid` 并重新完整初始化（`init --force` → 数据目录检测 → 应用层内存密钥提取兜底）。
  - 启动自动加载会话命中「无法解密」时**自动自愈**：清失效密钥 → 重扫 → 重试一次（无需用户手动操作）。
  - 自愈后仍失败时抛出**带排查指引的明确原因**（微信版本过新 / 未登录 / 未以管理员身份运行），不再让用户反复空转。
  - 自动加载失败时的提示不再误导为「首次使用请点击准备数据」（该场景数据已就绪、只是密钥失效）。
  - 探测/自愈均只针对「无法解密」标记，健康缓存与 #33 零密钥判定行为不变（回归测试覆盖）。

## [2.19.0] - 2026-09-26（进行中）

### Added
- **全文搜索（P0）**：导出时生成 `wce-search.sqlite`（FTS5，不可用时自动降级 LIKE）；App 工具栏新增「搜索」面板（命中结果按时间倒序、可跳转对应聊天记录）；无头 CLI `wce search <kw>` / `wce index`
- **定时增量导出（P0）**：macOS launchd / Windows schtasks / Linux systemd user timer 一键安装/卸载，每 N 分钟无人值守增量同步（无新增静默）；无头 `wce --auto-sync`
- **脱敏导出（P1）**：名称代号化（用户A/B/…确定性映射）+ PII 模糊化（手机号 138\*\*\*\*5678 / 身份证保头6尾2 / 邮箱首字符+\*\*\*@域名）；映射文件 `anonymization-map.json`（可保留或销毁，销毁即不可逆）
- **过滤导出（P1）**：时间区间 + 关键词过滤，过滤先于脱敏/索引/报告，所有生成物基于过滤后数据；摘要行提示保留 X/Y 条
- **年度报告（P2）**：`年度报告_YYYY.html` 单文件暗色科技风——概览卡、月度柱状、月×星期热力图、词频 Top30（CJK bigram+拉丁分词）、跨会话发言排行、24 小时分布
- **日历提取（P2）**：启发式识别「明天/周X/M月D日/下午N点」等约定，生成 `日历事件.json` + `日历事件.ics`（TZID=Asia/Shanghai，默认 60 分钟）
- **Linux 端（新平台）**：Tauri v2 + Rust，深色科技风 UI（霓虹青 #00f5ff 与 HTML 报告同主题）；功能与 macOS/Windows 对齐（数据源 = 用户指定已解密 SQLite 目录，与 macOS native 后端同口径）
- 无头 CLI 统一三端：`wce --auto-sync / search / index / report / --version / --help`
- 设置项（三端同名键）：`export.searchIndex / autoSync.* / anon.* / filter.* / annualReport / calendarExtract`

### 说明
- 顺序管线（SPEC §3）：过滤 → 脱敏 → 搜索索引 → 年报/日历 → 水印兜底 → 加密导出
- 详细契约见 `docs/MULTIPLATFORM_SPEC.md`

## [2.18.0] - 2026-09-26

### Added
- **导出水印（双平台，默认开）**：导出产物支持平铺视觉水印，可开关、水印文字可自定义（默认「林琝淏科技集团有限公司」，设置面板可改）。HTML 产物（单文件 / 统计 / 目录 / 表情包画廊）平铺斜纹水印 + 页脚版权行；EPUB 加版权页脚；文档版（macOS PDF 每页对角水印 / Windows 打印版 HTML 平铺深色水印）。关闭开关即无水印版本。实现：macOS 纯 CryptoKit 外的标准库 SVG data-URI，Windows 纯 BCL，零第三方依赖；导出流程含幂等兜底扫描（缺水印层的 HTML 自动补注入），双端行为一致
- 持久化：macOS UserDefaults（`export.watermarkEnabled` / `export.watermarkText`），Windows settings.json（与诊断日志同意状态同目录，保留其他字段）

## [2.17.0] - 2026-09-26

### Changed
- **Universal 双芯片构建（P2-1）**：macOS 资产改为 universal（x86_64 + arm64），Intel 芯片原生运行、Apple Silicon 原生运行（内置 wx-cli 为 x86_64 单架构，Apple Silicon 上经 Rosetta 透明执行）；资产改名 `WeChatExporter-macOS-universal.dmg/.zip`，应用内自动更新通道不受影响
- **服务器监控拆出独立仓（P2-3）**：iOS Monitor App（`ios/WeChatExporterMonitor/`）、服务器端脚本（`scripts/` 中 5 个 monitor 脚本）与部署/契约文档迁至私有仓 `93857536-pixel/WeChatExporterMonitor`，本仓 `DiagnosticUploader` 上传协议保持兼容

### Added
- **加密导出（P2-2，双平台，默认关）**：设置中填写导出密码后，导出目录整体打包加密为单个 `.wxenc` 文件（PBKDF2-SHA256 100k 轮派生密钥 + AES-256-GCM 认证加密，自实现格式、零第三方依赖），明文目录随即删除；macOS / Windows 双端互通，凭密码解密还原完整目录，全程离线。实现：macOS 纯 CryptoKit（自写 PBKDF2-HMAC-SHA256），Windows 纯 BCL（AesGcm + Rfc2898DeriveBytes）；双端字节级互通实测通过（含错误密码正确拦截）

## [2.16.0] - 2026-09-26

### Added
- **电子书 / 文档版导出（双平台）**：导出时本地聚合 `chat.json` 直接生成阅读版文档，不依赖 HTML、零第三方依赖、全程离线
  - **EPUB 电子书（双平台）**：`联系人_聊天记录.epub`，自实现 stored-ZIP 按 EPUB 3.0 规范打包（mimetype stored 首条目），按月分节 + 发言人/时间戳，可用系统 / 第三方阅读器打开
  - **文档版（macOS PDF / Windows 打印版 HTML）**：A4 排版白底打印版，macOS 用 CGPDFContext + CoreText（PingFang SC 中文渲染）生成 PDF，Windows 生成 A4 @page 打印优化 HTML（浏览器打印 / 另存 PDF，零 UI 线程、离线）；可打印 / 分享
  - 设置页「电子书 / 文档版」两个开关（默认开）；导出摘要列出生成文件
  - 双端字段解析与 WxCliService / ChatStatsReport 一致（create_time/timestamp 毫秒秒自适应、嵌套 message/source 行兼容）

### Notes
- 双端编译验证：macOS `swift build` 0 错 + Windows `dotnet build -p:EnableWindowsTargeting=true` 0 警告 0 错；EPUB ZIP 结构与 PDF/XPS 生成经独立 smoke test 全过

## [2.15.0] - 2026-09-26

### Added
- **语音转文字（双平台，本地离线）**：导出媒体时自动转写语音消息，结果保存为 `.transcript.txt` 侧车并在单文件 HTML 中折叠展示
  - 自研 SILK 解码器（`vendor/tools/silk/silk2wav`，macOS universal + Windows exe）随安装包内置，`.silk` 语音先转 WAV 再转写
  - macOS 与 Windows 均调用 whisper.cpp（`whisper-cli`）本地转写，全程离线；缺少 whisper.cpp / 模型时自动跳过，不影响导出
  - 设置页「语音转文字」开关（默认开）；Windows 设置页提供「下载 whisper 模型」一键按钮
- **图片 OCR（双平台，本地离线）**：导出媒体时对图片做本地离线文字识别，结果保存为 `.ocr.txt` 侧车并在 HTML 中折叠展示
  - macOS 用系统 Vision 框架（zh-Hans / zh-Hant / en-US，离线）；Windows 用系统 Media OCR（Win10/11 内置）
  - 设置页「图片 OCR」开关（默认开）
- **聊天统计报告（双平台）**：导出时本地聚合 `chat.json` 生成单文件 HTML 统计报告（消息总量、发言排行、24 小时活跃分布、月度趋势、媒体构成），无外部依赖，可离线打开；设置页「统计报告」开关（默认开）
- **增量导出（双平台，默认关）**：按「联系人 + 导出目录」记忆时间戳游标，开启后每次导出只保留上次之后的新增消息；无新增的会话自动跳过并提示；游标存于应用数据目录，更换导出目录保留各自独立记录
- **目录导航页 + 全文检索（双平台）**：导出后在导出目录生成 `index.html`，含文件列表导航 + 关键词全文检索框（内嵌文本数据，单文件 200KB 截断，可离线打开）；设置页「目录导航页」开关（默认开）
- **用户自带 wx-cli（回应 #30）**：设置页新增「wx-cli 设置」，可填写自定义 wx-cli 绝对路径（含自行编译的上游新版或 fork）；留空则用内置版，路径不可执行时自动回退内置。macOS 侧生效；Windows 内置 wx.exe 仍随包分发
- README 功能清单 / 兼容矩阵 / 发版前微信版本验证流程更新

### Notes
- 语音转写与图片 OCR 为「可选增强」：关闭或工具缺失时全部导出功能不受影响
- 双端编译验证：macOS `swift build` 0 错 + Windows `dotnet build -p:EnableWindowsTargeting=true` 0 警告 0 错；统计 / 增量 / 索引逻辑经独立 smoke test 全过

## [2.14.0] - 2026-08-30

### Added
- **iOS 监控 App「WeChatExporter Monitor」(ios/WeChatExporterMonitor/)**：原生 SwiftUI，4 个 Tab（概览/报错日志/修复进度/Hermes），通过 https://linminhao.top/api/* 实时查看服务器运行状态（CPU/内存/磁盘/6 服务指示灯）、诊断日志处理进度、Hermes 修复活动与配置
- **服务器监控 API（scripts/monitor-api.js → 127.0.0.1:8083）**：GET /api/status /api/logs /api/logs/:id /api/hermes，经 CF Tunnel /api/* 公网可达，x-diag-token 鉴权；计划任务自启 + 看门狗覆盖
- **诊断日志自动上传（双平台）**：首次启动弹「诊断日志上传」条款窗，用户明确同意后，导出/准备数据/加载会话报错时自动静默上传技术诊断信息（应用版本、操作系统版本、错误消息、运行日志尾部）到开发者服务器，用于自动分析并修复问题
  - 不同意则任何情况下都不上传任何数据，应用功能完全不受影响；设置里可随时更改
  - 上传内容仅含技术诊断数据，不包含聊天内容、联系人信息、账号信息或任何个人隐私数据
  - 上传经 Cloudflare Tunnel 443 加密传输，超时 5 秒，失败静默不打扰用户

## [2.13.4] - 2026-08-29

### Fixed
- **Windows 使用时报「wx-daemon 启动超时（>Ns）」无法继续**：
  - 新增 wx-daemon 启动失败自动恢复：检测到闭源 wx.exe 内部报「wx-daemon 启动超时」或「无法启动 daemon 进程」时，自动执行 `wx daemon stop` + 清理 `%APPDATA%\Tencent\xwechat\config\` 下的残留 daemon.pid / daemon.sock，等待管道释放后自动重试一次（覆盖残留状态、杀毒软件拦截、预热慢等常见原因）
  - 修复 daemon 状态误判：wx.exe 的 `daemon status` 输出为中文（「wx-daemon 运行中 / 未运行」），旧代码用 Contains("ready"/"running") 判断对真实输出永远为 false，导致每次准备数据都强制重新 init（反复触发 daemon 拉起）；现改为中文「运行中」+ 英文兼容判断
  - 失败时错误消息自动附上 `%APPDATA%\Tencent\xwechat\config\daemon.log` 尾部内容（最近 12 行），用户可直接看到 daemon 启动失败的真实原因

## [2.13.3] - 2026-08-28

### Fixed
- **Windows 导出报错「The requested operation requires an element of type 'Number', but the target element has type String」（#34）**：
  - 导出表情包时查询 emoticon.db 使用类型安全的读取（GetValue + 转换），兼容微信不同版本中同一列声明为 TEXT / INTEGER / REAL / BLOB 的情况，不再因列类型与预期不符而中断导出
- **Windows 微信 4.1.12+「准备数据」卡在 8% 不动、界面无响应（#35）**：
  - wx-cli 全部命令增加超时保护（init 240s / sessions 300s / export 600s）：wx-cli 对部分微信版本挂起时自动终止进程，并自动切换应用层数据目录检测 + 内存密钥提取兜底，不再无限等待
  - 日志与进度刷新改为异步批量派发（单帧最多 100 行），wx-cli 高频输出时窗口保持可响应，不再冻结

## [2.13.2] - 2026-08-25

### Fixed
- **Windows 微信 4.1.13.7 无法解密（报「成功提取 0 个数据库密钥 / 无法加载 session.db」）**：
  - 修复 wx-cli 在「提取到 0 个数据库密钥」时仍返回成功（退出码 0）的误判：`init` 后解析输出，检测到 0 密钥立即切换应用层数据目录检测 + 内存密钥提取兜底，不再带着空密钥继续导致 session.db 加载失败
  - 程序启动时自动请求管理员权限（UAC，manifest `requireAdministrator`），确保能以管理员权限读取 Weixin.exe 进程内存（微信 4.1.12+ 的新进程，旧流程仅扫描 WeChat.exe）
  - 已保存密钥失效（微信重装 / 升级 / 换号导致 rawKey 变化）时自动清除失效密钥并重新完整初始化

## [2.13.1] - 2026-08-23

### Fixed
- **Windows 自动检测微信数据目录失败（微信 4.1.13+ 报「未能自动检测到微信数据目录 / 找不到 config.json」）**：
  - 应用层新增微信数据目录自动检测：默认 Documents、OneDrive 重定向、注册表真实 Documents、微信旧版注册表、全盘扫描（深度 ≤3）
  - 检测到目录后自动写入 `%USERPROFILE%\.wx-cli\config.json` 的 `db_dir`，并以 `init --force --data-dir` 重试
  - 自动检测仍失败时，应用会询问并支持手动选择微信数据目录（含 db_storage 的账号目录）
- **Windows 微信 4.1.12+ 密钥提取失败（报「成功提取 0 个数据库密钥 / 无法解密 session.db」）**：
  - 应用层新增微信 4.x 密钥提取器：扫描 Weixin.exe 进程内存（GetKeyAddrStub 模式 + 设备类型字符串向前扫），用数据库 salt + HMAC-SHA512 真实校验
  - 提取成功后写入 `all_keys.json` 与 config.json（keys_file / your_wxid）并重新初始化
  - wx-cli 仍无法使用外部密钥时，应用层直接解密全部数据库到 `%USERPROFILE%\.wx-cli\cache\<账号>\db_storage` 供读取

### Changed
- Windows 内置 wx-cli 支持范围说明更新：微信 4.1.7–4.1.11 直接支持；4.1.12+ 由应用层密钥提取兜底

## [2.13.0] - 2026-08-06

### Added
- **自然更新体验**：自动更新改为后台静默下载（ZIP，无需挂载 DMG），完成后弹系统通知横幅
  - 点击通知横幅「重启并安装」一键完成更新，不打断当前操作
  - 未点击时，下次启动应用自动应用更新
  - 通知权限未授权时降级为应用内提示

### Changed
- 更新检查优先使用 ZIP 资产（体积小、更快），DMG 仅用于手动下载
- 更新弹窗「下载并安装」改为「下载更新」，下载后经系统通知完成安装

## [2.12.0] - 2026-08-06

### Added
- **导出方式选择**：设置中可选择三种导出方式
  - 分类导出：文字、图片、视频分别归档到独立文件夹
  - 只导出文字：仅导出 txt / json / csv
  - 全部导出：导出全部文字与媒体文件（不生成内嵌 HTML）
- 表情包在含媒体模式下导出到「全部表情包」文件夹

### Changed
- 不再生成媒体 base64 内嵌的单文件 HTML，改为直接输出文件夹结构

## [2.11.0] - 2026-08-06

### Changed
- **设置面板布局重构**：改为 macOS 系统设置风格的「左侧导航 + 右侧内容」双栏布局，导出/更新/关于三个入口清晰切换
- 右侧内容区支持滚动，内容较多时不再挤压截断

## [2.10.1] - 2026-08-06

### Fixed
- **日志面板 JSON 刷屏**：`sessions --format json` 的原始输出不再刷进 UI 日志，只显示有意义的状态信息
- **窗口标题**：主窗口标题从「详情」修正为「微信聊天记录导出」

## [2.10.0] - 2026-08-06

### Added
- **科技感 UI 重设计**：全新青蓝色主题配色、渐变头部卡片、终端风格日志面板
- **统一设置面板**：整合导出/更新/关于三个标签页，独立设置按钮入口
- **更新方式选择**：支持自动更新 / 仅通知 / 手动检查 / 关闭四种模式
- **DevToolsSecurity 自动检测**：SIP 关闭时自动检测并启用 DevToolsSecurity

### Fixed
- 修复 DMG 挂载点解析失败问题（改用 `-mountpoint` 显式指定挂载路径）
- 修复链接按钮参数缺失导致的编译错误

## [2.6.4] - 2026-07-23

### Changed
- **内置 wx-cli**：改为仓库 `vendor/` 随附，构建不再依赖外部 wx-cli GitHub 仓库下载
- macOS 内置 CLI 支持微信 **4.1.7–4.1.11**
- Windows 内置 `wx.exe` 改为使用仓库 vendored 副本（上游 jackwener/wx-cli 因 DMCA 不可用）

### Fixed
- CI/Release 因外部 CLI 下载 404 / DMCA 导致打包失败

## [2.6.3] - 2026-07-23

### Fixed
- 支持微信 **4.1.11**：密钥提取版本白名单扩展至 4.1.7–4.1.11
- 「环境检查未通过」时输出 wx-cli doctor 失败项详情

## [2.6.2] - 2026-07-08

### Added
- **WXGFTranscoder**：自动将微信 `*.wxgf` 图片提取 HEVC 首帧并转码为 JPEG 后嵌入 HTML
- 表情包导出遇到 WXGF 资源时，同样会尝试自动转码

### Fixed
- HTML 导出里 WXGF 图片只显示占位提示、无法直接浏览的问题（macOS 原生解码优先，双平台支持 ffmpeg 回退）

## [2.6.1] - 2026-07-08

### Added
- **ImageExporter**：从聊天 JSON 解析 `<img>` 标签，按 CDN 链接下载图片并写入消息
- **DatImageDecoder**：自动解密 `.dat` 加密图片（优先 wx-cli `decode-image`，失败时 XOR 探测）
- HTML 导出以 `<img>` 内嵌 base64，聊天图片可直接在浏览器中显示

### Fixed
- 勾选媒体导出后仍只显示 `[图片]` 占位、无法看图的问题

## [2.6.0] - 2026-07-08

### Added
- 勾选「同时导出媒体」时额外导出**全部表情包**（收藏表情 + 已下载商店表情），生成独立的 `全部表情包_<时间>.html` 画廊文件
- 从 wx-cli 解密缓存中的 `emoticon.db` 读取 CDN 链接并下载（支持 AES 加密表情）

### Changed
- 导出选项文案明确包含「全部表情包」

## [2.5.1] - 2026-07-08

### Changed
- 单文件 HTML 导出界面美化：深空霓虹 HUD 风格，与 macOS DMG 安装界面视觉一致（玻璃拟态消息卡片、星点/网格背景、青紫霓虹标题与媒体光晕）

## [2.5.0] - 2026-07-08

### Changed
- 每次导出生成**单个 HTML 文件**（图片、表情、音视频以 base64 内嵌），浏览器打开即可查看全部内容
- 不再在导出目录留下 chat.json / media 等分散文件夹

## [2.4.0] - 2026-07-08

### Added
- 勾选「同时导出媒体」时自动下载聊天中的表情/贴纸（GIF/PNG）到 `media/emojis/`
- macOS 导出时向 wx-cli 传递 `--show-emoji`，保留表情详情

### Changed
- 导出选项文案明确包含「表情」

## [2.3.9] - 2026-07-07

### Fixed
- macOS DMG 背景图无法铺满窗口：修正 1x/2x 背景 DPI（72/144）并合并为 Retina TIFF，Finder 不再只显示左上角

## [2.3.8] - 2026-07-07

### Changed
- macOS DMG 安装包界面美化：自定义背景、图标拖拽布局、卷标图标与固定窗口尺寸

## [2.3.7] - 2026-07-06

### Fixed
- macOS 勾选「同时导出媒体」后显示 0 条：wx-cli 实际输出为「联系人_日期.json」，现已正确统计并复制为 chat.json/txt/csv
- 含媒体导出取消 600 秒超时限制，避免大体积导出被中断
- Windows 同步改进 JSON 消息计数（支持 wrapper 格式）

## [2.3.6] - 2026-07-06

### Added
- **Windows**：会话加载与准备数据进度条（先时间预估，完成后显示实际数量）
- **Windows**：取消会话/初始化超时上限，使用 `-n 999999` 拉取全部会话
- **Windows**：未准备数据时跳过启动自动加载

## [2.3.5] - 2026-07-06

### Added
- 会话加载进度条：先时间预估，拿到总量后按「已加载 / 总数」实时更新
- 分页拉取全部会话（每批 500 条），不再受 120 秒超时限制

### Changed
- 准备数据 / 解密过程同样显示进度条
- wx-cli 长时间任务取消固定超时，改为无上限等待

## [2.3.4] - 2026-07-06

### Fixed
- macOS 加载会话列表超时：移除 `--all`（最多 2 万条），改用 `--limit 10000`，超时延长至 5 分钟
- 未准备数据时不再盲目加载会话，避免首次启动长时间卡住
- wx-cli 执行过程实时输出日志，超时时给出更明确的提示

### Changed
- 解密命令超时延长至 10 分钟；会话查询使用 `--no-server` 直连本地缓存

## [2.3.3] - 2026-07-06

### Fixed
- macOS 启动崩溃：修复 wx-cli 在后台线程回调导致 SwiftUI 菜单栏断言失败（SIGABRT）
- 将自动加载会话列表从 `init` 延迟到界面 `onAppear`，避免启动阶段竞态

### Changed
- 全新科技感应用图标（深青渐变 + 导出箭头）
- 构建脚本不再将 PNG 误当作 icns 使用，确保 Dock/Finder 图标尺寸正确

## [2.3.2] - 2026-07-06

### Added
- App icon bundled in repository (`assets/AppIcon.png`)
- README screenshots, badges, English README, CHANGELOG, CONTRIBUTING
- GitHub Issue templates and CI workflow (Swift + .NET build)
- `scripts/prepare_icon.sh` for macOS icns generation

### Changed
- README reorganized with Release-first install instructions
- `install.sh` documents DMG download and optional `CREATE_DMG=1`

## [2.3.1] - 2026-07-06

### Added
- macOS DMG installer (`WeChatExporter-macOS-arm64.dmg`) with drag-to-Applications layout
- `scripts/create_dmg.sh` for local DMG generation

### Changed
- GitHub Releases now publish DMG as the recommended macOS download

## [2.3.0] - 2026-07-06

### Added
- Windows self-contained Release build (no .NET runtime required)
- Optional media export toggle on macOS and Windows
- Readiness status banner in both UIs
- Windows administrator detection and one-click restart as administrator

### Changed
- First launch no longer shows error dialogs when data is not prepared yet
- Improved bootstrap and session loading UX

## [2.2.0] - 2026-07-06

### Added
- Windows WPF application with bundled jackwener/wx-cli
- GitHub Actions automated Release builds for macOS and Windows
- Bundled wx-cli inside macOS app (pandorafuture/wx-cli)

### Changed
- macOS app prefers bundled CLI over system-installed wx-cli

## [2.1.0] - Initial public release

### Added
- Native macOS SwiftUI chat exporter
- TXT / CSV / JSON export
- LLDB key capture and SQLCipher decryption fallback backend
- wx-cli integration for session list and export
