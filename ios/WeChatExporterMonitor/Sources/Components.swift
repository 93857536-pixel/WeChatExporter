import SwiftUI

// MARK: - 日期格式化

enum DateFormat {
    static func friendly(_ iso: String) -> String {
        guard !iso.isEmpty else { return "—" }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return friendly(d) }

        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let d = basic.date(from: iso) { return friendly(d) }
        return iso
    }

    static func friendly(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        return df.string(from: date)
    }
}

// MARK: - 状态徽章

enum LogStatus {
    static func color(_ status: String) -> Color {
        switch status {
        case "pending": return .orange
        case "processing": return .blue
        case "resolved": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    static func label(_ status: String) -> String {
        switch status {
        case "pending": return "待处理"
        case "processing": return "处理中"
        case "resolved": return "已解决"
        case "failed": return "失败"
        default: return status
        }
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(LogStatus.label(status))
            .font(.caption).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(LogStatus.color(status))
            .background(LogStatus.color(status).opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - 服务指示灯行

struct ServiceRow: View {
    let name: String
    let running: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(running ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(name)
                .font(.subheadline)
            Spacer()
            Text(running ? "运行中" : "已停止")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 11)
    }
}

// MARK: - 指标卡片

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double

    private var tint: Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.7 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2).bold()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(tint)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 统计瓦片

struct CountTile: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2).bold()
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 等宽文本块

struct MonospaceBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if text.isEmpty {
                Text("(空)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 错误状态

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("无法连接服务器")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
