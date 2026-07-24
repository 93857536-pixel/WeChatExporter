namespace WeChatExporter.Models;

public enum ExportStyle
{
    SingleHtml,
    FolderBundle
}

public static class ExportStyleInfo
{
    public static string Title(ExportStyle style) => style switch
    {
        ExportStyle.FolderBundle => "分类文件夹",
        _ => "单文件 HTML"
    };

    public static string Detail(ExportStyle style) => style switch
    {
        ExportStyle.FolderBundle => "文字文档 + 图片/音频(mp3)/视频(mp4) 分目录，汇总到同一文件夹",
        _ => "文字与媒体全部内嵌到一个网页，浏览器直接打开"
    };
}
