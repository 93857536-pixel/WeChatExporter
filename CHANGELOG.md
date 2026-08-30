# Changelog

All notable changes to this project are documented in this file.

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
