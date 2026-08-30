// WeChatExporter 服务器监控 API (独立端口 8083, 供 iOS App 查询)
// 部署: C:\WeChatExporterDiag\monitor-api.js
// 运行: node monitor-api.js  (计划任务自启)
// 端点:
//   GET /api/status      → 系统状态(CPU/内存/磁盘) + 服务进程状态
//   GET /api/logs        → 报错日志列表(含处理状态)
//   GET /api/logs/:id    → 单条日志详情
//   GET /api/hermes      → Hermes 进程/模型/最近活动
// 鉴权: x-diag-token 头(与 diag-server 相同 token)
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

const PORT = process.env.MONITOR_PORT || 8083;
const BASE = 'C:\\WeChatExporterDiag';
const INBOX = path.join(BASE, 'inbox');
const PROC = path.join(BASE, 'processed');
const FAIL = path.join(BASE, 'failed');
const HISTORY = path.join(BASE, 'history.json');
const TOKEN = process.env.DIAG_TOKEN || 'wxexporter-diag-2026';
const GIT = 'C:\\tools\\git-portable\\cmd\\git.exe';

const pad = (n) => String(n).padStart(2, '0');
function fmt(ts) {
    const d = new Date(ts);
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function json(res, code, obj) {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(obj));
}

// ---------- 系统状态 ----------
function getSystemStatus() {
    const out = { cpu: null, memory: null, disk: null };
    try {
        const ps = spawnSync('powershell', ['-NoProfile', '-Command',
            `$c = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average; ` +
            `$m = Get-CimInstance Win32_OperatingSystem; ` +
            `$d = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -eq 'C' }; ` +
            `Write-Output ("CPU=" + [math]::Round($c.Average,1)); ` +
            `Write-Output ("MEM=" + $m.TotalVisibleMemorySize + "," + $m.FreePhysicalMemory); ` +
            `Write-Output ("DISK=" + $d.Used + "," + $d.Free)`], { encoding: 'utf8', timeout: 15000 });
        if (ps.status === 0) {
            for (const line of ps.stdout.split(/\r?\n/)) {
                const m = line.trim().split('=');
                if (m[0] === 'CPU') out.cpu = parseFloat(m[1]);
                else if (m[0] === 'MEM') { const [t, f] = m[1].split(',').map(Number); out.memory = { usedMB: Math.round((t-f)/1024), totalMB: Math.round(t/1024) }; }
                else if (m[0] === 'DISK') { const [u, f] = m[1].split(',').map(Number); out.disk = { usedGB: Math.round(u/1073741824*10)/10, freeGB: Math.round(f/1073741824*10)/10 }; }
            }
        }
    } catch { /* 忽略 */ }
    return out;
}

function isListening(port) {
    try {
        const r = spawnSync('powershell', ['-NoProfile', '-Command',
            `if (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq ${port}) { '1' } else { '0' }`],
            { encoding: 'utf8', timeout: 10000 });
        return r.status === 0 && r.stdout.trim().endsWith('1');
    } catch { return false; }
}

function isProcessRunning(name) {
    try {
        const r = spawnSync('powershell', ['-NoProfile', '-Command',
            `if (Get-Process ${name} -ErrorAction SilentlyContinue) { '1' } else { '0' }`],
            { encoding: 'utf8', timeout: 10000 });
        return r.status === 0 && r.stdout.trim().endsWith('1');
    } catch { return false; }
}

function getServices() {
    return {
        diagServer: isListening(8082),
        monitorApi: isListening(8083),
        node3000: isListening(3000),
        nginx: isListening(80),
        cloudflared: isProcessRunning('cloudflared'),
        hermes: isProcessRunning('python'),
    };
}

// ---------- 日志读取 ----------
function readLogFiles(dir, status) {
    const results = [];
    try {
        if (!fs.existsSync(dir)) return results;
        for (const f of fs.readdirSync(dir)) {
            if (!f.endsWith('.json')) continue;
            const full = path.join(dir, f);
            try {
                const raw = fs.readFileSync(full, 'utf8');
                const data = JSON.parse(raw);
                results.push({
                    id: f.replace('.json', ''),
                    filename: f,
                    status,
                    received_at: data.received_at || fmt(fs.statSync(full).mtimeMs),
                    app: data.app || '',
                    platform: data.platform || '',
                    version: data.version || '',
                    build: data.build || '',
                    os: data.os || '',
                    stage: data.stage || '',
                    error: (data.error || '').slice(0, 300),
                    error_full: data.error || '',
                    logs_tail: (data.logs || '').slice(-2000),
                    timestamp: data.timestamp || '',
                });
            } catch { /* 跳过坏文件 */ }
        }
    } catch { /* 忽略 */ }
    return results;
}

function getFixProgress() {
    // 解析 auto-fix.log / hermes-fix.log 尾部, 提取最近修复活动
    const fixes = [];
    const autoLog = path.join(BASE, 'auto-fix.log');
    const hermesLog = path.join(BASE, 'hermes-fix.log');
    try {
        if (fs.existsSync(autoLog)) {
            const lines = fs.readFileSync(autoLog, 'utf8').split(/\r?\n/).filter(Boolean);
            for (const l of lines.slice(-15)) {
                fixes.push({ source: 'auto-fix', time: fmt(new Date()), text: l.slice(0, 200) });
            }
        }
        if (fs.existsSync(hermesLog) && fs.statSync(hermesLog).size > 0) {
            fixes.push({ source: 'hermes', time: fmt(fs.statSync(hermesLog).mtimeMs), text: `hermes-fix.log ${Math.round(fs.statSync(hermesLog).size/1024)}KB, 最后修改 ${fmt(fs.statSync(hermesLog).mtimeMs)}` });
        }
    } catch { /* 忽略 */ }
    return fixes;
}

// ---------- HTTP 路由 ----------
const server = http.createServer((req, res) => {
    if (req.headers['x-diag-token'] !== TOKEN) {
        return json(res, 403, { ok: false, error: 'forbidden' });
    }
    const url = new URL(req.url, 'http://x');
    const p = url.pathname;

    if (req.method === 'GET' && p === '/api/status') {
        return json(res, 200, {
            ok: true,
            fetched_at: new Date().toISOString(),
            system: getSystemStatus(),
            services: getServices(),
            counts: {
                inbox: readLogFiles(INBOX, 'pending').length,
                processing: 0,
                resolved: readLogFiles(PROC, 'resolved').length,
                failed: readLogFiles(FAIL, 'failed').length,
            },
        });
    }

    if (req.method === 'GET' && p === '/api/logs') {
        const limit = Math.min(parseInt(url.searchParams.get('limit') || '50', 10), 200);
        const all = [
            ...readLogFiles(INBOX, 'pending'),
            ...readLogFiles(PROC, 'resolved'),
            ...readLogFiles(FAIL, 'failed'),
        ].sort((a, b) => (b.received_at || '').localeCompare(a.received_at || ''));
        return json(res, 200, { ok: true, total: all.length, logs: all.slice(0, limit) });
    }

    const mLog = p.match(/^\/api\/logs\/([^/]+)$/);
    if (req.method === 'GET' && mLog) {
        const id = mLog[1];
        for (const [dir, status] of [[INBOX, 'pending'], [PROC, 'resolved'], [FAIL, 'failed']]) {
            const f = path.join(dir, id + '.json');
            if (fs.existsSync(f)) {
                try {
                    const data = JSON.parse(fs.readFileSync(f, 'utf8'));
                    return json(res, 200, { ok: true, status, data });
                } catch { return json(res, 500, { ok: false, error: 'parse error' }); }
            }
        }
        return json(res, 404, { ok: false, error: 'not found' });
    }

    if (req.method === 'GET' && p === '/api/hermes') {
        const fixes = getFixProgress();
        return json(res, 200, {
            ok: true,
            process: isProcessRunning('python') ? 'running' : 'stopped',
            model: 'deepseek-v4-flash',
            install: 'C:\\hermes-agent-main',
            venv: 'C:\\Users\\Administrator\\.hermes-agent-venv',
            last_fix_log: path.join(BASE, 'hermes-fix.log'),
            recent_fixes: fixes,
        });
    }

    // GET /api/history?hours=24 —— 系统状态历史(采集器每5分钟写入 history.json)
    if (req.method === 'GET' && p === '/api/history') {
        const hours = Math.min(parseInt(url.searchParams.get('hours') || '24', 10), 168);
        let arr = [];
        try { arr = JSON.parse(fs.readFileSync(HISTORY, 'utf8')); } catch { arr = []; }
        if (!Array.isArray(arr)) arr = [];
        const cutoff = Date.now() - hours * 3600 * 1000;
        arr = arr.filter(e => new Date(e.t).getTime() >= cutoff);
        // 降采样: 最多返回 300 点(小时视图下约 5min/点)
        if (arr.length > 300) {
            const step = Math.ceil(arr.length / 300);
            arr = arr.filter((_, i) => i % step === 0);
        }
        return json(res, 200, { ok: true, hours, points: arr });
    }

    // POST /api/logs/:id/trigger —— 手动触发 Hermes 修复(把日志复制回 inbox 并立即跑 auto-fix)
    const mTrigger = p.match(/^\/api\/logs\/([^/]+)\/trigger$/);
    if (req.method === 'POST' && mTrigger) {
        const id = mTrigger[1];
        // 找日志(可能在任何目录)
        let found = null, srcDir = null;
        for (const [dir, st] of [[INBOX, 'pending'], [PROC, 'resolved'], [FAIL, 'failed']]) {
            const f = path.join(dir, id + '.json');
            if (fs.existsSync(f)) { found = f; srcDir = dir; break; }
        }
        if (!found) return json(res, 404, { ok: false, error: 'log not found' });
        try {
            // 复制回 inbox(auto-fix 会按新文件处理)
            const target = path.join(INBOX, id + '.json');
            if (srcDir !== INBOX) {
                fs.copyFileSync(found, target);
                fs.unlinkSync(found); // 从原目录移走, 避免重复
            }
            // 立即触发 auto-fix(后台, 不等待)
            spawnSync('powershell', ['-NoProfile', '-Command',
                `schtasks /Run /TN WeChatExporterAutoFix 2>&1 | Out-Null; Write-Output done`],
                { encoding: 'utf8', timeout: 20000 });
            return json(res, 200, { ok: true, message: '修复已触发, 日志已放回 inbox', id });
        } catch (e) {
            return json(res, 500, { ok: false, error: 'trigger failed: ' + e.message });
        }
    }

    // POST /api/logs/:id/ack —— 标记已处理(移到 processed)
    const mAck = p.match(/^\/api\/logs\/([^/]+)\/ack$/);
    if (req.method === 'POST' && mAck) {
        const id = mAck[1];
        for (const [dir, st] of [[INBOX, 'pending'], [FAIL, 'failed']]) {
            const f = path.join(dir, id + '.json');
            if (fs.existsSync(f)) {
                try {
                    // 更新状态标记
                    const data = JSON.parse(fs.readFileSync(f, 'utf8'));
                    data.acked_at = new Date().toISOString();
                    data.acked_by = 'monitor-app';
                    fs.writeFileSync(f, JSON.stringify(data, null, 2));
                    // 移到 processed
                    const target = path.join(PROC, id + '.json');
                    fs.renameSync(f, target);
                    return json(res, 200, { ok: true, message: '已标记为处理完成', id });
                } catch (e) {
                    return json(res, 500, { ok: false, error: 'ack failed: ' + e.message });
                }
            }
        }
        return json(res, 404, { ok: false, error: 'log not found in inbox/failed' });
    }

    return json(res, 404, { ok: false, error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`[monitor-api] listening on :${PORT}`);
});
