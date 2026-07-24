using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WeChatExporter.Models;
using WeChatExporter.Services;
using WeChatExporter.ViewModels;

namespace WeChatExporter;

public partial class SettingsWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly AppSettings _settings;

    public SettingsWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _settings = AppSettings.Shared;
        DataContext = _viewModel;
        LoadFromSettings();
    }

    private void LoadFromSettings()
    {
        AppearanceSystem.IsChecked = _settings.Appearance == AppearanceMode.System;
        AppearanceLight.IsChecked = _settings.Appearance == AppearanceMode.Light;
        AppearanceDark.IsChecked = _settings.Appearance == AppearanceMode.Dark;

        StyleHtml.IsChecked = _settings.ExportStyle == ExportStyle.SingleHtml;
        StyleFolder.IsChecked = _settings.ExportStyle == ExportStyle.FolderBundle;
        StyleMarkdown.IsChecked = _settings.ExportStyle == ExportStyle.Markdown;
        StylePdf.IsChecked = _settings.ExportStyle == ExportStyle.Pdf;

        RangeAll.IsChecked = _settings.DateRangePreset == DateRangePreset.All;
        Range7.IsChecked = _settings.DateRangePreset == DateRangePreset.Last7Days;
        Range30.IsChecked = _settings.DateRangePreset == DateRangePreset.Last30Days;
        Range90.IsChecked = _settings.DateRangePreset == DateRangePreset.Last90Days;
        Range365.IsChecked = _settings.DateRangePreset == DateRangePreset.Last365Days;
        RangeCustom.IsChecked = _settings.DateRangePreset == DateRangePreset.Custom;
        CustomSinceBox.Text = _settings.CustomSince.ToString("yyyy-MM-dd");
        CustomUntilBox.Text = _settings.CustomUntil.ToString("yyyy-MM-dd");

        SetTypeChecks(_settings.EnabledMessageTypes);

        IncludeMediaCheck.IsChecked = _settings.IncludeMedia;
        IncludeStickerCheck.IsChecked = _settings.IncludeStickerGallery;
        FolderCsvCheck.IsChecked = _settings.FolderIncludeCsv;
        FolderJsonCheck.IsChecked = _settings.FolderIncludeJson;
        IncrementalCheck.IsChecked = _settings.IncrementalExport;
        MapNicknamesCheck.IsChecked = _settings.MapGroupNicknames;
        SpeechToTextCheck.IsChecked = _settings.EnableSpeechToText;
        OpenAfterExportCheck.IsChecked = _settings.OpenFolderAfterExport;
        ExportPathBox.Text = _settings.ExportPath;

        RefreshModePanels();
        RefreshRangePanel();
        CreditText.Text = AppSettings.CreditLine;
    }

    private void RefreshModePanels()
    {
        var folder = StyleFolder.IsChecked == true;
        var html = StyleHtml.IsChecked == true;
        HtmlOptionsPanel.Visibility = html ? Visibility.Visible : Visibility.Collapsed;
        FolderOptionsPanel.Visibility = folder ? Visibility.Visible : Visibility.Collapsed;
        StyleDetailText.Text = ExportStyleInfo.Detail(SelectedStyle());
    }

    private void Style_Changed(object sender, RoutedEventArgs e) => RefreshModePanels();

    private void Range_Changed(object sender, RoutedEventArgs e) => RefreshRangePanel();

    private void RefreshRangePanel()
    {
        CustomRangePanel.Visibility = RangeCustom.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.ChooseExportFolder();
        ExportPathBox.Text = _viewModel.ExportPath;
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.ExportPath = ExportPathBox.Text.Trim();
        _viewModel.OpenExportFolder();
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (AppearanceLight.IsChecked == true) _settings.Appearance = AppearanceMode.Light;
        else if (AppearanceDark.IsChecked == true) _settings.Appearance = AppearanceMode.Dark;
        else _settings.Appearance = AppearanceMode.System;

        _settings.ExportStyle = SelectedStyle();
        _settings.DateRangePreset = SelectedRange();
        if (DateTime.TryParse(CustomSinceBox.Text.Trim(), out var since))
            _settings.CustomSince = since.Date;
        if (DateTime.TryParse(CustomUntilBox.Text.Trim(), out var until))
            _settings.CustomUntil = until.Date;
        _settings.EnabledMessageTypes = SelectedTypeIds();
        _settings.IncludeMedia = IncludeMediaCheck.IsChecked == true;
        _settings.IncludeStickerGallery = IncludeStickerCheck.IsChecked == true;
        _settings.FolderIncludeCsv = FolderCsvCheck.IsChecked == true;
        _settings.FolderIncludeJson = FolderJsonCheck.IsChecked == true;
        _settings.IncrementalExport = IncrementalCheck.IsChecked == true;
        _settings.MapGroupNicknames = MapNicknamesCheck.IsChecked == true;
        _settings.EnableSpeechToText = SpeechToTextCheck.IsChecked == true;
        _settings.OpenFolderAfterExport = OpenAfterExportCheck.IsChecked == true;
        _settings.ExportPath = string.IsNullOrWhiteSpace(ExportPathBox.Text)
            ? _settings.ExportPath
            : ExportPathBox.Text.Trim();

        _settings.Save();
        _viewModel.ApplySettingsFromStore();
        ThemeManager.Apply(_settings.Appearance, Owner as Window ?? this);
        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private ExportStyle SelectedStyle()
    {
        if (StyleFolder.IsChecked == true) return ExportStyle.FolderBundle;
        if (StyleMarkdown.IsChecked == true) return ExportStyle.Markdown;
        if (StylePdf.IsChecked == true) return ExportStyle.Pdf;
        return ExportStyle.SingleHtml;
    }

    private DateRangePreset SelectedRange()
    {
        if (Range7.IsChecked == true) return DateRangePreset.Last7Days;
        if (Range30.IsChecked == true) return DateRangePreset.Last30Days;
        if (Range90.IsChecked == true) return DateRangePreset.Last90Days;
        if (Range365.IsChecked == true) return DateRangePreset.Last365Days;
        if (RangeCustom.IsChecked == true) return DateRangePreset.Custom;
        return DateRangePreset.All;
    }

    private void SetTypeChecks(HashSet<string> types)
    {
        bool On(MessageTypeFilter filter) => types.Count == 0 || types.Contains(MessageTypeFilterInfo.Id(filter));
        TypeTextCheck.IsChecked = On(MessageTypeFilter.Text);
        TypeImageCheck.IsChecked = On(MessageTypeFilter.Image);
        TypeVoiceCheck.IsChecked = On(MessageTypeFilter.Voice);
        TypeVideoCheck.IsChecked = On(MessageTypeFilter.Video);
        TypeEmojiCheck.IsChecked = On(MessageTypeFilter.Emoji);
        TypeAppCheck.IsChecked = On(MessageTypeFilter.App);
        TypeSystemCheck.IsChecked = On(MessageTypeFilter.System);
    }

    private HashSet<string> SelectedTypeIds()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void AddIf(bool? selected, MessageTypeFilter filter)
        {
            if (selected == true) set.Add(MessageTypeFilterInfo.Id(filter));
        }

        AddIf(TypeTextCheck.IsChecked, MessageTypeFilter.Text);
        AddIf(TypeImageCheck.IsChecked, MessageTypeFilter.Image);
        AddIf(TypeVoiceCheck.IsChecked, MessageTypeFilter.Voice);
        AddIf(TypeVideoCheck.IsChecked, MessageTypeFilter.Video);
        AddIf(TypeEmojiCheck.IsChecked, MessageTypeFilter.Emoji);
        AddIf(TypeAppCheck.IsChecked, MessageTypeFilter.App);
        AddIf(TypeSystemCheck.IsChecked, MessageTypeFilter.System);
        return set.Count == 0
            ? MessageTypeFilterInfo.AllIds().ToHashSet(StringComparer.OrdinalIgnoreCase)
            : set;
    }
}

/// <summary>浅色 / 深色主题切换。</summary>
public static class ThemeManager
{
    public static void Apply(AppearanceMode mode, Window? window = null)
    {
        var effective = mode;
        if (mode == AppearanceMode.System)
        {
            // 简易跟随：读注册表 AppsUseLightTheme
            effective = IsSystemLightTheme() ? AppearanceMode.Light : AppearanceMode.Dark;
        }

        var app = Application.Current;
        if (app is null) return;

        var isDark = effective == AppearanceMode.Dark;
        app.Resources["AppBgBrush"] = new SolidColorBrush(isDark ? Color.FromRgb(0x1E, 0x1E, 0x1E) : Color.FromRgb(0xFF, 0xFF, 0xFF));
        app.Resources["AppPanelBrush"] = new SolidColorBrush(isDark ? Color.FromRgb(0x2D, 0x2D, 0x2D) : Color.FromRgb(0xF5, 0xF5, 0xF5));
        app.Resources["AppTextBrush"] = new SolidColorBrush(isDark ? Color.FromRgb(0xF0, 0xF0, 0xF0) : Color.FromRgb(0x22, 0x22, 0x22));
        app.Resources["AppMutedBrush"] = new SolidColorBrush(isDark ? Color.FromRgb(0xAA, 0xAA, 0xAA) : Color.FromRgb(0x66, 0x66, 0x66));
        app.Resources["AppInputBgBrush"] = new SolidColorBrush(isDark ? Color.FromRgb(0x3A, 0x3A, 0x3A) : Color.FromRgb(0xFF, 0xFF, 0xFF));

        if (window is not null)
        {
            window.Background = (Brush)app.Resources["AppBgBrush"];
            window.Foreground = (Brush)app.Resources["AppTextBrush"];
        }

        foreach (Window w in app.Windows)
        {
            w.Background = (Brush)app.Resources["AppBgBrush"];
            w.Foreground = (Brush)app.Resources["AppTextBrush"];
        }
    }

    private static bool IsSystemLightTheme()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var value = key?.GetValue("AppsUseLightTheme");
            if (value is int i) return i != 0;
        }
        catch { /* ignore */ }
        return true;
    }
}
