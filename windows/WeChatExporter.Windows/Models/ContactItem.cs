using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace WeChatExporter.Models;

public enum ContactKind
{
    Friend,
    Group,
    Official
}

public sealed class ContactItem : INotifyPropertyChanged
{
    private bool _isFavorite;

    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string NickName { get; init; }
    public required string Remark { get; init; }
    public required ContactKind Kind { get; init; }
    public required string LastTime { get; init; }
    public required long LastTimestamp { get; init; }
    public required string Summary { get; init; }

    public bool IsFavorite
    {
        get => _isFavorite;
        set
        {
            if (_isFavorite == value) return;
            _isFavorite = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(FavoriteGlyph));
        }
    }

    public string FavoriteGlyph => IsFavorite ? "★" : "☆";

    public string KindLabel => Kind switch
    {
        ContactKind.Group => "群聊",
        ContactKind.Official => "公众号",
        _ => "好友"
    };

    public string Subtitle => string.IsNullOrWhiteSpace(Summary)
        ? LastTime
        : $"{LastTime} · {Summary}";

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
