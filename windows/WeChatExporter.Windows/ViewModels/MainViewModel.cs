using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using Microsoft.Win32;
using WeChatExporter.Models;
using WeChatExporter.Services;

namespace WeChatExporter.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly WxCliService _wxCli;
    private string _searchText = "";
    private string _exportPath;
    private string _statusText = "就绪";
    private bool _isBusy;
    private bool _isDataReady;
    private bool _includeMedia;
    private ExportStyle _exportStyle = ExportStyle.SingleHtml;
    private string? _alertMessage;
    private double? _operationProgress;
    private string _operationProgressLabel = "";

    public MainViewModel(WxCliService wxCli)
    {
        _wxCli = wxCli;
        _exportPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads", "微信聊天记录导出");
        Contacts = [];
        Logs = [];
        ContactsView = CollectionViewSource.GetDefaultView(Contacts);
        ContactsView.Filter = FilterContact;
        IsRunningAsAdmin = PlatformHelper.IsRunningAsAdministrator();
        AppendLog(wxCli.IsBundled ? "使用内置 wx-cli（即装即用）" : "使用系统 wx-cli");
        if (!IsRunningAsAdmin)
            AppendLog("提示：首次「准备数据」建议以管理员身份运行（可点击下方按钮）");
        _ = BootstrapAsync();
    }

    public ObservableCollection<ContactItem> Contacts { get; }
    public ICollectionView ContactsView { get; }
    public ObservableCollection<ContactItem> SelectedContacts { get; } = [];
    public ObservableCollection<string> Logs { get; }

    public bool IsRunningAsAdmin { get; }

    public string ReadinessHint
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(OperationProgressLabel))
                return OperationProgressLabel;
            if (IsBusy) return "正在处理，请稍候…";
            if (IsDataReady) return $"已就绪 · 共 {Contacts.Count} 个会话，选择后点击「导出选中」";
            if (!IsRunningAsAdmin)
                return "首次使用：请先以管理员身份运行，再点击「准备数据」（需微信 PC 版已登录）";
            return "首次使用：请点击「准备数据」（需微信 PC 版已登录）";
        }
    }

    public double? OperationProgress
    {
        get => _operationProgress;
        private set
        {
            if (_operationProgress == value) return;
            _operationProgress = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ShowOperationProgress));
            OnPropertyChanged(nameof(ShowIndeterminateBusy));
            OnPropertyChanged(nameof(OperationProgressPercentText));
        }
    }

    public string OperationProgressLabel
    {
        get => _operationProgressLabel;
        private set
        {
            if (_operationProgressLabel == value) return;
            _operationProgressLabel = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ReadinessHint));
        }
    }

    public bool ShowOperationProgress => OperationProgress.HasValue;

    public bool ShowIndeterminateBusy => IsBusy && !ShowOperationProgress;

    public string OperationProgressPercentText
        => OperationProgress is double p ? $"{Math.Clamp((int)Math.Round(p * 100), 0, 100)}%" : "";

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (_searchText == value) return;
            _searchText = value;
            OnPropertyChanged();
            ContactsView.Refresh();
            OnPropertyChanged(nameof(FilteredCountText));
        }
    }

    public string ExportPath
    {
        get => _exportPath;
        set
        {
            if (_exportPath == value) return;
            _exportPath = value;
            OnPropertyChanged();
        }
    }

    public bool IncludeMedia
    {
        get => _includeMedia;
        set
        {
            if (_includeMedia == value) return;
            _includeMedia = value;
            OnPropertyChanged();
        }
    }

    public ExportStyle ExportStyle
    {
        get => _exportStyle;
        set
        {
            if (_exportStyle == value) return;
            _exportStyle = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsSingleHtmlStyle));
            OnPropertyChanged(nameof(IsFolderBundleStyle));
            OnPropertyChanged(nameof(ExportStyleDetail));
            OnPropertyChanged(nameof(ShowIncludeMediaToggle));
        }
    }

    public bool IsSingleHtmlStyle
    {
        get => ExportStyle == ExportStyle.SingleHtml;
        set { if (value) ExportStyle = ExportStyle.SingleHtml; }
    }

    public bool IsFolderBundleStyle
    {
        get => ExportStyle == ExportStyle.FolderBundle;
        set { if (value) ExportStyle = ExportStyle.FolderBundle; }
    }

    public string ExportStyleDetail => ExportStyleInfo.Detail(ExportStyle);

    public bool ShowIncludeMediaToggle => ExportStyle == ExportStyle.SingleHtml;

    public string StatusText
    {
        get => _statusText;
        private set
        {
            if (_statusText == value) return;
            _statusText = value;
            OnPropertyChanged();
        }
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (_isBusy == value) return;
            _isBusy = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanExport));
            OnPropertyChanged(nameof(ReadinessHint));
            OnPropertyChanged(nameof(ShowIndeterminateBusy));
        }
    }

    public bool IsDataReady
    {
        get => _isDataReady;
        private set
        {
            if (_isDataReady == value) return;
            _isDataReady = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ReadinessHint));
        }
    }

    public bool CanExport => !IsBusy && SelectedContacts.Count > 0;

    public string? AlertMessage
    {
        get => _alertMessage;
        private set
        {
            _alertMessage = value;
            OnPropertyChanged();
        }
    }

    public string FilteredCountText => $"显示 {ContactsView.Cast<object>().Count()} / {Contacts.Count} 个会话";

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool FilterContact(object obj)
    {
        if (obj is not ContactItem contact) return false;
        var q = SearchText.Trim();
        if (string.IsNullOrEmpty(q)) return true;
        return $"{contact.DisplayName} {contact.NickName} {contact.Remark} {contact.Id} {contact.Summary}"
            .Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    public void NotifySelectionChanged()
    {
        OnPropertyChanged(nameof(CanExport));
    }

    public void RestartAsAdministrator()
    {
        if (PlatformHelper.TryRestartAsAdministrator())
            Application.Current.Shutdown();
        else
            ShowError("无法以管理员身份重启，请手动右键 WeChatExporter.exe → 以管理员身份运行。");
    }

    public async Task PrepareDataAsync()
    {
        if (IsBusy) return;
        IsBusy = true;
        StatusText = "准备数据中…";
        try
        {
            AppendLog("开始准备数据…");
            await _wxCli.PrepareDataAsync(AppendLog, ReportProgress);
            await LoadContactsInternalAsync(showErrorDialog: true);
            ShowAlert("数据准备完成，现在可以导出聊天记录了。");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        finally
        {
            IsBusy = false;
            StatusText = "就绪";
            ClearProgress();
        }
    }

    public async Task RefreshContactsAsync()
    {
        if (IsBusy) return;
        IsBusy = true;
        StatusText = "加载会话…";
        try
        {
            await LoadContactsInternalAsync(showErrorDialog: true);
        }
        finally
        {
            IsBusy = false;
            ClearProgress();
        }
    }

    public async Task ExportSelectedAsync()
    {
        if (IsBusy) return;
        // 快照当前选中项，避免导出过程中选中变化导致串到其他人。
        var selected = SelectedContacts.ToList();
        if (selected.Count == 0)
        {
            ShowError("请先在列表中选择联系人或群聊。");
            return;
        }

        IsBusy = true;
        StatusText = "导出中…";
        var summary = new List<string>();
        var failures = new List<string>();
        try
        {
            Directory.CreateDirectory(ExportPath);
            var style = ExportStyle;
            var wantMedia = style == ExportStyle.FolderBundle || IncludeMedia;

            if (wantMedia && style == ExportStyle.SingleHtml)
            {
                var stickerTemp = Path.Combine(Path.GetTempPath(), $"WeChatExporter-stickers-{Guid.NewGuid():N}");
                try
                {
                    var stickerCount = await StickerPackExporter.ExportAllPacksAsync(stickerTemp, AppendLog);
                    if (stickerCount > 0)
                    {
                        var galleryPath = SingleFileExporter.WriteStickerGallery(stickerTemp, ExportPath);
                        if (galleryPath is not null)
                            summary.Add($"• 全部表情包：{stickerCount} 张 → {Path.GetFileName(galleryPath)}");
                    }
                }
                finally
                {
                    try { if (Directory.Exists(stickerTemp)) Directory.Delete(stickerTemp, true); } catch { /* ignore */ }
                }
            }

            for (var index = 0; index < selected.Count; index++)
            {
                var contact = selected[index];
                OperationProgress = (double)index / selected.Count;
                OperationProgressLabel = $"正在导出 {contact.DisplayName}（{index + 1}/{selected.Count}）…";

                var tempDir = Path.Combine(Path.GetTempPath(), $"WeChatExporter-{Guid.NewGuid():N}");
                try
                {
                    var count = await _wxCli.ExportAsync(contact, tempDir, wantMedia, AppendLog);
                    if (style == ExportStyle.FolderBundle)
                    {
                        var result = FolderBundleExporter.Write(tempDir, contact.DisplayName, ExportPath, AppendLog);
                        summary.Add(
                            $"• {contact.DisplayName}：{count} 条 → {Path.GetFileName(result.FolderPath)}/（图{result.ImageCount}/音{result.AudioCount}/视{result.VideoCount}）");
                    }
                    else
                    {
                        var htmlPath = SingleFileExporter.WriteHtml(tempDir, contact.DisplayName, ExportPath);
                        summary.Add($"• {contact.DisplayName}：{count} 条 → {Path.GetFileName(htmlPath)}");
                    }
                }
                catch (Exception ex)
                {
                    failures.Add($"• {contact.DisplayName}：{ex.Message}");
                    AppendLog($"导出失败：{contact.DisplayName} — {ex.Message}");
                }
                finally
                {
                    try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true); } catch { /* ignore */ }
                }
            }

            if (summary.Count == 0)
            {
                ShowError($"全部导出失败（共 {selected.Count} 个会话）：\n{string.Join('\n', failures)}");
            }
            else if (failures.Count == 0)
            {
                var tip = style == ExportStyle.SingleHtml
                    ? "用浏览器打开 .html 即可查看全部内容（媒体已内嵌）。"
                    : "每个会话一个文件夹：文字记录.txt + 图片/音频/视频/表情 分目录。";
                ShowAlert($"已导出 {summary.Count} 项到：\n{ExportPath}\n\n{string.Join('\n', summary)}\n\n{tip}");
            }
            else
            {
                ShowAlert($"部分导出完成（成功 {summary.Count}，失败 {failures.Count}）：\n{ExportPath}\n\n成功：\n{string.Join('\n', summary)}\n\n失败：\n{string.Join('\n', failures)}");
            }
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        finally
        {
            IsBusy = false;
            StatusText = "就绪";
            ClearProgress();
        }
    }

    public void ChooseExportFolder()
    {
        var dialog = new OpenFolderDialog
        {
            Title = "选择导出目录",
            InitialDirectory = Directory.Exists(ExportPath) ? ExportPath : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        if (dialog.ShowDialog() == true)
            ExportPath = dialog.FolderName;
    }

    public void OpenExportFolder()
    {
        Directory.CreateDirectory(ExportPath);
        ProcessHelper.OpenFolder(ExportPath);
    }

    private async Task BootstrapAsync()
    {
        if (!await _wxCli.IsPreparedForQueryAsync())
        {
            AppendLog("首次使用请点击「准备数据」。");
            return;
        }

        AppendLog("正在自动加载会话列表…");
        IsBusy = true;
        try
        {
            await LoadContactsInternalAsync(showErrorDialog: false);
        }
        finally
        {
            IsBusy = false;
            ClearProgress();
        }
    }

    private async Task LoadContactsInternalAsync(bool showErrorDialog)
    {
        try
        {
            var items = await _wxCli.LoadSessionsAsync(AppendLog, ReportProgress);
            Contacts.Clear();
            foreach (var item in items)
                Contacts.Add(item);
            ContactsView.Refresh();
            OnPropertyChanged(nameof(FilteredCountText));
            StatusText = FilteredCountText;
            IsDataReady = Contacts.Count > 0;
        }
        catch (Exception ex)
        {
            IsDataReady = false;
            if (showErrorDialog)
                ShowError(ex.Message);
            else
            {
                AppendLog($"自动加载失败：{ex.Message}");
                AppendLog("首次使用请点击「准备数据」。");
            }
        }
    }

    private void ReportProgress(LoadProgressUpdate update)
    {
        Application.Current.Dispatcher.Invoke(() =>
        {
            OperationProgress = update.Fraction;
            OperationProgressLabel = update.Message;
        });
    }

    private void ClearProgress()
    {
        OperationProgress = null;
        OperationProgressLabel = "";
    }

    private void AppendLog(string message)
    {
        var line = message.Trim();
        if (string.IsNullOrEmpty(line)) return;

        Application.Current.Dispatcher.Invoke(() =>
        {
            Logs.Add(line);
            while (Logs.Count > 300)
                Logs.RemoveAt(0);
        });
    }

    private void ShowAlert(string message)
    {
        AlertMessage = message;
        MessageBox.Show(message, "提示", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void ShowError(string message)
    {
        AppendLog($"错误：{message}");
        AlertMessage = message;
        MessageBox.Show(message, "错误", MessageBoxButton.OK, MessageBoxImage.Error);
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

internal static class ProcessHelper
{
    public static void OpenFolder(string path)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = true
        });
    }
}
