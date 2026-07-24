namespace WeChatExporter.Services;

public enum MessageTypeFilter
{
    Text,
    Image,
    Voice,
    Video,
    Emoji,
    App,
    System
}

public static class MessageTypeFilterInfo
{
    public static IReadOnlyList<MessageTypeFilter> All { get; } =
        Enum.GetValues<MessageTypeFilter>();

    public static string Id(MessageTypeFilter filter) => filter switch
    {
        MessageTypeFilter.Text => "text",
        MessageTypeFilter.Image => "image",
        MessageTypeFilter.Voice => "voice",
        MessageTypeFilter.Video => "video",
        MessageTypeFilter.Emoji => "emoji",
        MessageTypeFilter.App => "app",
        MessageTypeFilter.System => "system",
        _ => "text"
    };

    public static string Title(MessageTypeFilter filter) => filter switch
    {
        MessageTypeFilter.Text => "文字",
        MessageTypeFilter.Image => "图片",
        MessageTypeFilter.Voice => "语音",
        MessageTypeFilter.Video => "视频",
        MessageTypeFilter.Emoji => "表情",
        MessageTypeFilter.App => "链接/文件",
        MessageTypeFilter.System => "系统",
        _ => "消息"
    };

    public static IReadOnlyList<string> AllIds() => All.Select(Id).ToArray();

    public static MessageTypeFilter? FromId(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return null;
        foreach (var filter in All)
        {
            if (string.Equals(Id(filter), id.Trim(), StringComparison.OrdinalIgnoreCase))
                return filter;
        }
        return null;
    }

    public static MessageTypeFilter? Matching(int? msgType, string? typeName)
    {
        if (msgType is int t)
        {
            return t switch
            {
                1 => MessageTypeFilter.Text,
                3 => MessageTypeFilter.Image,
                34 => MessageTypeFilter.Voice,
                43 => MessageTypeFilter.Video,
                47 => MessageTypeFilter.Emoji,
                49 => MessageTypeFilter.App,
                10000 or 10002 => MessageTypeFilter.System,
                _ => null
            };
        }

        var name = (typeName ?? "").ToLowerInvariant();
        if (name.Contains("text") || name.Contains("文本") || name.Contains("文字")) return MessageTypeFilter.Text;
        if (name.Contains("image") || name.Contains("图片")) return MessageTypeFilter.Image;
        if (name.Contains("voice") || name.Contains("语音") || name.Contains("audio")) return MessageTypeFilter.Voice;
        if (name.Contains("video") || name.Contains("视频")) return MessageTypeFilter.Video;
        if (name.Contains("emoji") || name.Contains("表情") || name.Contains("sticker")) return MessageTypeFilter.Emoji;
        if (name.Contains("app") || name.Contains("链接") || name.Contains("文件") || name.Contains("link")) return MessageTypeFilter.App;
        if (name.Contains("system") || name.Contains("系统") || name.Contains("revoke")) return MessageTypeFilter.System;
        return null;
    }
}
