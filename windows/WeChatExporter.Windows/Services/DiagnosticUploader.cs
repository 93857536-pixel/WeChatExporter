using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

/// <summary>
/// 诊断日志静默上传：首次启动弹出条款窗征得同意后，报错时自动将诊断信息
/// POST 到开发者服务器。上传失败一律静默（不重试、不阻塞、不弹框），
/// 不影响任何用户操作。
/// </summary>
public static class DiagnosticUploader
{
    private const string SettingsDirectoryName = "WeChatExporter";
    private const string SettingsFileName = "settings.json";
    private const string ConsentKey = "diagnostics_consented";
    // 经 Cloudflare Tunnel 443 转发到服务器 8082（阿里云云盾拦截非 80/443 端口直连）
    private const string Endpoint = "https://linminhao.top/diag/v1/diag";
    private const string AppName = "WeChatExporter";
    private const string Platform = "windows";

    // 与契约文档 v2.14.0 保持一致（独立于 csproj 的发布版本号，由主流程统一同步）。
    private const string Version = "2.14.0";
    private const string Build = "31";

    private const int MaxErrorChars = 2000;
    private const int MaxLogChars = 8000;
    private const int MaxLogLines = 50;
    private const int TimeoutSeconds = 5;

    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(TimeoutSeconds),
    };

    private static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        SettingsDirectoryName,
        SettingsFileName);

    /// <summary>是否已同意上传诊断日志（未设置或明确不同意均返回 false）。</summary>
    public static bool IsConsented
    {
        get
        {
            try
            {
                if (!File.Exists(SettingsPath))
                    return false;
                using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
                return doc.RootElement.TryGetProperty(ConsentKey, out var el)
                       && el.ValueKind == JsonValueKind.True;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>是否已就诊断日志上传做出过选择（用于判断是否需要弹条款窗；未设置返回 false）。</summary>
    public static bool HasConsent
    {
        get
        {
            try
            {
                if (!File.Exists(SettingsPath))
                    return false;
                using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
                return doc.RootElement.TryGetProperty(ConsentKey, out _);
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>写入同意/不同意选择（保留 settings.json 中已存在的其他字段）。</summary>
    public static void SetConsent(bool consented)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);

            JsonObject obj;
            if (File.Exists(SettingsPath))
            {
                try
                {
                    obj = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? new JsonObject();
                }
                catch
                {
                    obj = new JsonObject();
                }
            }
            else
            {
                obj = new JsonObject();
            }

            obj[ConsentKey] = consented;
            File.WriteAllText(SettingsPath, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // 写入失败不影响功能（下次启动会重新询问）。
        }
    }

    /// <summary>
    /// 仅在用户已同意时上传诊断信息。任何失败均静默（不重试、不阻塞、不弹框）。
    /// </summary>
    public static async Task ReportIfAllowedAsync(string stage, string? error, IReadOnlyList<string> logs)
    {
        if (!IsConsented)
            return;

        try
        {
            // 快照日志尾部，避免上传期间集合被 UI 线程修改。
            var tail = logs.Skip(Math.Max(0, logs.Count - MaxLogLines)).ToList();
            var body = new
            {
                app = AppName,
                platform = Platform,
                version = Version,
                build = Build,
                os = Environment.OSVersion.ToString(),
                timestamp = DateTime.Now.ToString("o"),
                stage,
                error = Truncate(error ?? "", MaxErrorChars),
                logs = Truncate(string.Join("\n", tail), MaxLogChars),
            };

            var json = JsonSerializer.Serialize(body);
            using var content = new StringContent(json, Encoding.UTF8, "application/json");
            using var response = await Http.PostAsync(Endpoint, content).ConfigureAwait(false);
            // 不解析响应内容：成功或失败均静默。
        }
        catch
        {
            // 上传失败静默：不影响用户操作。
        }
    }

    private static string Truncate(string value, int maxChars)
        => value.Length <= maxChars ? value : value[..maxChars];
}
