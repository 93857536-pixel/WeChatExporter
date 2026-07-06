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
    private string? _alertMessage;

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
            if (IsBusy) return "正在处理，请稍候…";
            if (IsDataReady) return $"已就绪 · 共 {Contacts.Count} 个会话，选择后点击「导出选中」";
            if (!IsRunningAsAdmin)
                return "首次使用：请先以管理员身份运行，再点击「准备数据」（需微信 PC 版已登录）";
            return "首次使用：请点击「准备数据」（需微信 PC 版已登录）";
        }
    }

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
            await _wxCli.PrepareDataAsync(AppendLog);
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
            foreach (var contact in SelectedContacts.ToList())
            {
                var safeName = contact.DisplayName.Replace('/', '_');
                var outDir = Path.Combine(ExportPath, safeName);
                var count = await _wxCli.ExportAsync(contact, outDir, IncludeMedia, AppendLog);
                summary.Add($"• {contact.DisplayName}：{count} 条");
            }

            ShowAlert($"已导出 {SelectedContacts.Count} 个会话到：\n{ExportPath}\n\n{string.Join('\n', summary)}");
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
        AppendLog("正在自动加载会话列表…");
        IsBusy = true;
        try
        {
            await LoadContactsInternalAsync(showErrorDialog: false);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task LoadContactsInternalAsync(bool showErrorDialog)
    {
        try
        {
            var items = await _wxCli.LoadSessionsAsync(AppendLog);
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
