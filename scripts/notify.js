// WeChatExporter 推送通知模块 (Server酱微信推送 + Bark iOS 推送)
// 部署: C:\WeChatExporterDiag\notify.js
// 用法: node notify.js "<标题>" "<正文>"
// 配置: 环境变量或同目录 notify-config.json:
//   { "serverchan_key": "...", "bark_key": "...", "bark_url": "https://api.day.app" }
// 未配置 key 时静默跳过(不报错)
const fs = require('fs');
const path = require('path');
const https = require('https');

const CONFIG_FILE = path.join(__dirname, 'notify-config.json');

function loadConfig() {
    try {
        if (fs.existsSync(CONFIG_FILE)) {
            return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
        }
    } catch {}
    return {
        serverchan_key: process.env.SERVERCHAN_KEY || '',
        bark_key: process.env.BARK_KEY || '',
        bark_url: process.env.BARK_URL || 'https://api.day.app',
    };
}

function httpsGet(url) {
    return new Promise((resolve) => {
        https.get(url, (res) => {
            let body = '';
            res.on('data', (c) => (body += c));
            res.on('end', () => resolve({ status: res.statusCode, body: body.slice(0, 200) }));
        }).on('error', (e) => resolve({ status: 0, body: String(e) }));
    });
}

async function sendServerChan(title, content) {
    const cfg = loadConfig();
    if (!cfg.serverchan_key) return { channel: 'serverchan', sent: false, reason: 'no key' };
    // https://sctapi.ftqq.com/<KEY>.send?title=..&desp=..
    const url = `https://sctapi.ftqq.com/${cfg.serverchan_key}.send?title=${encodeURIComponent(title)}&desp=${encodeURIComponent(content)}`;
    const r = await httpsGet(url);
    return { channel: 'serverchan', sent: r.status === 200, status: r.status, body: r.body };
}

async function sendBark(title, content) {
    const cfg = loadConfig();
    if (!cfg.bark_key) return { channel: 'bark', sent: false, reason: 'no key' };
    // https://api.day.app/<KEY>/<title>/<body>
    const url = `${cfg.bark_url}/${cfg.bark_key}/${encodeURIComponent(title)}/${encodeURIComponent(content)}`;
    const r = await httpsGet(url);
    return { channel: 'bark', sent: r.status === 200, status: r.status, body: r.body };
}

async function main() {
    const [, , title, content] = process.argv;
    if (!title) { console.log('usage: node notify.js "<title>" "<body>"'); process.exit(1); }
    const body = content || title;
    const results = [];
    results.push(await sendServerChan(title, body));
    results.push(await sendBark(title, body));
    console.log(JSON.stringify(results));
}

if (require.main === module) main();
module.exports = { sendServerChan, sendBark, loadConfig };
