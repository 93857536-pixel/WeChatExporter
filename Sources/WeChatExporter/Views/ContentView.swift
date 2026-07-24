import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.03, green: 0.76, blue: 0.38)
    static let accentSoft = Color(red: 0.03, green: 0.76, blue: 0.38).opacity(0.12)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtleText = Color.secondary
}

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
        } detail: {
            detailPanel
        }
        .frame(minWidth: 980, minHeight: 680)
        .preferredColorScheme(settings.appearance.colorScheme)
        .alert("提示", isPresented: $model.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .sheet(isPresented: $model.showSettings) {
            NavigationStack {
                SettingsView(model: model, settings: settings)
            }
        }
        .task {
            await model.startIfNeeded()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(16)

            List(selection: $model.selectedIDs) {
                if !model.favoriteContacts.isEmpty {
                    Section {
                        ForEach(model.favoriteContacts) { contact in
                            ContactRow(
                                contact: contact,
                                isFavorite: true,
                                onToggleFavorite: { model.toggleFavorite(contact.id) }
                            )
                            .tag(contact.id)
                        }
                    } header: {
                        HStack {
                            Text("收藏")
                            Spacer()
                            Text("\(model.favoriteContacts.count)")
                                .foregroundStyle(AppTheme.subtleText)
                        }
                    }
                }

                Section {
                    ForEach(model.otherContacts) { contact in
                        ContactRow(
                            contact: contact,
                            isFavorite: settings.favoriteIDs.contains(contact.id),
                            onToggleFavorite: { model.toggleFavorite(contact.id) }
                        )
                        .tag(contact.id)
                    }
                } header: {
                    HStack {
                        Text("会话")
                        Spacer()
                        Text("\(model.otherContacts.count)")
                            .foregroundStyle(AppTheme.subtleText)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .searchable(text: $model.searchText, prompt: "搜索联系人、群聊、备注")
        .toolbar { toolbarContent }
        .navigationTitle("微信聊天记录导出")
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "message.and.waveform.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("导出工具")
                        .font(.title3.weight(.semibold))
                    Text("当前：\(settings.exportStyle.title) · \(settings.dateRangePreset.title)")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.subtleText)
                }
            }

            if model.isBusy || model.operationProgress != nil {
                operationProgressView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var operationProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = model.operationProgress {
                ProgressView(value: value) {
                    Text(model.operationProgressLabel.isEmpty ? "处理中…" : model.operationProgressLabel)
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                }
                .progressViewStyle(.linear)
                Text("\(Int(value * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.subtleText)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape.fill")
            }

            Button {
                Task { await model.prepareData() }
            } label: {
                Label("准备数据", systemImage: "key.fill")
            }
            .disabled(model.isBusy)

            Button {
                Task { await model.refreshContacts() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)

            Button {
                Task { await model.previewSelected() }
            } label: {
                Label("预览", systemImage: "eye")
            }
            .disabled(model.isBusy || model.selectedIDs.isEmpty)

            Button {
                Task { await model.retryFailedExports() }
            } label: {
                Label("重试失败", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!model.canRetryFailed)

            Button {
                Task { await model.exportSelected() }
            } label: {
                Label("导出选中", systemImage: "square.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .disabled(model.isBusy || model.selectedIDs.isEmpty)
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessBanner

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("当前导出配置", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Text("方式：\(settings.exportStyle.title)")
                    Text("时间：\(settings.dateRangePreset.title)")
                    Text("增量续导：\(settings.incrementalExport ? "开" : "关") · 群昵称：\(settings.mapGroupNicknames ? "开" : "关") · 语音转写：\(settings.enableSpeechToText ? "开" : "关")")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                    Text(settings.exportStyle.detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                    Text("目录：\(settings.exportPath)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                        .lineLimit(2)
                    HStack {
                        Button("打开设置…") { model.showSettings = true }
                        Button("环境检测") {
                            Task { await model.runEnvironmentCheck() }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("使用说明", systemImage: "info.circle.fill")
                        .font(.headline)
                    Text("1. 首次使用点击「准备数据」（会重启微信）")
                    Text("2. 收藏常用联系人；搜索并多选会话")
                    Text("3. 在「设置」配置时间范围、消息类型、输出格式")
                    Text("4. 可先「预览」再「导出选中」；失败可「重试失败」")
                        .foregroundStyle(AppTheme.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("日志", systemImage: "doc.text.fill")
                            .font(.headline)
                        Spacer()
                        Text(model.statusText)
                            .foregroundStyle(AppTheme.subtleText)
                            .font(.caption)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(4)
            }

            Text(AppSettings.creditLine)
                .font(.caption2)
                .foregroundStyle(AppTheme.subtleText)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("详情")
    }

    private var readinessBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.isDataReady ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(model.isDataReady ? AppTheme.accent : .orange)
                    .font(.title3)
                Text(model.readinessHint)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.subtleText)
                Spacer()
            }

            if let value = model.operationProgress {
                ProgressView(value: value) {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(AppTheme.accent)
            }
        }
        .padding(12)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ContactRow: View {
    let contact: ContactItem
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contact.kind.icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(contact.subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.subtleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .orange : AppTheme.subtleText)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "取消收藏" : "收藏")

            Text(contact.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.accentSoft, in: Capsule())
        }
        .padding(.vertical, 4)
    }
}
