using System.Text.Json.Serialization;

namespace WeChatExporter.Models;

/// <summary>
/// 云端备份清单中的单个文件条目（对应后端 GET /backup/manifest 的 files[] 元素）。
/// 字段与契约一致：name / category / sha256 / totalSize / chunkCount / chunkSize / state / createdAt / updatedAt。
/// </summary>
public sealed class CloudBackupItem
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("category")] public string Category { get; set; } = "other";
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
    [JsonPropertyName("totalSize")] public long TotalSize { get; set; }
    [JsonPropertyName("chunkCount")] public int ChunkCount { get; set; }
    [JsonPropertyName("chunkSize")] public int ChunkSize { get; set; }
    [JsonPropertyName("state")] public string State { get; set; } = "uploading";
    [JsonPropertyName("createdAt")] public string? CreatedAt { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }

    /// <summary>仅 state == complete 的文件可下载。</summary>
    [JsonIgnore]
    public bool IsComplete => string.Equals(State, "complete", StringComparison.OrdinalIgnoreCase);

    [JsonIgnore]
    public string DisplayName => Name;

    /// <summary>列表副标题：大小 · 状态 · 更新时间。</summary>
    [JsonIgnore]
    public string Subtitle
    {
        get
        {
            var size = Services.EncryptedExport.FormatSize(TotalSize);
            var state = IsComplete ? "已就绪" : "上传中";
            var updated = string.IsNullOrWhiteSpace(UpdatedAt) ? "" : $" · {UpdatedAt}";
            return $"{size} · {state}{updated}";
        }
    }
}
