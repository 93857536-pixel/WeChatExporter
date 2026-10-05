import SwiftUI
import AppKit

/// 云备份设置卡：登录/注册(OTP) + 备份上传/管理/删除/下载。
/// 与 Windows 端对齐，对接同一后端 /api/backup。
struct CloudBackupSettingsTab: View {
    @StateObject private var model = CloudBackupViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isLoggedIn {
                accountCard
                uploadCard
                filesCard
            } else {
                loginCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("提示", isPresented: $model.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .confirmationDialog(
            "删除云端备份",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(model.pendingDelete?.name ?? "")」", role: .destructive) {
                model.performDelete()
            }
            Button("取消", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("此操作不可撤销，云端备份将被永久删除。")
        }
    }

    // MARK: - 登录/注册

    private var loginCard: some View {
        TechCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .foregroundStyle(AppTheme.accent)
                    Text("登录 / 注册")
                        .font(.headline)
                }

                Picker("验证方式", selection: $model.authType) {
                    ForEach(CloudAuthType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField("邮箱或手机号", text: $model.target)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    TextField("6 位验证码", text: $model.code)
                        .textFieldStyle(.roundedBorder)
                        .font(AppTheme.monoFont)
                    Button(model.countdown > 0 ? "\(model.countdown)s" : "发送验证码") {
                        model.sendCode()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSendingCode || model.countdown > 0)
                }

                TextField("昵称（可选）", text: $model.handle)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button {
                        model.loginOrRegister()
                    } label: {
                        Text(model.authBusy ? "处理中…" : "登录 / 注册")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(model.authBusy)
                }

                Text("验证码会发送到你的邮箱/手机号；昵称可选。登录后备份数据会先在本地加密，密码永不上传服务器。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        TechCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                    Text("账号")
                        .font(.headline)
                    Spacer()
                    Button("登出") { model.logout() }
                        .buttonStyle(.bordered)
                }

                HStack {
                    Text("昵称")
                        .foregroundStyle(AppTheme.subtleText)
                    Spacer()
                    Text(model.currentHandle)
                        .font(AppTheme.monoFont.weight(.semibold))
                }

                if let usage = model.usage {
                    HStack {
                        Text("用量")
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("\(CloudByteSize.string(usage.usedBytes)) / \(CloudByteSize.string(usage.quotaBytes)) · \(usage.fileCount) 个文件")
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.accent)
                    }
                    ProgressView(
                        value: usage.quotaBytes > 0 ? Double(usage.usedBytes) / Double(usage.quotaBytes) : 0
                    )
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
                }

                HStack {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.loadingFiles)
                    Spacer()
                    if model.loadingFiles {
                        ProgressView().controlSize(.small)
                    }
                }

                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 上传

    private var uploadCard: some View {
        TechCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                    Text("备份到云端")
                        .font(.headline)
                }

                HStack(spacing: 8) {
                    TextField("导出目录", text: $model.uploadSourceDir)
                        .textFieldStyle(.roundedBorder)
                        .font(AppTheme.monoFontSm)
                    Button("选择…") { model.selectUploadDirectory() }
                }

                SecureField("备份密码（本地加密为 .wxenc，不上传服务器）", text: $model.password)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button {
                        model.startUpload()
                    } label: {
                        Text(model.isUploading ? "上传中…" : "上传备份")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(model.isUploading || model.uploadSourceDir.isEmpty || model.password.isEmpty)
                    Spacer()
                    if model.isUploading {
                        ProgressView().controlSize(.small)
                    }
                }

                if model.isUploading, let p = model.uploadProgress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)
                    HStack {
                        Text(model.uploadLabel)
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("\(Int(p * 100))%")
                            .font(AppTheme.monoFontSm.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                }

                Text("把导出目录整体加密为单个 .wxenc 后分块上传；重新备份同名覆盖。云端只存密文。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 云端文件列表

    private var filesCard: some View {
        TechCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .foregroundStyle(AppTheme.accent)
                    Text("云端备份")
                        .font(.headline)
                    Spacer()
                    Text("\(model.files.count) 个")
                        .font(AppTheme.monoFontSm)
                        .foregroundStyle(AppTheme.subtleText)
                }

                if model.files.isEmpty {
                    Text("暂无备份文件。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.subtleText)
                } else {
                    ForEach(model.files) { file in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.body.weight(.medium))
                                HStack(spacing: 8) {
                                    Text(CloudByteSize.string(file.totalSize))
                                        .font(AppTheme.monoFontSm)
                                        .foregroundStyle(AppTheme.subtleText)
                                    Text(file.state)
                                        .font(AppTheme.monoFontSm)
                                        .foregroundStyle(file.state == "complete" ? AppTheme.success : AppTheme.warning)
                                    Text(file.createdAt)
                                        .font(AppTheme.monoFontSm)
                                        .foregroundStyle(AppTheme.subtleText)
                                }
                            }
                            Spacer()
                            Button("下载") { model.startDownload(file) }
                                .buttonStyle(.bordered)
                                .disabled(model.isDownloading)
                            Button(role: .destructive) {
                                model.confirmDelete(file)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isDownloading)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if model.isDownloading, let p = model.downloadProgress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)
                    HStack {
                        Text(model.downloadLabel)
                            .font(AppTheme.monoFontSm)
                            .foregroundStyle(AppTheme.subtleText)
                        Spacer()
                        Text("\(Int(p * 100))%")
                            .font(AppTheme.monoFontSm.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
