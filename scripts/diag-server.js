// WeChatExporter 诊断日志接收服务 (独立端口 8082, 与现有 nginx/Node 3000 完全隔离)
// 部署: C:\WeChatExporterDiag\diag-server.js
// 运行: node diag-server.js  (计划任务/看门狗自动拉起)
// 接收: POST /v1/diag  {app,platform,version,build,os,timestamp,stage,error,logs}
// 落盘: C:\WeChatExporterDiag\inbox\<yyyyMMdd-HHmmss>-<rand>.json
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = process.env.DIAG_PORT || 8082;
const INBOX = process.env.DIAG_INBOX || 'C:\\WeChatExporterDiag\\inbox';
// 与客户端约定的静态 token,防止随意灌数据(客户端内置;非安全边界,仅防滥用)
const TOKEN = process.env.DIAG_TOKEN || 'wxexporter-diag-2026';

// 入站最大 body: 256KB (日志截断后远小于此)
const MAX_BODY = 256 * 1024;

fs.mkdirSync(INBOX, { recursive: true });

function log(...args) {
    const ts = new Date().toISOString();
    console.log(`[${ts}]`, ...args);
}

const server = http.createServer((req, res) => {
    const chunks = [];
    let size = 0;

    req.on('data', (c) => {
        size += c.length;
        if (size > MAX_BODY) {
            req.destroy();
            return;
        }
        chunks.push(c);
    });

    req.on('end', () => {
        // 只接受 POST /v1/diag(允许任意前缀,如 CF Tunnel 的 /diag/v1/diag)
        if (req.method !== 'POST' || !req.url.includes('/v1/diag')) {
            res.writeHead(404, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: false, error: 'not found' }));
            return;
        }

        // token 校验
        const auth = req.headers['x-diag-token'];
        if (auth !== TOKEN) {
            log('REJECT token mismatch from', req.socket.remoteAddress);
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: false, error: 'forbidden' }));
            return;
        }

        let body;
        try {
            body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        } catch {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: false, error: 'bad json' }));
            return;
        }

        // 落盘: 文件名带时间戳 + 随机后缀
        const now = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        const ts = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-` +
                   `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
        const rand = crypto.randomBytes(4).toString('hex');
        const file = path.join(INBOX, `${ts}-${rand}.json`);
        const record = {
            received_at: now.toISOString(),
            remote: req.socket.remoteAddress,
            ...body,
        };
        fs.writeFileSync(file, JSON.stringify(record, null, 2), 'utf8');
        log('SAVED', path.basename(file),
            `platform=${body.platform}`, `stage=${body.stage}`, `version=${body.version}`,
            `error=${(body.error || '').slice(0, 80)}`);

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
    });

    req.on('error', (e) => log('req error', e.message));
});

server.listen(PORT, '0.0.0.0', () => {
    log(`diag-server listening on :${PORT}, inbox=${INBOX}`);
});
