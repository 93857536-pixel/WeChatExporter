//! 入口：检测 `wce` 子命令走无头 CLI，否则启动 GUI

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("wce") {
        std::process::exit(wechat_exporter_core::cli::run(&args[1..]));
    }
    wechat_exporter_core::run();
}
