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
    private readonly object _logGate = new();
    private readonly List<string> _pendingLogLines = [];
    private bool _logFlushQueued;
    private string _searchText = "";
    private string _exportPath;
    private string _exportPassword = "";
    private string _statusText = "就绪";
    private bool _isBusy;
    private bool _isDataReady;
    private bool _includeMedia;
    private bool _diagnosticsConsented;
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
        _diagnosticsConsented = DiagnosticUploader.IsConsented;
        // v2.19 设置项：从 settings.json 恢复（键名与 macOS 完全一致）
        _searchIndexEnabled = AppSettings.SearchIndexEnabled;
        _anonEnabled = AppSettings.AnonEnabled;
        _anonMaskPii = AppSettings.AnonMaskPii;
        _anonKeepMapping = AppSettings.AnonKeepMapping;
        _filterEnabled = AppSettings.FilterEnabled;
        _filterFromDate = AppSettings.FilterFromDate;
        _filterToDate = AppSettings.FilterToDate;
        _filterKeywords = AppSettings.FilterKeywords;
        _annualReportEnabled = AppSettings.AnnualReportEnabled;
        _calendarExtractEnabled = AppSettings.CalendarExtractEnabled;
        _autoSyncEnabled = AppSettings.AutoSyncEnabled;
        _autoSyncIntervalMinutes = AppSettings.AutoSyncIntervalMinutes;
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

    /// <summary>是否报错时自动上传诊断日志（与 settings.json 双向同步，即时生效）。</summary>
    public bool DiagnosticsConsented
    {
        get => _diagnosticsConsented;
        set
        {
            if (_diagnosticsConsented == value) return;
            _diagnosticsConsented = value;
            OnPropertyChanged();
            DiagnosticUploader.SetConsent(value);
        }
    }

    private bool _voiceTranscriptionEnabled = true;

    /// <summary>导出媒体时是否顺带做本地离线语音转文字（whisper.cpp，默认开启；缺工具自动跳过）。</summary>
    public bool VoiceTranscriptionEnabled
    {
        get => _voiceTranscriptionEnabled;
        set
        {
            if (_voiceTranscriptionEnabled == value) return;
            _voiceTranscriptionEnabled = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(VoiceTranscriptStatus));
        }
    }

    /// <summary>语音转文字工具就绪状态（设置面板展示）。</summary>
    public string VoiceTranscriptStatus
    {
        get
        {
            var cli = VoiceTranscriber.LocateWhisperCli();
            var model = VoiceTranscriber.LocateWhisperModel();
            var s2w = VoiceTranscriber.LocateSilk2wav();
            if (cli == null || model == null)
                return VoiceTranscriptionEnabled
                    ? "未检测到 whisper.cpp，导出时自动跳过；可点击「下载 whisper 模型」安装"
                    : "未检测到 whisper.cpp（功能已关闭）";
            var detail = $"whisper 模型：{Path.GetFileName(model)}";
            detail += s2w != null ? " · SILK 解码器已内置" : " · 缺少 SILK 解码器（仅 .silk 语音不可转）";
            return detail;
        }
    }

    private bool _ocrEnabled = true;

    /// <summary>导出媒体时是否对图片做本地离线 OCR（Windows.Media.Ocr，默认开启）。</summary>
    public bool OcrEnabled
    {
        get => _ocrEnabled;
        set
        {
            if (_ocrEnabled == value) return;
            _ocrEnabled = value;
            OnPropertyChanged();
        }
    }

    private bool _statsReportEnabled = true;

    /// <summary>导出时是否顺带生成聊天统计报告（本地聚合 chat.json，默认开启）。</summary>
    public bool StatsReportEnabled
    {
        get => _statsReportEnabled;
        set
        {
            if (_statsReportEnabled == value) return;
            _statsReportEnabled = value;
            OnPropertyChanged();
        }
    }

    private bool _incrementalExportEnabled;

    /// <summary>只导出上次之后的新增消息（按联系人+目录记忆游标，默认关闭）。</summary>
    public bool IncrementalExportEnabled
    {
        get => _incrementalExportEnabled;
        set
        {
            if (_incrementalExportEnabled == value) return;
            _incrementalExportEnabled = value;
            OnPropertyChanged();
        }
    }

    private bool _indexPageEnabled = true;

    /// <summary>导出后生成目录导航页 index.html（文件列表 + 全文检索框，默认开启）。</summary>
    public bool IndexPageEnabled
    {
        get => _indexPageEnabled;
        set
        {
            if (_indexPageEnabled == value) return;
            _indexPageEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>加密导出密码（仅内存持有，不落盘；留空 = 不加密，导出明文目录）。</summary>
    public string ExportPassword
    {
        get => _exportPassword;
        set
        {
            if (_exportPassword == value) return;
            _exportPassword = value;
            OnPropertyChanged();
        }
    }

    /// <summary>导出产物是否平铺视觉水印（默认开启；关闭即无水印版本，持久化 settings.json）。</summary>
    public bool WatermarkEnabled
    {
        get => Watermark.Enabled;
        set
        {
            if (Watermark.Enabled == value) return;
            Watermark.Enabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>水印文字（默认「林琝淏科技集团有限公司」，可改，持久化 settings.json）。</summary>
    public string WatermarkText
    {
        get => Watermark.Text;
        set
        {
            if (Watermark.Text == value) return;
            Watermark.Text = value;
            OnPropertyChanged();
        }
    }

    // MARK: - v2.19 新功能设置（SPEC：docs/MULTIPLATFORM_SPEC.md，键名与 macOS 完全一致）

    private bool _searchIndexEnabled = true;
    private bool _anonEnabled;
    private bool _anonMaskPii = true;
    private bool _anonKeepMapping = true;
    private bool _filterEnabled;
    private string _filterFromDate = "";
    private string _filterToDate = "";
    private string _filterKeywords = "";
    private bool _annualReportEnabled = true;
    private bool _calendarExtractEnabled = true;
    private bool _autoSyncEnabled;
    private int _autoSyncIntervalMinutes = 60;

    /// <summary>导出时在根目录生成 wce-search.sqlite 全文搜索索引（默认开启）。</summary>
    public bool SearchIndexEnabled
    {
        get => _searchIndexEnabled;
        set
        {
            if (_searchIndexEnabled == value) return;
            _searchIndexEnabled = value;
            AppSettings.SearchIndexEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>脱敏导出总开关（默认关闭）。</summary>
    public bool AnonEnabled
    {
        get => _anonEnabled;
        set
        {
            if (_anonEnabled == value) return;
            _anonEnabled = value;
            AppSettings.AnonEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>脱敏时是否同时模糊化 PII（手机号/身份证/邮箱，默认开启）。</summary>
    public bool AnonMaskPii
    {
        get => _anonMaskPii;
        set
        {
            if (_anonMaskPii == value) return;
            _anonMaskPii = value;
            AppSettings.AnonMaskPii = value;
            OnPropertyChanged();
        }
    }

    /// <summary>脱敏后是否保留映射文件（可逆；关闭=导出后销毁）。</summary>
    public bool AnonKeepMapping
    {
        get => _anonKeepMapping;
        set
        {
            if (_anonKeepMapping == value) return;
            _anonKeepMapping = value;
            AppSettings.AnonKeepMapping = value;
            OnPropertyChanged();
        }
    }

    /// <summary>过滤导出总开关（默认关闭）。</summary>
    public bool FilterEnabled
    {
        get => _filterEnabled;
        set
        {
            if (_filterEnabled == value) return;
            _filterEnabled = value;
            AppSettings.FilterEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>过滤起始日期 yyyy-MM-dd（含；空=不限）。</summary>
    public string FilterFromDate
    {
        get => _filterFromDate;
        set
        {
            if (_filterFromDate == value) return;
            _filterFromDate = value;
            AppSettings.FilterFromDate = value;
            OnPropertyChanged();
        }
    }

    /// <summary>过滤结束日期 yyyy-MM-dd（含；空=不限）。</summary>
    public string FilterToDate
    {
        get => _filterToDate;
        set
        {
            if (_filterToDate == value) return;
            _filterToDate = value;
            AppSettings.FilterToDate = value;
            OnPropertyChanged();
        }
    }

    /// <summary>过滤关键词（逗号分隔，不区分大小写；空=不过滤内容）。</summary>
    public string FilterKeywords
    {
        get => _filterKeywords;
        set
        {
            if (_filterKeywords == value) return;
            _filterKeywords = value;
            AppSettings.FilterKeywords = value;
            OnPropertyChanged();
        }
    }

    /// <summary>生成年度可视化报告 HTML（默认开启）。</summary>
    public bool AnnualReportEnabled
    {
        get => _annualReportEnabled;
        set
        {
            if (_annualReportEnabled == value) return;
            _annualReportEnabled = value;
            AppSettings.AnnualReportEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>提取日历事件 .ics/.json（默认开启）。</summary>
    public bool CalendarExtractEnabled
    {
        get => _calendarExtractEnabled;
        set
        {
            if (_calendarExtractEnabled == value) return;
            _calendarExtractEnabled = value;
            AppSettings.CalendarExtractEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>定时增量导出总开关（默认关闭）。</summary>
    public bool AutoSyncEnabled
    {
        get => _autoSyncEnabled;
        set
        {
            if (_autoSyncEnabled == value) return;
            _autoSyncEnabled = value;
            AppSettings.AutoSyncEnabled = value;
            OnPropertyChanged();
        }
    }

    /// <summary>定时间隔分钟数（默认 60，最小 5）。</summary>
    public int AutoSyncIntervalMinutes
    {
        get => _autoSyncIntervalMinutes;
        set
        {
            if (_autoSyncIntervalMinutes == value) return;
            _autoSyncIntervalMinutes = value;
            AppSettings.AutoSyncIntervalMinutes = value;
            OnPropertyChanged();
        }
    }

    /// <summary>定时任务当前是否已安装（schtasks），展示用文案。</summary>
    public string AutoSyncInstalled => AutoSyncScheduler.IsInstalled ? "已安装" : "未安装";

    /// <summary>上次定时运行时间（ISO 本地）。</summary>
    public string AutoSyncLastRun => AppSettings.AutoSyncLastRun;

    /// <summary>安装定时任务（schtasks）：把当前选中的会话子集与间隔写入。</summary>
    public void InstallAutoSyncTask()
    {
        var idsJson = AppSettings.AutoSyncContactIDs;
        if (string.IsNullOrWhiteSpace(idsJson) || idsJson == "[]")
        {
            idsJson = System.Text.Json.JsonSerializer.Serialize(SelectedContacts.Select(c => c.Id).ToList());
        }
        AppSettings.AutoSyncContactIDs = idsJson;
        var dir = string.IsNullOrWhiteSpace(AppSettings.AutoSyncExportDir) ? ExportPath : AppSettings.AutoSyncExportDir;
        AppSettings.AutoSyncExportDir = dir;
        var ok = AutoSyncScheduler.Install(Math.Max(5, AutoSyncIntervalMinutes), dir, idsJson, AppendLog);
        AppendLog(ok ? $"定时增量导出已安装（每 {Math.Max(5, AutoSyncIntervalMinutes)} 分钟）" : "定时任务安装失败，详见日志");
        OnPropertyChanged(nameof(AutoSyncInstalled));
    }

    public void UninstallAutoSyncTask()
    {
        AutoSyncScheduler.Uninstall(AppendLog);
        OnPropertyChanged(nameof(AutoSyncInstalled));
    }

    // MARK: - 搜索面板（SPEC §1）

    private string _searchKeyword = "";
    private bool _searchIndexAvailable;

    /// <summary>搜索关键词（绑定搜索框）。</summary>
    public string SearchKeyword
    {
        get => _searchKeyword;
        set
        {
            if (_searchKeyword == value) return;
            _searchKeyword = value;
            OnPropertyChanged();
        }
    }

    /// <summary>搜索命中结果。</summary>
    public ObservableCollection<SearchIndexService.Hit> SearchHits { get; } = [];

    /// <summary>搜索索引是否可用（上次运行搜索时判定）。</summary>
    public bool SearchIndexAvailable
    {
        get => _searchIndexAvailable;
        private set
        {
            if (_searchIndexAvailable == value) return;
            _searchIndexAvailable = value;
            OnPropertyChanged();
        }
    }

    /// <summary>执行全文搜索（最近一次导出目录的 wce-search.sqlite）。</summary>
    public void RunSearch()
    {
        var kw = SearchKeyword.Trim();
        SearchHits.Clear();
        if (kw.Length == 0) return;
        var dir = string.IsNullOrWhiteSpace(AppSettings.LastExportDir) ? ExportPath : AppSettings.LastExportDir;
        var indexPath = Path.Combine(dir, SearchIndexService.FileName);
        var db = SearchIndexService.Open(indexPath);
        if (db is null)
        {
            SearchIndexAvailable = false;
            AppendLog($"搜索索引不存在（{SearchIndexService.FileName}），请先导出并开启「搜索索引」");
            return;
        }
        using (db)
        {
            SearchIndexAvailable = true;
            foreach (var hit in SearchIndexService.Query(db, kw, 200))
                SearchHits.Add(hit);
            AppendLog($"全文搜索「{kw}」：{SearchHits.Count} 条命中");
        }
    }

    /// <summary>定位命中消息所在会话的 chat.txt（用系统程序打开）。</summary>
    public void OpenSearchHit(SearchIndexService.Hit hit)
    {
        var dir = string.IsNullOrWhiteSpace(AppSettings.LastExportDir) ? ExportPath : AppSettings.LastExportDir;
        var baseDir = dir;
        var candidates = new[]
        {
            Path.Combine(baseDir, hit.Chat, "chat.txt"),
            Path.Combine(baseDir, hit.Chat, "文字", "chat.txt"),
        };
        foreach (var c in candidates)
        {
            if (File.Exists(c))
            {
                ProcessHelper.OpenFolder(c);
                return;
            }
        }
        ProcessHelper.OpenFolder(baseDir);
    }

    /// <summary>重建搜索索引（不导出）。</summary>
    public void RebuildSearchIndex()
    {
        var dir = string.IsNullOrWhiteSpace(AppSettings.LastExportDir) ? ExportPath : AppSettings.LastExportDir;
        var n = SearchIndexService.Build(dir, AppendLog);
        if (n == 0) SearchIndexAvailable = false;
        RunSearch();
    }

    /// <summary>解密 .wxenc 加密导出包到导出目录</summary>
    public void DecryptEncryptedExport()
    {
        if (string.IsNullOrEmpty(_exportPassword))
        {
            ShowError("请先在「加密导出」卡片输入密码，再执行解密。");
            return;
        }
        var dialog = new OpenFileDialog
        {
            Title = "选择加密导出文件 (.wxenc)",
            Filter = "加密导出文件 (*.wxenc)|*.wxenc",
            InitialDirectory = Directory.Exists(_exportPath) ? _exportPath : null,
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            var n = EncryptedExport.DecryptFile(dialog.FileName, _exportPassword, _exportPath, AppendLog);
            ShowAlert($"解密完成：{n} 个文件 → {_exportPath}");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private bool _ebookEpubEnabled = true;

    /// <summary>导出时是否顺带生成 EPUB 电子书（本地离线，默认开启）。</summary>
    public bool EbookEpubEnabled
    {
        get => _ebookEpubEnabled;
        set
        {
            if (_ebookEpubEnabled == value) return;
            _ebookEpubEnabled = value;
            OnPropertyChanged();
        }
    }

    private bool _ebookDocumentEnabled = true;

    /// <summary>导出时是否顺带生成文档版（A4 打印版 HTML，浏览器可打印/另存 PDF，默认开启）。</summary>
    public bool EbookDocumentEnabled
    {
        get => _ebookDocumentEnabled;
        set
        {
            if (_ebookDocumentEnabled == value) return;
            _ebookDocumentEnabled = value;
            OnPropertyChanged();
        }
    }

    public bool IsDownloadingWhisperModel
    {
        get => _isDownloadingWhisperModel;
        private set
        {
            if (_isDownloadingWhisperModel == value) return;
            _isDownloadingWhisperModel = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(VoiceTranscriptStatus));
        }
    }
    private bool _isDownloadingWhisperModel;

    /// <summary>下载 whisper 模型（约 141MB）。</summary>
    public async Task DownloadWhisperModelAsync()
    {
        if (IsDownloadingWhisperModel) return;
        IsDownloadingWhisperModel = true;
        try
        {
            var (ok, message) = await VoiceTranscriber.DownloadModelAsync(
                progress: (_, text) => AppendLog($"模型下载 {text}"),
                log: AppendLog);
            if (ok)
            {
                ShowAlert($"whisper 模型已就绪：\n{message}\n\n请再安装 whisper-cli（GitHub：ggml-org/whisper.cpp releases 下载 whisper-cli.exe，放入程序目录或 PATH）。");
                OnPropertyChanged(nameof(VoiceTranscriptStatus));
            }
            else
            {
                ShowError($"whisper 模型下载失败：{message}");
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ShowError($"whisper 模型下载失败：{ex.Message}");
        }
        finally
        {
            IsDownloadingWhisperModel = false;
        }
    }

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
            ReportDiagnostic("prepare", ex.Message);
            // 数据目录相关失败 → 询问用户手动选择微信数据目录
            if (ex.Message.Contains("数据目录", StringComparison.OrdinalIgnoreCase)
                || ex.Message.Contains("db_dir", StringComparison.OrdinalIgnoreCase))
            {
                await PromptManualDataDirAsync();
            }
        }
        finally
        {
            IsBusy = false;
            StatusText = "就绪";
            ClearProgress();
        }
    }

    /// <summary>询问用户手动选择微信数据目录，保存后自动重试初始化。</summary>
    private async Task PromptManualDataDirAsync()
    {
        var choice = MessageBox.Show(
            "未能自动定位微信数据目录。是否手动选择？\n\n" +
            "请选择包含 db_storage 的账号目录，例如：\n" +
            "…\\xwechat_files\\wxid_xxxxxxxx_xxxx\\（也可直接选其中的 db_storage 文件夹）",
            "手动指定微信数据目录", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (choice != MessageBoxResult.Yes) return;

        var dialog = new OpenFolderDialog
        {
            Title = "请选择微信数据目录（含 db_storage 的 wxid 账号目录）",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        if (dialog.ShowDialog() != true) return;
        var chosen = dialog.FolderName;
        if (string.IsNullOrWhiteSpace(chosen)) return;

        AppendLog($"手动指定数据目录：{chosen}");
        try
        {
            await _wxCli.SetCustomDataDirAsync(chosen);
            AppendLog("已保存数据目录配置，正在重新初始化…");
            StatusText = "准备数据中…";
            await _wxCli.PrepareDataAsync(AppendLog, ReportProgress);
            await LoadContactsInternalAsync(showErrorDialog: true);
            ShowAlert("数据准备完成，现在可以导出聊天记录了。");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
            ReportDiagnostic("prepare", ex.Message);
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
        if (SelectedContacts.Count == 0)
        {
            ShowError("请先在列表中选择联系人或群聊。");
            return;
        }

        IsBusy = true;
        StatusText = "导出中…";
        var summary = new List<string>();
        try
        {
            Directory.CreateDirectory(ExportPath);
            if (IncludeMedia)
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

            foreach (var contact in SelectedContacts.ToList())
            {
                var tempDir = Path.Combine(Path.GetTempPath(), $"WeChatExporter-{Guid.NewGuid():N}");
                try
                {
                    var count = await _wxCli.ExportAsync(contact, tempDir, IncludeMedia, AppendLog);
                    // 语音转文字（本地离线 whisper.cpp，缺工具自动跳过）
                    if (IncludeMedia && VoiceTranscriber.IsAvailable())
                    {
                        VoiceTranscriber.TranscribeAll(tempDir, AppendLog);
                    }
                    // 图片 OCR（本地离线 Windows.Media.Ocr）
                    if (IncludeMedia && OcrEnabled)
                    {
                        ImageOcrService.OcrAll(tempDir, AppendLog);
                    }
                    // 增量导出：过滤为只保留上次游标之后的新增消息
                    if (IncrementalExportEnabled)
                    {
                        var lastTs = IncrementalExport.LoadCursor(contact.Id, ExportPath);
                        if (lastTs is { } after)
                        {
                            count = IncrementalExport.FilterArtifacts(tempDir, contact.Id, after, AppendLog);
                            if (count == 0)
                            {
                                summary.Add($"• {contact.DisplayName}：无新增消息，已跳过");
                                continue;
                            }
                            var maxTs = IncrementalExport.MaxTimestamp(tempDir);
                            if (maxTs > after)
                                IncrementalExport.SaveCursor(contact.Id, ExportPath, maxTs);
                        }
                        else
                        {
                            IncrementalExport.SaveCursor(contact.Id, ExportPath, IncrementalExport.MaxTimestamp(tempDir));
                        }
                    }
                    // v2.19：把文字产物（chat.json/txt/csv）复制到导出根目录/<会话名>/，
                    // 供全文搜索索引 / 脱敏 / 过滤 / 年度报告 / 日历提取使用（与 macOS textOnly 布局同口径）
                    var sessionDir = Path.Combine(ExportPath, ExportArtifacts.SanitizeDirName(contact.DisplayName));
                    ExportArtifacts.CopyTextArtifacts(tempDir, sessionDir);

                    var htmlPath = SingleFileExporter.WriteHtml(tempDir, contact.DisplayName, ExportPath);
                    summary.Add($"• {contact.DisplayName}：{count} 条 → {Path.GetFileName(htmlPath)}");
                    // 统计报告（本地聚合 chat.json，生成单文件 HTML）
                    if (StatsReportEnabled)
                    {
                        var reportPath = ChatStatsReport.WriteReport(tempDir, contact.DisplayName, ExportPath, AppendLog);
                        if (reportPath is not null)
                            summary.Add($"• {contact.DisplayName} 统计报告 → {Path.GetFileName(reportPath)}");
                    }
                    // 电子书 / 文档版（本地聚合 chat.json，生成 EPUB 与打印版文档）
                    if (EbookEpubEnabled)
                    {
                        var epubPath = EBookExporter.WriteEpub(tempDir, contact.DisplayName, ExportPath, AppendLog);
                        if (epubPath is not null)
                            summary.Add($"• {contact.DisplayName} EPUB → {Path.GetFileName(epubPath)}");
                    }
                    if (EbookDocumentEnabled)
                    {
                        var docPath = EBookExporter.WriteDocument(tempDir, contact.DisplayName, ExportPath, AppendLog);
                        if (docPath is not null)
                            summary.Add($"• {contact.DisplayName} 文档版 → {Path.GetFileName(docPath)}");
                    }
                }
                finally
                {
                    try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true); } catch { /* ignore */ }
                }
            }

            // 目录导航页 + 全文检索（扫描导出目录，生成 index.html）
            if (IndexPageEnabled)
            {
                ExportIndexBuilder.WriteIndex(ExportPath, AppendLog);
            }

            // v2.19 全局后处理管线（SPEC §3 顺序：过滤 → 脱敏 → 搜索索引 → 年报/日历 → 水印）
            if (FilterEnabled)
            {
                _ = ExportFilterService.Apply(ExportPath, FilterFromDate, FilterToDate, FilterKeywords, AppendLog);
            }
            if (AnonEnabled)
            {
                var names = AnonymizationService.CollectNames(ExportPath);
                _ = AnonymizationService.Anonymize(ExportPath, names,
                    new AnonymizationService.Settings(AnonMaskPii, AnonKeepMapping), AppendLog);
                summary.Add(AnonKeepMapping
                    ? "🕶 已脱敏（映射文件在导出根目录，可逆）"
                    : "🕶 已脱敏（不可逆，映射已销毁）");
            }
            if (SearchIndexEnabled)
            {
                _ = SearchIndexService.Build(ExportPath, AppendLog);
            }
            if (AnnualReportEnabled)
            {
                _ = AnnualReportService.Write(ExportPath, AppendLog);
            }
            if (CalendarExtractEnabled)
            {
                _ = CalendarExtractService.Extract(ExportPath, AppendLog);
            }

            // 导出水印：兜底扫描导出目录全部 HTML（幂等，已注入的跳过），缺水印层的补上
            if (WatermarkEnabled)
            {
                Watermark.ApplyToDirectory(ExportPath, AppendLog);
            }

            // 记录最近导出目录（搜索面板 / wce CLI 用它定位索引）
            AppSettings.LastExportDir = ExportPath;

            // 加密导出（密码非空 → 整体加密为 .wxenc 并删除明文目录）
            if (!string.IsNullOrEmpty(ExportPassword))
            {
                var encFile = Path.Combine(ExportPath, "加密导出.wxenc");
                EncryptedExport.EncryptDirectory(ExportPath, ExportPassword, encFile, AppendLog);
                Directory.Delete(ExportPath, true);
                summary.Add($"🔒 已加密为 {encFile}，明文目录已删除；用「解密导出」恢复");
            }

            ShowAlert($"已导出 {SelectedContacts.Count} 个单文件到：\n{ExportPath}\n\n{string.Join('\n', summary)}\n\n用浏览器打开 .html 即可查看全部内容（媒体已内嵌）。");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
            ReportDiagnostic("export", ex.Message);
        }
        finally
        {
            IsBusy = false;
            StatusText = "就绪";
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
            ReportDiagnostic("load_sessions", ex.Message);
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
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.HasShutdownStarted) return;
        // 异步派发：ticker/日志线程不会被 UI 队列阻塞（#35：同步 Invoke 在日志风暴下会冻结窗口）
        dispatcher.BeginInvoke(new Action(() =>
        {
            OperationProgress = update.Fraction;
            OperationProgressLabel = update.Message;
        }));
    }

    private void ClearProgress()
    {
        OperationProgress = null;
        OperationProgressLabel = "";
    }

    /// <summary>
    /// 线程安全的日志写入：后台线程只入队（O(1)），UI 线程按帧批量刷新。
    /// 避免 wx-cli 高频输出时同步 Dispatcher.Invoke 把 UI 线程淹没（#35）。
    /// </summary>
    private void AppendLog(string message)
    {
        var line = message.Trim();
        if (string.IsNullOrEmpty(line)) return;

        lock (_logGate)
        {
            _pendingLogLines.Add(line);
            if (_logFlushQueued) return;
            _logFlushQueued = true;
        }

        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.HasShutdownStarted) return;
        dispatcher.BeginInvoke(new Action(FlushLogs));
    }

    private void FlushLogs()
    {
        List<string> batch;
        lock (_logGate)
        {
            batch = [.. _pendingLogLines];
            _pendingLogLines.Clear();
            _logFlushQueued = false;
        }
        if (batch.Count == 0) return;

        // 单帧最多刷 100 行：日志风暴时丢弃中间行，保证窗口始终可响应
        if (batch.Count > 100)
            batch = batch[^100..];

        foreach (var line in batch)
            Logs.Add(line);
        while (Logs.Count > 300)
            Logs.RemoveAt(0);
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

    /// <summary>fire-and-forget 上报诊断信息：快照当前日志后交给 DiagnosticUploader，失败静默。</summary>
    private void ReportDiagnostic(string stage, string error)
    {
        try
        {
            var snapshot = Logs.ToList();
            _ = DiagnosticUploader.ReportIfAllowedAsync(stage, error, snapshot);
        }
        catch
        {
            // 诊断上报自身异常静默，绝不影响业务。
        }
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
