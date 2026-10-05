using System.IO;
using System.Text.Json;

namespace WeChatExporter.Services;

/// <summary>
/// 云备份账号状态持久化：%APPDATA%/WeChatExporter/cloud-settings.json。
/// 只存 JWT token / handle / userId / sessionId —— 绝不存备份密码（密码只停留在内存）。
/// 此文件不进入 git（.gitignore 已覆盖 settings 类文件）。
/// </summary>
public static class CloudSettings
{
    private const string DirectoryName = "WeChatExporter";
    private const string FileName = "cloud-settings.json";

    public sealed class State
    {
        public string Token { get; set; } = "";
        public string Handle { get; set; } = "";
        public string UserId { get; set; } = "";
        public string SessionId { get; set; } = "";
    }

    private static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        DirectoryName,
        FileName);

    public static State Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var state = JsonSerializer.Deserialize<State>(File.ReadAllText(SettingsPath));
                if (state is not null) return state;
            }
        }
        catch { /* 解析失败按未登录处理 */ }
        return new State();
    }

    public static void Save(State state)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath,
                JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* 写入失败不影响本次会话 */ }
    }

    public static void Clear()
    {
        try { if (File.Exists(SettingsPath)) File.Delete(SettingsPath); } catch { /* ignore */ }
    }
}
