using System.Windows;
using WeChatExporter.Services;

namespace WeChatExporter;

public partial class App : Application
{
    /// <summary>
    /// 无头 CLI 分支（SPEC §7）：命令行首参为 "wce" 时不启动 GUI，
    /// 同步跑完无头任务后以对应退出码退出。
    /// </summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        if (HeadlessCli.ShouldRun(e.Args))
        {
            var code = HeadlessCli.Run(e.Args);
            Shutdown(code);
            return;
        }
        base.OnStartup(e);
    }
}
