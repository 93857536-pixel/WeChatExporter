namespace WeChatExporter.Models;

public enum ExportStyle
{
    SingleHtml,
    FolderBundle,
    Markdown,
    Pdf
}

public static class ExportStyleInfo
{
    public static string Title(ExportStyle style) => style switch
    {
        ExportStyle.FolderBundle => "分类文件夹",
        ExportStyle.Markdown => "Markdown",
        ExportStyle.Pdf => "PDF",
        _ => "单文件 HTML"
    };

    public static string Detail(ExportStyle style) => style switch
    {
        ExportStyle.FolderBundle => "文字文档 + 图片/音频(mp3)/视频(mp4) 分目录，汇总到同一文件夹",
        ExportStyle.Markdown => "生成 .md 文本，方便导入笔记软件或二次编辑",
        ExportStyle.Pdf => "生成可打印的 PDF 文档（适合归档与打印）",
        _ => "文字与媒体全部内嵌到一个网页，浏览器直接打开"
    };
}
