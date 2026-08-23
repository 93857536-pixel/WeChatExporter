using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace WeChatExporter.Services;

/// <summary>
/// 微信 4.x 数据库密钥（rawKey）提取器：扫描 Weixin.exe / WeChat.exe 进程内存，
/// 通过两种通用模式定位密钥（不依赖版本偏移，参考 wechat-dump-rs / WeChatMsg_fix 思路）：
/// <list type="number">
/// <item>GetKeyAddrStub：内存对象结构 [ptr(8)][00*8][0x20][00*7][0x2f][00*7]，ptr 指向 32 字节密钥。</item>
/// <item>设备类型字符串 "iphone/android/ipad" 向前扫描指针（密钥通常紧随设备信息）。</item>
/// </list>
/// 候选密钥使用微信 4.x 数据库文件头（salt + HMAC-SHA512）做真实校验，杜绝误报。
/// </summary>
public static class WeChatKeyExtractor
{
    private const uint ProcessAllAccess = 0x1F0FFF;
    private const uint MemCommit = 0x1000;
    private const uint MemPrivate = 0x20000;
    private const int KeySize = 32;
    private const int ChunkSize = 8 * 1024 * 1024;        // 单次读取 8MB
    private const int OverlapSize = 128;                  // 块间重叠，防跨块模式漏检
    private const int BackwardScanSteps = 2048;           // 设备字符串向前扫指针的步数
    private const long ProgressLogInterval = 256L * 1024 * 1024;

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryBasicInformation
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress,
        out MemoryBasicInformation lpBuffer, int dwLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress,
        byte[] lpBuffer, int nSize, out IntPtr lpNumberOfBytesRead);

    /// <summary>
    /// 从运行中的微信进程内存提取 32 字节 rawKey。dbPath 为任一微信 4.x 加密数据库
    /// （用于 salt/HMAC 校验，建议 message_0.db 或 session.db）。
    /// 返回 null 表示未找到有效密钥。
    /// </summary>
    public static byte[]? ExtractRawKey(string? dbPath, Action<string>? log = null, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(dbPath) || !File.Exists(dbPath))
        {
            log?.Invoke("密钥校验库不存在，跳过内存扫描");
            return null;
        }

        foreach (var process in FindWeChatProcesses())
        {
            ct.ThrowIfCancellationRequested();
            log?.Invoke($"扫描微信进程内存（PID {process.Id}，{process.ProcessName}）…");
            try
            {
                var key = ScanProcess(process.Id, dbPath, log, ct);
                if (key is not null)
                {
                    log?.Invoke($"应用层密钥提取成功（PID {process.Id}）");
                    return key;
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                log?.Invoke($"进程 {process.Id} 扫描失败：{ex.Message}");
            }
        }
        log?.Invoke("内存中未匹配到有效密钥（微信可能未登录或版本过新）");
        return null;
    }

    private static IEnumerable<Process> FindWeChatProcesses()
    {
        // 微信 4.x 进程名为 Weixin.exe；3.x 为 WeChat.exe。多开时取工作集最大的实例。
        return Process.GetProcesses()
            .Where(p => p.ProcessName is "Weixin" or "WeChat" or "WeChatAppEx")
            .OrderByDescending(p => { try { return p.WorkingSet64; } catch { return 0L; } });
    }

    private static byte[]? ScanProcess(int pid, string dbPath, Action<string>? log, CancellationToken ct)
    {
        var handle = OpenProcess(ProcessAllAccess, false, (uint)pid);
        if (handle == IntPtr.Zero)
        {
            log?.Invoke($"无法打开进程 {pid}（需以管理员身份运行）");
            return null;
        }
        try
        {
            var regions = EnumerateRegions(handle);
            log?.Invoke($"找到 {regions.Count} 个可读内存区域，开始模式扫描…");

            var pointerCandidates = new List<long>();
            long scannedBytes = 0;
            var lockObj = new object();

            Parallel.ForEach(regions, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(2, Environment.ProcessorCount / 2) },
                region =>
                {
                    ct.ThrowIfCancellationRequested();
                    var (baseAddr, size) = region;
                    var pointers = ScanRegion(handle, baseAddr, (long)size, ref scannedBytes, log);
                    lock (lockObj)
                    {
                        pointerCandidates.AddRange(pointers);
                    }
                });

            log?.Invoke($"模式扫描完成，得到 {pointerCandidates.Count} 个候选指针，正在校验密钥…");
            return VerifyCandidates(handle, pointerCandidates, dbPath, log, ct);
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static List<(long Base, long Size)> EnumerateRegions(IntPtr handle)
    {
        var regions = new List<(long, long)>();
        long address = 0;
        while (VirtualQueryEx(handle, new IntPtr(address), out var mbi, Marshal.SizeOf<MemoryBasicInformation>()) != 0)
        {
            var regionSize = (long)mbi.RegionSize;
            if (regionSize <= 0) break;
            if (mbi.State == MemCommit && mbi.Type == MemPrivate)
                regions.Add(((long)mbi.BaseAddress, regionSize));
            address += regionSize;
        }
        return regions;
    }

    private static List<long> ScanRegion(IntPtr handle, long baseAddr, long size, ref long scannedBytes, Action<string>? log)
    {
        var found = new List<long>();
        var buffer = new byte[ChunkSize + OverlapSize];
        var pointerBuffer = new byte[8];

        for (long offset = 0; offset < size; offset += ChunkSize)
        {
            var toRead = (int)Math.Min(ChunkSize + OverlapSize, size - offset);
            if (!ReadProcessMemory(handle, new IntPtr(baseAddr + offset), buffer, toRead, out _))
                continue;

            ScanPatternA(buffer, toRead, baseAddr + offset, found);
            ScanPatternB(buffer, toRead, baseAddr + offset, pointerBuffer, found);

            var scanned = Interlocked.Add(ref scannedBytes, toRead);
            if (log is not null && scanned / ProgressLogInterval != (scanned - toRead) / ProgressLogInterval)
                log($"内存扫描进度：{scanned / (1024 * 1024)} MB…");
        }
        return found;
    }

    /// <summary>
    /// 模式 A（GetKeyAddrStub）：定位 [00*8][0x20][00*7][0x2f][00*7] 24 字节结构，
    /// 其前 8 字节为指向 32 字节密钥的小端指针。
    /// </summary>
    private static void ScanPatternA(byte[] buf, int len, long baseAddr, List<long> found)
    {
        for (var i = 8; i < len - 16; i++)
        {
            if (buf[i] == 0x20 && buf[i + 8] == 0x2f)
            {
                // 校验 [i-8, i) 全零、[i+1, i+8) 全零、[i+9, i+16) 全零
                var ok = true;
                for (var j = i - 8; j < i; j++) if (buf[j] != 0) { ok = false; break; }
                if (!ok) continue;
                for (var j = i + 1; j < i + 8; j++) if (buf[j] != 0) { ok = false; break; }
                if (!ok) continue;
                for (var j = i + 9; j < i + 16; j++) if (buf[j] != 0) { ok = false; break; }
                if (!ok) continue;

                var ptr = BitConverter.ToInt64(buf, i - 8);
                if (IsPlausiblePointer(ptr))
                    found.Add(ptr);
            }
        }
    }

    /// <summary>
    /// 模式 B：在 "iphone/android/ipad" 设备字符串前向后扫描指针（密钥通常紧跟设备信息）。
    /// </summary>
    private static void ScanPatternB(byte[] buf, int len, long baseAddr, byte[] ptrBuf, List<long> found)
    {
        foreach (var device in DeviceStrings)
        {
            var pos = 0;
            while (pos < len)
            {
                var idx = IndexOf(buf, device, pos, len);
                if (idx < 0) break;
                // 从设备字符串位置向前（更小地址）扫描指针
                var start = Math.Max(0, idx - BackwardScanSteps * 8);
                for (var p = idx - 8; p >= start; p -= 8)
                {
                    var ptr = BitConverter.ToInt64(buf, p);
                    if (IsPlausiblePointer(ptr))
                        found.Add(ptr);
                }
                pos = idx + device.Length;
            }
        }
    }

    private static readonly byte[][] DeviceStrings =
    [
        "iphone\0"u8.ToArray(),
        "android\0"u8.ToArray(),
        "ipad\0"u8.ToArray(),
    ];

    private static int IndexOf(byte[] haystack, byte[] needle, int start, int len)
    {
        if (needle.Length == 0 || start >= len) return -1;
        var limit = len - needle.Length;
        for (var i = start; i <= limit; i++)
        {
            var matched = true;
            for (var j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j]) { matched = false; break; }
            }
            if (matched) return i;
        }
        return -1;
    }

    private static bool IsPlausiblePointer(long ptr)
    {
        // 用户态 64 位指针：高 2 字节为 0，且非极小/极大值
        const long userSpaceLimit = 0x0000_7FFF_FFFF_0000;
        return ptr > 0x1_0000 && ptr < userSpaceLimit;
    }

    private static byte[]? VerifyCandidates(IntPtr handle, List<long> pointers, string dbPath,
        Action<string>? log, CancellationToken ct)
    {
        var seen = new HashSet<long>();
        var keys = new List<byte[]>();
        foreach (var ptr in pointers)
        {
            ct.ThrowIfCancellationRequested();
            if (!seen.Add(ptr)) continue;

            var key = ReadProcessBytes(handle, ptr, KeySize);
            if (key is null || !LooksLikeKey(key)) continue;
            if (keys.Any(k => k.AsSpan().SequenceEqual(key))) continue;

            keys.Add(key);
            if (WeChatDbCrypto.ValidateRawKey(key, dbPath))
            {
                log?.Invoke($"密钥校验通过（指针 0x{ptr:X}）");
                return key;
            }
        }
        log?.Invoke($"已校验 {keys.Count} 个候选密钥，均不匹配");
        return null;
    }

    private static byte[]? ReadProcessBytes(IntPtr handle, long address, int size)
    {
        var buffer = new byte[size];
        if (!ReadProcessMemory(handle, new IntPtr(address), buffer, size, out _))
            return null;
        return buffer;
    }

    /// <summary>轻量预筛：密钥应为 32 字节随机数据（含足够不同字节，非全零/全重复）。</summary>
    private static bool LooksLikeKey(byte[] key)
    {
        var distinct = 0;
        var seen = new bool[256];
        foreach (var b in key)
        {
            if (!seen[b]) { seen[b] = true; distinct++; }
        }
        return distinct >= 8;
    }
}
