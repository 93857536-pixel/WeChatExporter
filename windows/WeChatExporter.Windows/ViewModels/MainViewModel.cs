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
    private bool _includeStickerGallery = true;
    private bool _folderIncludeCsv = true;
    private bool _folderIncludeJson;
    private bool _openFolderAfterExport;
    private DateRangePreset _dateRangePreset = DateRangePreset.All;
    private DateTime _customSince = DateTime.Today.AddMonths(-1);
    private DateTime _customUntil = DateTime.Today;
    private HashSet<string> _enabledMessageTypes = MessageTypeFilterInfo.AllIds().ToHashSet(StringComparer.OrdinalIgnoreCase);
    private bool _incrementalExport;
    private bool _mapGroupNicknames = true;
    private bool _enableSpeechToText;
    private bool _showFavoritesOnly;
    private string? _alertMessage;
    private double? _operationProgress;
    private string _operationProgressLabel = "";
    private readonly List<string> _lastFailedIds = [];

    public MainViewModel(WxCliService wxCli)
    {
        _wxCli = wxCli;
        var store = AppSettings.Shared;
        _exportPath = string.IsNullOrWhiteSpace(store.ExportPath)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "微信聊天记录导出")
            : store.ExportPath;
        _includeMedia = store.IncludeMedia;
        _exportStyle = store.ExportStyle;
        _includeStickerGallery = store.IncludeStickerGallery;
        _folderIncludeCsv = store.FolderIncludeCsv;
        _folderIncludeJson = store.FolderIncludeJson;
        _openFolderAfterExport = store.OpenFolderAfterExport;
        _dateRangePreset = store.DateRangePreset;
        _customSince = store.CustomSince;
        _customUntil = store.CustomUntil;
        _enabledMessageTypes = store.EnabledMessageTypes.ToHashSet(StringComparer.OrdinalIgnoreCase);
        _incrementalExport = store.IncrementalExport;
        _mapGroupNicknames = store.MapGroupNicknames;
        _enableSpeechToText = store.EnableSpeechToText;

        Contacts = [];
        Logs = [];
        ContactsView = CollectionViewSource.GetDefaultView(Contacts);
        ContactsView.Filter = FilterContact;
        ContactsView.SortDescriptions.Add(new SortDescription(nameof(ContactItem.IsFavorite), ListSortDirection.Descending));
        ContactsView.SortDescriptions.Add(new SortDescription(nameof(ContactItem.LastTimestamp), ListSortDirection.Descending));
        IsRunningAsAdmin = PlatformHelper.IsRunningAsAdministrator();
        AppendLog(wxCli.IsBundled ? "使用内置 wx-cli（即装即用）" : "使用系统 wx-cli");
        if (!IsRunningAsAdmin)
            AppendLog("提示：首次「准备数据」建议以管理员身份运行（可在设置或下方按钮提权）");
        _ = BootstrapAsync();
    }

    public void ApplySettingsFromStore()
    {
        var store = AppSettings.Shared;
        ExportPath = store.ExportPath;
        IncludeMedia = store.IncludeMedia;
        ExportStyle = store.ExportStyle;
        IncludeStickerGallery = store.IncludeStickerGallery;
        FolderIncludeCsv = store.FolderIncludeCsv;
        FolderIncludeJson = store.FolderIncludeJson;
        OpenFolderAfterExport = store.OpenFolderAfterExport;
        DateRangePreset = store.DateRangePreset;
        CustomSince = store.CustomSince;
        CustomUntil = store.CustomUntil;
        EnabledMessageTypes = store.EnabledMessageTypes.ToHashSet(StringComparer.OrdinalIgnoreCase);
        IncrementalExport = store.IncrementalExport;
        MapGroupNicknames = store.MapGroupNicknames;
        EnableSpeechToText = store.EnableSpeechToText;
        ApplyFavoriteFlags();
        OnPropertyChanged(nameof(ExportStyleSummary));
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

    public bool IncludeStickerGallery
    {
        get => _includeStickerGallery;
        set
        {
            if (_includeStickerGallery == value) return;
            _includeStickerGallery = value;
            OnPropertyChanged();
        }
    }

    public bool FolderIncludeCsv
    {
        get => _folderIncludeCsv;
        set
        {
            if (_folderIncludeCsv == value) return;
            _folderIncludeCsv = value;
            OnPropertyChanged();
        }
    }

    public bool FolderIncludeJson
    {
        get => _folderIncludeJson;
        set
        {
            if (_folderIncludeJson == value) return;
            _folderIncludeJson = value;
            OnPropertyChanged();
        }
    }

    public bool OpenFolderAfterExport
    {
        get => _openFolderAfterExport;
        set
        {
            if (_openFolderAfterExport == value) return;
            _openFolderAfterExport = value;
            OnPropertyChanged();
        }
    }

    public DateRangePreset DateRangePreset
    {
        get => _dateRangePreset;
        private set
        {
            if (_dateRangePreset == value) return;
            _dateRangePreset = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ExportStyleSummary));
        }
    }

    public DateTime CustomSince
    {
        get => _customSince;
        private set
        {
            if (_customSince == value) return;
            _customSince = value;
            OnPropertyChanged();
        }
    }

    public DateTime CustomUntil
    {
        get => _customUntil;
        private set
        {
            if (_customUntil == value) return;
            _customUntil = value;
            OnPropertyChanged();
        }
    }

    public HashSet<string> EnabledMessageTypes
    {
        get => _enabledMessageTypes;
        private set
        {
            _enabledMessageTypes = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(MessageTypeSummary));
            OnPropertyChanged(nameof(ExportStyleSummary));
        }
    }

    public bool IncrementalExport
    {
        get => _incrementalExport;
        private set
        {
            if (_incrementalExport == value) return;
            _incrementalExport = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ExportStyleSummary));
        }
    }

    public bool MapGroupNicknames
    {
        get => _mapGroupNicknames;
        private set
        {
            if (_mapGroupNicknames == value) return;
            _mapGroupNicknames = value;
            OnPropertyChanged();
        }
    }

    public bool EnableSpeechToText
    {
        get => _enableSpeechToText;
        private set
        {
            if (_enableSpeechToText == value) return;
            _enableSpeechToText = value;
            OnPropertyChanged();
        }
    }

    public bool ShowFavoritesOnly
    {
        get => _showFavoritesOnly;
        set
        {
            if (_showFavoritesOnly == value) return;
            _showFavoritesOnly = value;
            OnPropertyChanged();
            ContactsView.Refresh();
            OnPropertyChanged(nameof(FilteredCountText));
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
            OnPropertyChanged(nameof(IsMarkdownStyle));
            OnPropertyChanged(nameof(IsPdfStyle));
            OnPropertyChanged(nameof(ExportStyleDetail));
            OnPropertyChanged(nameof(ShowIncludeMediaToggle));
            OnPropertyChanged(nameof(ExportStyleSummary));
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

    public bool IsMarkdownStyle
    {
        get => ExportStyle == ExportStyle.Markdown;
        set { if (value) ExportStyle = ExportStyle.Markdown; }
    }

    public bool IsPdfStyle
    {
        get => ExportStyle == ExportStyle.Pdf;
        set { if (value) ExportStyle = ExportStyle.Pdf; }
    }

    public string ExportStyleDetail => ExportStyleInfo.Detail(ExportStyle);

    public string MessageTypeSummary
    {
        get
        {
            var all = MessageTypeFilterInfo.AllIds();
            if (EnabledMessageTypes.Count == 0 || all.All(id => EnabledMessageTypes.Contains(id)))
                return "全部类型";
            var titles = MessageTypeFilterInfo.All
                .Where(t => EnabledMessageTypes.Contains(MessageTypeFilterInfo.Id(t)))
                .Select(MessageTypeFilterInfo.Title);
            return string.Join("、", titles);
        }
    }

    public string ExportStyleSummary =>
        $"当前：{ExportStyleInfo.Title(ExportStyle)} · {ExportStyleDetail} · {DateRangePresetInfo.Title(DateRangePreset)} · {MessageTypeSummary}"
        + (IncrementalExport ? " · 增量导出" : "");

    public bool ShowIncludeMediaToggle => ExportStyle == ExportStyle.SingleHtml;

    public string CreditLine => AppSettings.CreditLine;

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
            OnPropertyChanged(nameof(CanRetryFailed));
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

    public bool CanRetryFailed => !IsBusy && _lastFailedIds.Count > 0;

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
        if (ShowFavoritesOnly && !contact.IsFavorite) return false;
        var q = SearchText.Trim();
        if (string.IsNullOrEmpty(q)) return true;
        return $"{contact.DisplayName} {contact.NickName} {contact.Remark} {contact.Id} {contact.Summary}"
            .Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    public void NotifySelectionChanged()
    {
        OnPropertyChanged(nameof(CanExport));
    }

    public void ToggleFavorite(ContactItem contact)
    {
        contact.IsFavorite = !contact.IsFavorite;
        var store = AppSettings.Shared;
        if (contact.IsFavorite)
            store.FavoriteIds.Add(contact.Id);
        else
            store.FavoriteIds.Remove(contact.Id);
        store.Save();
        ContactsView.Refresh();
        OnPropertyChanged(nameof(FilteredCountText));
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

        await ExportContactsAsync(selected, isRetry: false);
    }

    public async Task RetryFailedAsync()
    {
        if (IsBusy) return;
        var failed = _lastFailedIds
            .Select(id => Contacts.FirstOrDefault(c => string.Equals(c.Id, id, StringComparison.OrdinalIgnoreCase)))
            .Where(c => c is not null)
            .Cast<ContactItem>()
            .ToList();
        if (failed.Count == 0)
        {
            ShowAlert("没有可重试的失败会话。");
            return;
        }

        await ExportContactsAsync(failed, isRetry: true);
    }

    public async Task PreviewSelectedAsync()
    {
        if (IsBusy) return;
        var selected = SelectedContacts.ToList();
        if (selected.Count == 0)
        {
            ShowError("请先在列表中选择联系人或群聊。");
            return;
        }

        IsBusy = true;
        StatusText = "生成预览…";
        var previews = new List<ExportPreviewResult>();
        var failures = new List<string>();
        try
        {
            for (var index = 0; index < selected.Count; index++)
            {
                var contact = selected[index];
                OperationProgress = (double)index / selected.Count;
                OperationProgressLabel = $"正在预览 {contact.DisplayName}（{index + 1}/{selected.Count}）…";
                var tempDir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"WeChatExporter-preview-{Guid.NewGuid():N}");
                try
                {
                    var options = BuildExportOptions(contact, includeMedia: false, allowEmpty: true, progress: (p, label) =>
                    {
                        OperationProgress = (index + p) / selected.Count;
                        OperationProgressLabel = $"正在预览 {contact.DisplayName}：{label}";
                    });
                    await _wxCli.ExportAsync(contact, tempDir, options, AppendLog);
                    previews.Add(ChatJsonProcessor.Preview(System.IO.Path.Combine(tempDir, "chat.json"), tempDir));
                }
                catch (Exception ex)
                {
                    failures.Add($"• {contact.DisplayName}：{ex.Message}");
                    AppendLog($"预览失败：{contact.DisplayName} — {ex.Message}");
                }
                finally
                {
                    try { if (System.IO.Directory.Exists(tempDir)) System.IO.Directory.Delete(tempDir, true); } catch { /* ignore */ }
                }
            }

            var byType = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var preview in previews)
            {
                foreach (var kv in preview.ByType)
                    byType[kv.Key] = byType.TryGetValue(kv.Key, out var n) ? n + kv.Value : kv.Value;
            }
            var total = new ExportPreviewResult(
                selected.Count,
                previews.Sum(p => p.MessageCount),
                previews.Sum(p => p.MediaCount),
                previews.Sum(p => p.EstimatedBytes),
                byType);
            var failedText = failures.Count == 0 ? "" : $"\n\n失败：\n{string.Join('\n', failures)}";
            ShowAlert($"导出预览：\n{total.SummaryText}{failedText}");
        }
        finally
        {
            IsBusy = false;
            StatusText = "就绪";
            ClearProgress();
        }
    }

    public async Task EnvironmentCheckAsync()
    {
        if (IsBusy) return;
        IsBusy = true;
        StatusText = "环境检测…";
        try
        {
            var result = await _wxCli.EnvironmentCheckAsync(AppendLog);
            ShowAlert($"环境检测结果：\n\n{result.Report}");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        finally
        {
            IsBusy = false;
            StatusText = "就绪";
        }
    }

    private async Task ExportContactsAsync(List<ContactItem> selected, bool isRetry)
    {
        IsBusy = true;
        StatusText = isRetry ? "重试导出中…" : "导出中…";
        var summary = new List<string>();
        var failures = new List<string>();
        var failedIds = new List<string>();
        try
        {
            System.IO.Directory.CreateDirectory(ExportPath);
            var style = ExportStyle;
            var wantMedia = style == ExportStyle.FolderBundle || (style == ExportStyle.SingleHtml && IncludeMedia);
            var wantStickers = IncludeStickerGallery && wantMedia;

            if (wantStickers)
            {
                var stickerTemp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"WeChatExporter-stickers-{Guid.NewGuid():N}");
                try
                {
                    var stickerCount = await StickerPackExporter.ExportAllPacksAsync(stickerTemp, AppendLog);
                    if (stickerCount > 0)
                    {
                        var galleryPath = SingleFileExporter.WriteStickerGallery(stickerTemp, ExportPath);
                        if (galleryPath is not null)
                            summary.Add($"• 全部表情包：{stickerCount} 张 → {System.IO.Path.GetFileName(galleryPath)}");
                    }
                }
                finally
                {
                    try { if (System.IO.Directory.Exists(stickerTemp)) System.IO.Directory.Delete(stickerTemp, true); } catch { /* ignore */ }
                }
            }

            for (var index = 0; index < selected.Count; index++)
            {
                var contact = selected[index];
                OperationProgress = (double)index / selected.Count;
                OperationProgressLabel = $"正在导出 {contact.DisplayName}（{index + 1}/{selected.Count}）…";

                var tempDir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"WeChatExporter-{Guid.NewGuid():N}");
                try
                {
                    var options = BuildExportOptions(contact, wantMedia, allowEmpty: true, progress: (p, label) =>
                    {
                        OperationProgress = (index + p) / selected.Count;
                        OperationProgressLabel = $"正在导出 {contact.DisplayName}：{label}";
                    });
                    var count = await _wxCli.ExportAsync(contact, tempDir, options, AppendLog);
                    var latest = ChatJsonProcessor.LatestCreateTime(System.IO.Path.Combine(tempDir, "chat.json"));
                    if (latest is long last)
                        ExportCursorStore.Remember(contact.Id, last);

                    if (count <= 0)
                    {
                        summary.Add($"• {contact.DisplayName}：无新增消息");
                    }
                    else if (style == ExportStyle.FolderBundle)
                    {
                        var result = FolderBundleExporter.Write(
                            tempDir,
                            contact.DisplayName,
                            ExportPath,
                            AppendLog,
                            FolderIncludeCsv,
                            FolderIncludeJson);
                        summary.Add(
                            $"• {contact.DisplayName}：{count} 条 → {System.IO.Path.GetFileName(result.FolderPath)}/（图{result.ImageCount}/音{result.AudioCount}/视{result.VideoCount}）");
                    }
                    else if (style == ExportStyle.Markdown)
                    {
                        var markdownPath = MarkdownExporter.Write(tempDir, contact.DisplayName, ExportPath);
                        summary.Add($"• {contact.DisplayName}：{count} 条 → {System.IO.Path.GetFileName(markdownPath)}");
                    }
                    else if (style == ExportStyle.Pdf)
                    {
                        var pdfPath = PdfExporter.Write(tempDir, contact.DisplayName, ExportPath);
                        summary.Add($"• {contact.DisplayName}：{count} 条 → {System.IO.Path.GetFileName(pdfPath)}（另附 UTF-8 文本）");
                    }
                    else
                    {
                        var htmlPath = SingleFileExporter.WriteHtml(tempDir, contact.DisplayName, ExportPath);
                        summary.Add($"• {contact.DisplayName}：{count} 条 → {System.IO.Path.GetFileName(htmlPath)}");
                    }
                }
                catch (Exception ex)
                {
                    failedIds.Add(contact.Id);
                    failures.Add($"• {contact.DisplayName}：{ex.Message}");
                    AppendLog($"导出失败：{contact.DisplayName} — {ex.Message}");
                }
                finally
                {
                    try { if (System.IO.Directory.Exists(tempDir)) System.IO.Directory.Delete(tempDir, true); } catch { /* ignore */ }
                }
            }

            _lastFailedIds.Clear();
            _lastFailedIds.AddRange(failedIds);
            OnPropertyChanged(nameof(CanRetryFailed));

            if (summary.Count == 0)
            {
                ShowError($"全部导出失败（共 {selected.Count} 个会话）：\n{string.Join('\n', failures)}");
            }
            else if (failures.Count == 0)
            {
                var tip = style switch
                {
                    ExportStyle.FolderBundle => "每个会话一个文件夹：文字记录.txt + 图片/音频/视频/表情 分目录。",
                    ExportStyle.Markdown => "Markdown 文件可导入笔记软件或继续编辑。",
                    ExportStyle.Pdf => "PDF 适合归档与打印；中文全文保存在同名 _pdf内容.txt。",
                    _ => "用浏览器打开 .html 即可查看全部内容（媒体已内嵌）。"
                };
                ShowAlert($"已导出 {summary.Count} 项到：\n{ExportPath}\n\n{string.Join('\n', summary)}\n\n{tip}");
                if (OpenFolderAfterExport)
                    OpenExportFolder();
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
        {
            ExportPath = dialog.FolderName;
            AppSettings.Shared.ExportPath = dialog.FolderName;
            AppSettings.Shared.Save();
        }
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
            {
                item.IsFavorite = AppSettings.Shared.FavoriteIds.Contains(item.Id);
                Contacts.Add(item);
            }
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

    private WxCliService.ExportOptions BuildExportOptions(
        ContactItem contact,
        bool includeMedia,
        bool allowEmpty,
        Action<double, string>? progress)
    {
        var (since, until) = ResolvedDateRangeFromFields();
        var sinceUnix = since is DateTime s ? ToUnixSeconds(s, endOfDay: false) : (long?)null;
        var untilUnix = until is DateTime u ? ToUnixSeconds(u, endOfDay: true) : (long?)null;
        var cliSince = since?.Date;
        var cliUntil = until?.Date;

        if (IncrementalExport && ExportCursorStore.LastExportedTime(contact.Id) is long lastExported)
        {
            var cursorSince = lastExported + 1;
            if (sinceUnix is null || cursorSince > sinceUnix.Value)
            {
                sinceUnix = cursorSince;
                cliSince = DateTimeOffset.FromUnixTimeSeconds(cursorSince).LocalDateTime.Date;
            }
        }

        return new WxCliService.ExportOptions
        {
            IncludeMedia = includeMedia,
            Since = cliSince,
            Until = cliUntil,
            FilterOptions = new ChatJsonFilterOptions
            {
                SinceUnix = sinceUnix,
                UntilUnix = untilUnix,
                EnabledTypes = EnabledMessageTypes.ToHashSet(StringComparer.OrdinalIgnoreCase)
            },
            MapGroupNicknames = MapGroupNicknames,
            EnableSpeechToText = EnableSpeechToText,
            AllowEmptyResults = allowEmpty,
            Progress = progress
        };
    }

    private (DateTime? since, DateTime? until) ResolvedDateRangeFromFields()
    {
        var now = DateTime.Now;
        return DateRangePreset switch
        {
            DateRangePreset.Last7Days => (now.AddDays(-7), now),
            DateRangePreset.Last30Days => (now.AddDays(-30), now),
            DateRangePreset.Last90Days => (now.AddDays(-90), now),
            DateRangePreset.Last365Days => (now.AddDays(-365), now),
            DateRangePreset.Custom => (CustomSince, CustomUntil),
            _ => (null, null)
        };
    }

    private static long ToUnixSeconds(DateTime value, bool endOfDay)
    {
        var adjusted = endOfDay && value.TimeOfDay == TimeSpan.Zero
            ? value.Date.AddDays(1).AddTicks(-1)
            : value;
        if (adjusted.Kind == DateTimeKind.Unspecified)
            adjusted = DateTime.SpecifyKind(adjusted, DateTimeKind.Local);
        return new DateTimeOffset(adjusted).ToUnixTimeSeconds();
    }

    private void ApplyFavoriteFlags()
    {
        var favorites = AppSettings.Shared.FavoriteIds;
        foreach (var contact in Contacts)
            contact.IsFavorite = favorites.Contains(contact.Id);
        ContactsView.Refresh();
        OnPropertyChanged(nameof(FilteredCountText));
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
