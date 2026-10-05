using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using WeChatExporter.Models;

namespace WeChatExporter.Services;

/// <summary>
/// 云备份后端 HTTP 客户端（https://wce.liminhao.top/api）。
/// 契约：登录/注册(OTP) + manifest / chunk / commit / download / delete / usage。
/// 本类只做网络层与响应解析；备份密码与加解密在上层（CloudBackupService），绝不经过本类。
/// </summary>
public sealed class CloudApiException : Exception
{
    public HttpStatusCode StatusCode { get; }
    public int? RetryAfterSec { get; }
    public long? UsedBytes { get; }
    public long? QuotaBytes { get; }

    public CloudApiException(HttpStatusCode code, string message, int? retryAfter = null, long? used = null, long? quota = null)
        : base(message)
    {
        StatusCode = code;
        RetryAfterSec = retryAfter;
        UsedBytes = used;
        QuotaBytes = quota;
    }
}

/// <summary>manifest 提交条目的上传计划（name 固定，category 固定 other）。</summary>
public sealed class ManifestEntry
{
    public string Name { get; init; } = "";
    public string Category { get; init; } = "other";
    public string Sha256 { get; init; } = "";
    public long TotalSize { get; init; }
    public int ChunkCount { get; init; }
    public int ChunkSize { get; init; }
}

public sealed class ManifestSubmitResult
{
    /// <summary>服务端判定内容未变，可跳过上传（sha256 命中已有 complete 文件）。</summary>
    public bool SkipUpload { get; set; }
    public long UsedBytes { get; set; }
    public long QuotaBytes { get; set; }
}

public sealed class CloudBackupClient
{
    public const string BaseUrl = "https://wce.liminhao.top/api";

    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

    private readonly HttpClient _http;

    /// <summary>当前登录 token（JWT）；未登录为 null。</summary>
    public string? Token { get; set; }

    public CloudBackupClient()
    {
        _http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
    }

    // MARK: - 鉴权

    /// <summary>发送 OTP 验证码，返回有效期（秒）。</summary>
    public async Task<int> SendCodeAsync(string type, string target, CancellationToken ct = default)
    {
        var node = await PostJsonAsync("/auth/send-code", new { type, target }, auth: false, ct).ConfigureAwait(false);
        return GetInt(node, "expiresInSec") ?? 0;
    }

    /// <summary>注册或登录（register=true 时携带 handle 昵称走 /auth/register，否则 /auth/login）。</summary>
    public async Task<(string Token, string SessionId, string Handle, string UserId)> RegisterOrLoginAsync(
        string type, string target, string code, string? handle, string deviceId, bool register, CancellationToken ct = default)
    {
        var body = new { type, target, code, handle, deviceId };
        var node = await PostJsonAsync(register ? "/auth/register" : "/auth/login", body, auth: false, ct).ConfigureAwait(false);
        var token = GetString(node, "token")
            ?? throw new CloudApiException(HttpStatusCode.Unauthorized, "登录响应缺少 token");
        var sessionId = GetString(node, "sessionId") ?? "";
        string userId = "";
        string h = "";
        if (node.TryGetPropertyValue("user", out var u) && u is JsonObject uo)
        {
            userId = GetString(uo, "id") ?? "";
            h = GetString(uo, "handle") ?? "";
        }
        return (token, sessionId, h, userId);
    }

    // MARK: - 备份清单 / 用量

    public async Task<List<CloudBackupItem>> GetManifestAsync(CancellationToken ct = default)
    {
        var node = await GetJsonAsync("/backup/manifest", ct).ConfigureAwait(false);
        var list = new List<CloudBackupItem>();
        if (node.TryGetPropertyValue("files", out var f) && f is JsonArray arr)
        {
            foreach (var a in arr)
            {
                if (a is JsonObject ao)
                {
                    var item = ao.Deserialize<CloudBackupItem>(JsonOpts);
                    if (item is not null) list.Add(item);
                }
            }
        }
        return list;
    }

    public async Task<(long UsedBytes, long QuotaBytes, int FileCount)> GetUsageAsync(CancellationToken ct = default)
    {
        var node = await GetJsonAsync("/backup/usage", ct).ConfigureAwait(false);
        return (GetLong(node, "usedBytes") ?? 0, GetLong(node, "quotaBytes") ?? 0, GetInt(node, "fileCount") ?? 0);
    }

    // MARK: - 上传

    /// <summary>提交 manifest（files 单条目），返回 skip/upload 判定与用量。</summary>
    public async Task<ManifestSubmitResult> SubmitManifestAsync(ManifestEntry entry, CancellationToken ct = default)
    {
        var body = new
        {
            files = new[]
            {
                new
                {
                    name = entry.Name,
                    category = entry.Category,
                    sha256 = entry.Sha256,
                    totalSize = entry.TotalSize,
                    chunkCount = entry.ChunkCount,
                    chunkSize = entry.ChunkSize,
                },
            },
        };
        var node = await PostJsonAsync("/backup/manifest", body, auth: true, ct).ConfigureAwait(false);
        var result = new ManifestSubmitResult
        {
            UsedBytes = GetLong(node, "usedBytes") ?? 0,
            QuotaBytes = GetLong(node, "quotaBytes") ?? 0,
        };
        if (node.TryGetPropertyValue("actions", out var acts) && acts is JsonArray arr)
        {
            foreach (var a in arr)
            {
                if (a is JsonObject ao && string.Equals(GetString(ao, "action"), "skip", StringComparison.OrdinalIgnoreCase))
                {
                    result.SkipUpload = true;
                    break;
                }
            }
        }
        return result;
    }

    /// <summary>上传单个密文分块（data = base64 密文）。</summary>
    public async Task UploadChunkAsync(string name, int chunkIdx, string dataBase64, CancellationToken ct = default)
    {
        await PostJsonAsync("/backup/chunk", new { name, chunkIdx, data = dataBase64 }, auth: true, ct).ConfigureAwait(false);
    }

    /// <summary>提交完成，返回 (size, usedBytes, quotaBytes)。</summary>
    public async Task<(long Size, long UsedBytes, long QuotaBytes)> CommitAsync(string name, CancellationToken ct = default)
    {
        var node = await PostJsonAsync("/backup/commit", new { name }, auth: true, ct).ConfigureAwait(false);
        return (GetLong(node, "size") ?? 0, GetLong(node, "usedBytes") ?? 0, GetLong(node, "quotaBytes") ?? 0);
    }

    // MARK: - 下载 / 删除

    /// <summary>下载单个分块（application/octet-stream 密文）。</summary>
    public async Task<byte[]> DownloadChunkAsync(string name, int idx, CancellationToken ct = default)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, $"{BaseUrl}/backup/chunk?name={Uri.EscapeDataString(name)}&idx={idx}");
        AddAuth(req);
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw await BuildExceptionAsync(resp, ct).ConfigureAwait(false);
        return await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
    }

    /// <summary>删除云端备份（DELETE 携带 JSON body，与契约一致）。</summary>
    public async Task DeleteFileAsync(string name, CancellationToken ct = default)
    {
        var req = new HttpRequestMessage(HttpMethod.Delete, BaseUrl + "/backup/file");
        req.Content = new StringContent(JsonSerializer.Serialize(new { name }, JsonOpts), Encoding.UTF8, "application/json");
        AddAuth(req);
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw await BuildExceptionAsync(resp, ct).ConfigureAwait(false);
    }

    // MARK: - 底层

    private async Task<JsonObject> PostJsonAsync(string path, object body, bool auth, CancellationToken ct)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, BaseUrl + path);
        req.Content = new StringContent(JsonSerializer.Serialize(body, JsonOpts), Encoding.UTF8, "application/json");
        if (auth) AddAuth(req);
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        return await ParseOkAsync(resp, ct).ConfigureAwait(false);
    }

    private async Task<JsonObject> GetJsonAsync(string path, CancellationToken ct)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, BaseUrl + path);
        AddAuth(req);
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        return await ParseOkAsync(resp, ct).ConfigureAwait(false);
    }

    private void AddAuth(HttpRequestMessage req)
    {
        if (!string.IsNullOrEmpty(Token))
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + Token);
    }

    private async Task<JsonObject> ParseOkAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        var node = await ReadJsonAsync(resp, ct).ConfigureAwait(false);
        if (resp.IsSuccessStatusCode) return node;
        throw BuildException(resp.StatusCode, node);
    }

    private async Task<CloudApiException> BuildExceptionAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        var node = await ReadJsonAsync(resp, ct).ConfigureAwait(false);
        return BuildException(resp.StatusCode, node);
    }

    private static async Task<JsonObject> ReadJsonAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        var raw = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        try { return JsonNode.Parse(raw) as JsonObject ?? new JsonObject(); }
        catch { return new JsonObject(); }
    }

    private static CloudApiException BuildException(HttpStatusCode code, JsonObject node)
    {
        int? retryAfter = GetInt(node, "retryAfterSec");
        long? used = GetLong(node, "usedBytes");
        long? quota = GetLong(node, "quotaBytes");
        return new CloudApiException(code, BuildErrorMessage(code, node, retryAfter, used, quota), retryAfter, used, quota);
    }

    private static string BuildErrorMessage(HttpStatusCode code, JsonObject node, int? retryAfter, long? used, long? quota)
    {
        switch ((int)code)
        {
            case 401: return "验证码错误或账号不存在（登录失败）";
            case 400: return "请求参数无效";
            case 404: return "文件不存在";
            case 409:
            {
                // 契约把不同冲突原因区分在 409 里：quota_exceeded / file_not_pending / chunks_missing / size_mismatch
                var err = GetString(node, "error") ?? GetString(node, "code") ?? "";
                switch (err)
                {
                    case "quota_exceeded":
                        return quota is { } q && used is { } u
                            ? $"云端空间不足：已用 {EncryptedExport.FormatSize(u)} / 配额 {EncryptedExport.FormatSize(q)}"
                            : "云端空间不足（配额已满）";
                    case "file_not_pending": return "文件未处于可上传状态（请先提交清单）";
                    case "chunks_missing": return "分块缺失，提交失败";
                    case "size_mismatch": return "上传大小与清单不一致";
                    default:
                        // 兜底：带 used/quota 的 409 一律按配额超限解释
                        return quota is { } q2 && used is { } u2
                            ? $"云端空间不足：已用 {EncryptedExport.FormatSize(u2)} / 配额 {EncryptedExport.FormatSize(q2)}"
                            : "请求冲突（资源状态不符）";
                }
            }
            case 429:
                return retryAfter is { } r ? $"请求过于频繁，请 {r} 秒后重试" : "请求过于频繁，请稍后重试";
            case 507: return "服务器存储已满";
            default: return $"请求失败（HTTP {(int)code}）";
        }
    }

    private static string? GetString(JsonObject o, string key)
        => o.TryGetPropertyValue(key, out var n) && n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static int? GetInt(JsonObject o, string key)
        => o.TryGetPropertyValue(key, out var n) && n is JsonValue v && v.TryGetValue<int>(out var i) ? i : null;

    private static long? GetLong(JsonObject o, string key)
    {
        if (!o.TryGetPropertyValue(key, out var n) || n is not JsonValue v) return null;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        return null;
    }
}
