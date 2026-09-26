import SwiftUI

/// 统一设置面板 — 左侧导航 + 右侧内容，macOS 系统设置风格
struct SettingsView: View {
    @ObservedObject var model: AppViewModel

    enum SettingsTab: Int, CaseIterable, Identifiable {
        case export = 0, update = 1, about = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .export: return "导出"
            case .update: return "更新"
            case .about: return "关于"
            }
        }

        var icon: String {
            switch self {
            case .export: return "square.and.arrow.down.fill"
            case .update: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 680, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.headerGradient)
                    .frame(width: 34, height: 34)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            Text("设置")
                .font(.title3.weight(.bold))
            Spacer()
            Button("完成") {
                model.showSettings = false
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sidebar

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: model.settingsTab) ?? .export
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.settingsTab = tab.rawValue
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20)
                        Text(tab.title)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? AppTheme.accentSoft : Color.clear)
                    )
                    .foregroundStyle(isSelected ? AppTheme.accent : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedTab {
                case .export:
                    ExportSettingsTab(model: model)
                case .update:
                    UpdateSettingsTab(model: model)
                case .about:
                    AboutTab(model: model)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selectedTab)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.subtleText)
            Text("WeChatExporter v\(model.currentVersion) (\(model.currentBuild))")
                .font(AppTheme.monoFontSm)
                .foregroundStyle(AppTheme.subtleText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

// MARK: - 导出设置

private struct ExportSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 导出方式
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "square.and.arrow.down.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("导出方式")
                            .font(.headline)
                    }

                    ForEach(ExportMode.allCases) { mode in
                        let isSelected = model.exportMode == mode
                        HStack(alignment: .top, spacing: 12) {
                            RadioButton(
                                isSelected: isSelected,
                                action: { changeMode(mode) }
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.displayName)
                                    .font(.body.weight(.medium))
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.subtleText)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { changeMode(mode) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 导出目录
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("导出目录")
                            .font(.headline)
                    }

                    HStack(spacing: 8) {
                        TextField("导出路径", text: $model.exportPath)
                            .textFieldStyle(.roundedBorder)
                            .font(AppTheme.monoFontSm)
                        Button("选择…") { model.chooseExportFolder() }
                        Button("打开") { model.openExportFolder() }
                    }

                    Text("导出的聊天记录将保存到此目录")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 语音转文字
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "waveform.and.mic")
                            .foregroundStyle(AppTheme.accent)
                        Text("语音转文字")
                            .font(.headline)
                    }

                    Toggle("导出媒体时本地离线转写语音（whisper.cpp）", isOn: Binding(
                        get: { model.voiceTranscriptionEnabled },
                        set: { model.setVoiceTranscriptionEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("仅在有媒体导出时生效；需要本机安装 whisper.cpp（whisper-cli）与模型。缺少工具时自动跳过，不影响导出。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 图片 OCR
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(AppTheme.accent)
                        Text("图片 OCR")
                            .font(.headline)
                    }

                    Toggle("导出媒体时对图片做本地离线文字识别", isOn: Binding(
                        get: { model.imageOCREnabled },
                        set: { model.setImageOCREnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("使用 macOS 系统 Vision 框架，离线识别截图/图片中的文字，结果以 .ocr.txt 侧车文件保存，并展示在 HTML 中。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 统计报告
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "chart.bar")
                            .foregroundStyle(AppTheme.accent)
                        Text("统计报告")
                            .font(.headline)
                    }

                    Toggle("导出时生成聊天统计报告（消息量/时段/排行）", isOn: Binding(
                        get: { model.statsReportEnabled },
                        set: { model.setStatsReportEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("本地聚合 chat.json，生成单文件 HTML 统计报告（发言排行、24 小时活跃分布、月度趋势、媒体构成），随导出保存在同一目录。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 增量导出
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(AppTheme.accent)
                        Text("增量导出")
                            .font(.headline)
                    }

                    Toggle("只导出上次之后的新增消息（按联系人+目录记忆游标）", isOn: Binding(
                        get: { model.incrementalExportEnabled },
                        set: { model.setIncrementalExportEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("每次导出按「联系人 + 导出目录」记录时间戳游标，下次只保留新增消息；无新增的会话自动跳过。首次开启会记录基线，从下次导出开始生效。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 目录导航页（全文检索）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass.circle")
                            .foregroundStyle(AppTheme.accent)
                        Text("目录导航页（全文检索）")
                            .font(.headline)
                    }

                    Toggle("导出后在目录中生成 index.html（文件列表 + 全文检索框）", isOn: Binding(
                        get: { model.indexPageEnabled },
                        set: { model.setIndexPageEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("扫描导出目录生成导航页：单文件/统计报告入口 + 关键词全文检索（内嵌文本数据，可离线打开）。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 电子书 / 文档版
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "books.vertical")
                            .foregroundStyle(AppTheme.accent)
                        Text("电子书 / 文档版")
                            .font(.headline)
                    }

                    Toggle("导出时生成 EPUB 电子书（本地阅读 App 可打开）", isOn: Binding(
                        get: { model.ebookEpubEnabled },
                        set: { model.setEbookEpubEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Toggle("导出时生成文档版 PDF（A4 排版，可打印 / 分享）", isOn: Binding(
                        get: { model.ebookDocumentEnabled },
                        set: { model.setEbookDocumentEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("本地聚合 chat.json 直接生成，不依赖 HTML，离线无网络。按月分节、保留发言人和时间戳。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 加密导出
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("加密导出")
                            .font(.headline)
                    }

                    SecureField("导出密码（留空 = 明文目录；设置后整体加密为 .wxenc）", text: $model.exportPassword)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("解密导出…") { model.decryptEncryptedExport() }
                            .buttonStyle(.bordered)
                    }

                    Text("密码只在内存中持有，不落盘。留空则按普通明文目录导出。.wxenc 可复制到任意机器用同密码解密（双端互通）。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 导出水印
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "drop.halffull")
                            .foregroundStyle(AppTheme.accent)
                        Text("导出水印")
                            .font(.headline)
                    }

                    Toggle("在导出产物上平铺视觉水印（关闭即无水印版本）", isOn: Binding(
                        get: { model.watermarkEnabled },
                        set: { model.watermarkEnabled = $0 }
                    ))

                    TextField("水印文字（默认：林琝淏科技集团有限公司）",
                              text: Binding(
                        get: { model.watermarkText },
                        set: { model.watermarkText = $0 }
                    ))
                        .textFieldStyle(.roundedBorder)

                    Text("HTML 产物（单文件 / 统计 / 目录 / 表情包画廊）会平铺斜纹水印；EPUB 加版权页脚；PDF 每页盖对角水印。关闭开关后导出全部无水印。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 全文搜索索引（v2.19）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(AppTheme.accent)
                        Text("全文搜索")
                            .font(.headline)
                    }

                    Toggle("导出时生成搜索索引 wce-search.sqlite（FTS5，可 App 内/CLI 全文检索）", isOn: Binding(
                        get: { model.searchIndexEnabled },
                        set: { model.setSearchIndexEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("索引随导出落盘在导出根目录；工具栏「搜索」按钮或命令行 wce search <关键词> 检索，命中结果可跳转到对应聊天记录。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 过滤导出（v2.19）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(AppTheme.accent)
                        Text("过滤导出")
                            .font(.headline)
                    }

                    Toggle("只导出指定时间区间与关键词命中的消息", isOn: Binding(
                        get: { model.filterEnabled },
                        set: { model.setFilterEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    HStack(spacing: 8) {
                        DatePicker("", selection: Binding(
                            get: { model.filterFromDate.isEmpty ? Date() : (Self.dateFromCompact(model.filterFromDate) ?? Date()) },
                            set: { model.setFilterFromDate(Self.compactDate($0)) }
                        ), displayedComponents: [.date])
                        .labelsHidden()
                        Text("~")
                            .foregroundStyle(AppTheme.subtleText)
                        DatePicker("", selection: Binding(
                            get: { model.filterToDate.isEmpty ? Date() : (Self.dateFromCompact(model.filterToDate) ?? Date()) },
                            set: { model.setFilterToDate(Self.compactDate($0)) }
                        ), displayedComponents: [.date])
                        .labelsHidden()
                    }
                    .disabled(!model.filterEnabled)

                    TextField("关键词（逗号分隔，不区分大小写；留空 = 不过滤内容）", text: Binding(
                        get: { model.filterKeywords },
                        set: { model.setFilterKeywords($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.filterEnabled)

                    Text("过滤在脱敏/索引/报告之前生效：产物只保留命中消息，后续所有生成物基于过滤后的数据。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 脱敏导出（v2.19）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(AppTheme.accent)
                        Text("脱敏导出")
                            .font(.headline)
                    }

                    Toggle("把产物中真实名称替换为 用户A/用户B/… 代号（确定性映射）", isOn: Binding(
                        get: { model.anonEnabled },
                        set: { model.setAnonEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Toggle("同时模糊化手机号 / 身份证 / 邮箱", isOn: Binding(
                        get: { model.anonMaskPii },
                        set: { model.setAnonMaskPii($0) }
                    ))
                    .disabled(!model.anonEnabled)

                    Toggle("保留映射文件 anonymization-map.json（关闭 = 导出后销毁，不可逆）", isOn: Binding(
                        get: { model.anonKeepMapping },
                        set: { model.setAnonKeepMapping($0) }
                    ))
                    .disabled(!model.anonEnabled)

                    Text("脱敏在过滤之后、索引/报告/水印之前生效，因此所有生成物（含统计与年度报告）都看不到真实名称。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 年度报告 / 日历提取（v2.19）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(AppTheme.accent)
                        Text("年度报告 / 日历提取")
                            .font(.headline)
                    }

                    Toggle("生成年度可视化报告（热力图/词频/排行，单文件 HTML）", isOn: Binding(
                        get: { model.annualReportEnabled },
                        set: { model.setAnnualReportEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Toggle("从聊天中识别时间约定，生成日历事件（.ics 可导入系统日历）", isOn: Binding(
                        get: { model.calendarExtractEnabled },
                        set: { model.setCalendarExtractEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("年度报告聚合导出目录下全部会话数据；日历事件识别「明天/周X/M月D日/N点」等约定，默认 60 分钟时长。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 定时增量导出（v2.19）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(AppTheme.accent)
                        Text("定时增量导出")
                            .font(.headline)
                    }

                    Toggle("启用定时增量同步（无人值守，无新增则静默）", isOn: Binding(
                        get: { model.autoSyncEnabled },
                        set: { model.setAutoSyncEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Stepper("每 \(model.autoSyncIntervalMinutes) 分钟", value: Binding(
                        get: { model.autoSyncIntervalMinutes },
                        set: { model.setAutoSyncInterval($0) }
                    ), in: 5...1440, step: 5)

                    HStack(spacing: 8) {
                        Button(model.autoSyncInstalled ? "重装定时任务" : "安装定时任务") {
                            model.installAutoSyncTask(log: model.appendLog)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.autoSyncEnabled)
                        Button("卸载") { model.uninstallAutoSyncTask() }
                            .buttonStyle(.bordered)
                            .tint(model.autoSyncInstalled ? .primary : .gray)
                        Spacer()
                        Text(model.autoSyncInstalled ? "已安装" : "未安装")
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(model.autoSyncInstalled ? AppTheme.success : AppTheme.subtleText)
                    }

                    if !model.autoSyncLastRun.isEmpty {
                        Text("上次运行：\(model.autoSyncLastRun)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.subtleText)
                    }
                    Text("安装后系统每 N 分钟自动执行一次增量导出（launchd，日志在 ~/Library/Logs/wce-autosync.log）。会话范围默认为当前选中的联系人，留空 = 全部会话。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // wx-cli 设置（用户自带）
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundStyle(AppTheme.accent)
                        Text("wx-cli 设置")
                            .font(.headline)
                    }

                    HStack(spacing: 8) {
                        TextField("wx-cli 路径（默认自动搜索：内置 → ~/.local/bin → Homebrew）",
                                  text: Binding(
                                    get: { model.customWxCliPath },
                                    set: { model.setCustomWxCliPath($0) }
                                  ))
                        .textFieldStyle(.roundedBorder)
                        .font(AppTheme.monoFontSm)
                    }

                    Text("留空则使用内置 wx-cli（安装即用）。填写自定义绝对路径可优先使用你自己构建的 wx-cli（含上游新版本或自行编译的 fork），路径不可执行时自动回退到内置版本。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 诊断日志上传
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(AppTheme.accent)
                        Text("诊断日志上传")
                            .font(.headline)
                    }

                    Toggle("自动上传诊断日志(报错时)", isOn: $model.diagnosticsConsented)
                        .toggleStyle(.switch)

                    Text("仅当导出过程中发生错误时，静默上传技术诊断数据（应用版本、错误信息、运行日志），不包含聊天内容、联系人或账号信息。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeMode(_ mode: ExportMode) {
        model.exportMode = mode
        ExportModePreferences.mode = mode
    }

    // 过滤日期 helper（yyyy-MM-dd 字符串 <-> Date）
    static func compactDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return f.string(from: d)
    }

    static func dateFromCompact(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return f.date(from: s)
    }
}

// MARK: - 更新设置

private struct UpdateSettingsTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 版本信息
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text("版本信息")
                            .font(.headline)
                    }

                    HStack {
                        Text("当前版本")
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("v\(model.currentVersion)")
                            .font(AppTheme.monoFont.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        Text("(Build \(model.currentBuild))")
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                    }
                    if let lastCheck = model.lastCheckDate {
                        HStack {
                            Text("上次检查")
                                .foregroundStyle(AppTheme.subtleText)
                            Spacer()
                            Text(lastCheck.formatted(date: .abbreviated, time: .shortened))
                                .font(AppTheme.monoFontSm)
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 更新方式
            TechCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(AppTheme.accent)
                        Text("更新方式")
                            .font(.headline)
                    }

                    ForEach(UpdateMode.allCases, id: \.self) { mode in
                        HStack(alignment: .top, spacing: 12) {
                            RadioButton(
                                isSelected: model.updateMode == mode,
                                action: { model.changeUpdateMode(mode) }
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.displayName)
                                    .font(.body.weight(.medium))
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.subtleText)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.changeUpdateMode(mode) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 手动检查
            HStack(spacing: 12) {
                Button {
                    model.checkForUpdatesManually()
                } label: {
                    Label("立即检查更新", systemImage: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(model.isCheckingUpdate || model.isDownloadingUpdate)

                if model.isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查…")
                        .font(AppTheme.monoFontSm)
                        .foregroundStyle(AppTheme.subtleText)
                }

                Spacer()

                Button("前往 Release 页面") {
                    model.openReleaseInBrowser()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)
            }

            // 下载进度
            if model.isDownloadingUpdate, let progress = model.updateDownloadProgress {
                TechCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载进度")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.subtleText)
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .tint(AppTheme.accent)
                        HStack {
                            Text(progress.formattedProgress)
                                .font(AppTheme.monoFontSm)
                                .foregroundStyle(AppTheme.subtleText)
                            Spacer()
                            Text("\(Int(progress.fraction * 100))%")
                                .font(AppTheme.monoFontSm.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 安装中提示
            if model.isInstallingUpdate {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装更新，应用将自动重启…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 关于

private struct AboutTab: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 22) {
            // App icon
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.headerGradient)
                        .frame(width: 88, height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: AppTheme.accentGlow, radius: 16, y: 6)

                    Image(systemName: "message.and.waveform.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 4) {
                    Text("微信聊天记录导出")
                        .font(.title2.weight(.bold))
                    HStack(spacing: 6) {
                        Text("v\(model.currentVersion)")
                            .font(AppTheme.monoFont.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        Text("Build \(model.currentBuild)")
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            // Quick guide
            TechCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("快速指南", systemImage: "book.fill")
                        .font(.headline)
                    GuideStep(number: 1, text: "首次使用点击「准备数据」（会重启微信）")
                    GuideStep(number: 2, text: "在左侧列表中选择一个或多个联系人")
                    GuideStep(number: 3, text: "点击「导出选中」生成 HTML 文件")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Environment requirements
            TechCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.warning)
                        Text("环境要求")
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Label("macOS 需关闭 SIP（恢复模式执行 csrutil disable）", systemImage: "checkmark.circle")
                            .font(.caption)
                        Label("需启用 DevToolsSecurity（软件可自动检测并启用）", systemImage: "checkmark.circle")
                            .font(.caption)
                        Label("支持微信 4.1.7 – 4.1.11", systemImage: "checkmark.circle")
                            .font(.caption)
                        Label("Windows 需安装 .NET 8 运行时", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .foregroundStyle(AppTheme.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Links
            HStack(spacing: 20) {
                LinkButton(title: "GitHub 仓库", icon: "star.fill") {
                    if let url = URL(string: "https://github.com/93857536-pixel/WeChatExporter") {
                        NSWorkspace.shared.open(url)
                    }
                }
                LinkButton(title: "问题反馈", icon: "exclamationmark.bubble.fill") {
                    if let url = URL(string: "https://github.com/93857536-pixel/WeChatExporter/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                LinkButton(title: "Release 下载", icon: "arrow.down.circle.fill") {
                    model.openReleaseInBrowser()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 90, height: 52)
            .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
    }
}
