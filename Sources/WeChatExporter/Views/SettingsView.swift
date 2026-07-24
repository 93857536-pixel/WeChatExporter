import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("外观") {
                    Picker("界面主题", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("导出方式") {
                    Picker("输出类型", selection: $settings.exportStyle) {
                        ForEach(ExportStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Text(settings.exportStyle.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("时间范围") {
                    Picker("范围", selection: $settings.dateRangePreset) {
                        ForEach(DateRangePreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    if settings.dateRangePreset == .custom {
                        DatePicker("开始", selection: $settings.customSince, displayedComponents: .date)
                        DatePicker("结束", selection: $settings.customUntil, displayedComponents: .date)
                    }
                }

                Section("消息类型") {
                    ForEach(MessageTypeFilter.allCases) { type in
                        Toggle(type.title, isOn: Binding(
                            get: { settings.enabledMessageTypes.contains(type) },
                            set: { on in
                                if on { settings.enabledMessageTypes.insert(type) }
                                else { settings.enabledMessageTypes.remove(type) }
                                if settings.enabledMessageTypes.isEmpty {
                                    settings.enabledMessageTypes = Set(MessageTypeFilter.allCases)
                                }
                            }
                        ))
                    }
                }

                Section("导出内容") {
                    if settings.exportStyle == .singleHTML {
                        Toggle("导出媒体并内嵌到 HTML（图片/表情/音视频）", isOn: $settings.includeMedia)
                        Toggle("额外导出全部表情包画廊", isOn: $settings.includeStickerGallery)
                            .disabled(!settings.includeMedia)
                    } else if settings.exportStyle == .folderBundle {
                        Text("分类文件夹模式会自动导出媒体，并整理为文字 / 图片 / 音频 / 视频 / 表情。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("同时附带 聊天记录.csv", isOn: $settings.folderIncludeCSV)
                        Toggle("同时附带 chat.json 原始数据", isOn: $settings.folderIncludeJSON)
                        Toggle("额外导出全部表情包画廊", isOn: $settings.includeStickerGallery)
                    } else {
                        Toggle("导出时附带媒体文件（若 CLI 支持）", isOn: $settings.includeMedia)
                    }
                    Toggle("增量续导（只导出上次之后的新消息）", isOn: $settings.incrementalExport)
                    Toggle("群聊映射成员昵称", isOn: $settings.mapGroupNicknames)
                    Toggle("语音转文字（需系统语音识别权限）", isOn: $settings.enableSpeechToText)
                }

                Section("导出目录") {
                    HStack {
                        TextField("导出路径", text: $settings.exportPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { model.chooseExportFolder() }
                        Button("打开") { model.openExportFolder() }
                    }
                    Toggle("导出完成后自动打开文件夹", isOn: $settings.openFolderAfterExport)
                }

                Section("环境") {
                    Button("一键检测环境") {
                        Task { await model.runEnvironmentCheck() }
                    }
                    Text("准备数据会重启微信；macOS 需关闭 SIP。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            Text(AppSettings.creditLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .frame(width: 580, height: 720)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}
