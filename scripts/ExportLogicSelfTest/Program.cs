// 可在 Linux / Windows 上编译的纯逻辑自测（不依赖 WPF / 微信）
// 用法：dotnet run --project scripts/ExportLogicSelfTest

using System.Text.Json;
using System.Text.RegularExpressions;

static string ExportQuery(string id, string displayName)
{
    if (!string.IsNullOrWhiteSpace(id)) return id.Trim();
    return (displayName ?? "").Trim();
}

static string? ReadExportedTalker(string json)
{
    using var doc = JsonDocument.Parse(json);
    var root = doc.RootElement;
    if (root.ValueKind != JsonValueKind.Object) return null;
    if (TryGet(root, "talker", out var talker)) return talker;
    if (root.TryGetProperty("conversation", out var conversation)
        && conversation.ValueKind == JsonValueKind.Object)
    {
        if (TryGet(conversation, "talker", out talker)) return talker;
        if (TryGet(conversation, "username", out talker)) return talker;
    }
    if (root.TryGetProperty("export_info", out var exportInfo)
        && exportInfo.ValueKind == JsonValueKind.Object
        && TryGet(exportInfo, "talker", out talker))
    {
        return talker;
    }
    return null;
}

static bool TryGet(JsonElement el, string name, out string value)
{
    value = "";
    if (!el.TryGetProperty(name, out var prop) || prop.ValueKind != JsonValueKind.String) return false;
    value = prop.GetString()?.Trim() ?? "";
    return !string.IsNullOrEmpty(value);
}

static string SanitizeFilename(string name)
{
    var cleaned = Regex.Replace(name, "[/\\\\:\\?\\*\"<>\\|]", "_");
    return string.IsNullOrEmpty(cleaned) ? "聊天记录" : cleaned;
}

var failed = 0;
void Check(string name, bool ok)
{
    Console.WriteLine(ok ? $"  PASS  {name}" : $"  FAIL  {name}");
    if (!ok) failed++;
}

Console.WriteLine("ExportLogicSelfTest");
Check("ExportQuery prefers wxid", ExportQuery("wxid_abc", "张三") == "wxid_abc");
Check("ExportQuery chatroom", ExportQuery("1@chatroom", "群") == "1@chatroom");
Check("ExportQuery fallback name", ExportQuery("", "文件传输助手") == "文件传输助手");
Check("Talker match", string.Equals(ReadExportedTalker("{\"conversation\":{\"talker\":\"wxid_a\"}}"), "wxid_a", StringComparison.OrdinalIgnoreCase));
Check("Talker mismatch detect", !string.Equals(ReadExportedTalker("{\"export_info\":{\"talker\":\"wxid_b\"}}"), "wxid_a", StringComparison.OrdinalIgnoreCase));
Check("Sanitize", SanitizeFilename("a/b:c") == "a_b_c");

Console.WriteLine(failed == 0 ? "ALL PASSED" : $"FAILED: {failed}");
return failed == 0 ? 0 : 1;
