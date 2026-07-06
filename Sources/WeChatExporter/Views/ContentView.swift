import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.03, green: 0.76, blue: 0.38)
    static let accentSoft = Color(red: 0.03, green: 0.76, blue: 0.38).opacity(0.12)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtleText = Color.secondary
}

struct ContentView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
        } detail: {
            detailPanel
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("提示", isPresented: $model.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
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
                Section {
                    ForEach(model.filteredContacts) { contact in
                        ContactRow(contact: contact)
                            .tag(contact.id)
                    }
                } header: {
                    HStack {
                        Text("会话")
                        Spacer()
                        Text("\(model.filteredContacts.count)")
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
                    Text("选择联系人后导出 TXT / CSV / JSON")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.subtleText)
                }
            }

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
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
                VStack(alignment: .leading, spacing: 12) {
                    Label("导出设置", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Toggle("同时导出图片等媒体文件（体积更大，耗时更长）", isOn: $model.includeMedia)
                        .toggleStyle(.switch)
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("导出目录", systemImage: "folder.fill")
                        .font(.headline)
                    HStack {
                        TextField("导出路径", text: $model.exportPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { model.chooseExportFolder() }
                        Button("打开") { model.openExportFolder() }
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("使用说明", systemImage: "info.circle.fill")
                        .font(.headline)
                    Text("1. 首次使用点击「准备数据」（会重启微信）")
                    Text("2. 在左侧列表中选择一个或多个联系人")
                    Text("3. 点击「导出选中」")
                    Text("4. 路径由系统自动检测，无需手动配置")
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
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("详情")
    }

    private var readinessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.isDataReady ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(model.isDataReady ? AppTheme.accent : .orange)
                .font(.title3)
            Text(model.readinessHint)
                .font(.subheadline)
                .foregroundStyle(AppTheme.subtleText)
            Spacer()
        }
        .padding(12)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ContactRow: View {
    let contact: ContactItem

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

            Text(contact.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.accentSoft, in: Capsule())
        }
        .padding(.vertical, 4)
    }
}
