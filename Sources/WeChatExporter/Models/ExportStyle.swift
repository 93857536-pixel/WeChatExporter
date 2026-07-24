import Foundation

/// 导出成品形态。
enum ExportStyle: String, CaseIterable, Identifiable {
    case singleHTML
    case folderBundle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleHTML: return "单文件 HTML"
        case .folderBundle: return "分类文件夹"
        }
    }

    var detail: String {
        switch self {
        case .singleHTML:
            return "文字与媒体全部内嵌到一个网页，浏览器直接打开"
        case .folderBundle:
            return "文字文档 + 图片/音频(mp3)/视频(mp4) 分目录，汇总到同一文件夹"
        }
    }
}
