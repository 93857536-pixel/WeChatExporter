// WeChatExporter 服务器状态采集器 (每 5 分钟由计划任务运行)
// 部署: C:\WeChatExporterDiag\collector.js
// 运行: node collector.js  → 追加一条记录到 C:\WeChatExporterDiag\history.json
// 数据: {t: ISO时间, cpu, memUsed, memTotal, diskUsed, diskFree}
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const BASE = 'C:\\WeChatExporterDiag';
const HISTORY = path.join(BASE, 'history.json');
const MAX_ENTRIES = 2000; // ~7天(5min间隔)

function collect() {
    const out = { cpu: null, memUsed: null, memTotal: null, diskUsed: null, diskFree: null };
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
                else if (m[0] === 'MEM') { const [t, f] = m[1].split(',').map(Number); out.memTotal = Math.round(t/1024); out.memUsed = Math.round((t-f)/1024); }
                else if (m[0] === 'DISK') { const [u, f] = m[1].split(',').map(Number); out.diskUsed = Math.round(u/1073741824*10)/10; out.diskFree = Math.round(f/1073741824*10)/10; }
            }
        }
    } catch { /* 忽略 */ }
    return out;
}

function main() {
    const rec = collect();
    if (rec.cpu === null) { process.exit(1); }
    const entry = { t: new Date().toISOString(), ...rec };
    let arr = [];
    try { arr = JSON.parse(fs.readFileSync(HISTORY, 'utf8')); } catch { arr = []; }
    if (!Array.isArray(arr)) arr = [];
    arr.push(entry);
    if (arr.length > MAX_ENTRIES) arr = arr.slice(-MAX_ENTRIES);
    fs.writeFileSync(HISTORY, JSON.stringify(arr));
    console.log(`[collector] ${entry.t} cpu=${entry.cpu}% mem=${entry.memUsed}/${entry.memTotal}MB disk=${entry.diskUsed}/${entry.diskFree}GB total=${arr.length}`);
}

main();
