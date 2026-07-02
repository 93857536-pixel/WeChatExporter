import Foundation

enum KeyCaptureService {
    private static let lldbScript = """
    import lldb
    import binascii

    call_count = 0
    module_name = __name__

    def pbkdf_callback(frame, bp_loc, dict):
        global call_count
        call_count += 1
        process = frame.GetThread().GetProcess()
        gpr = frame.GetRegisters()[0]
        pwd_ptr = gpr.GetChildMemberWithName("x1").GetValueAsUnsigned()
        pwd_len = gpr.GetChildMemberWithName("x2").GetValueAsUnsigned()
        salt_ptr = gpr.GetChildMemberWithName("x3").GetValueAsUnsigned()
        salt_len = gpr.GetChildMemberWithName("x4").GetValueAsUnsigned()
        prf = gpr.GetChildMemberWithName("x5").GetValueAsUnsigned()
        rounds = gpr.GetChildMemberWithName("x6").GetValueAsUnsigned()
        error = lldb.SBError()
        pwd_hex, salt_hex = "", ""
        if 0 < pwd_len < 1024:
            d = process.ReadMemory(pwd_ptr, pwd_len, error)
            if error.Success(): pwd_hex = binascii.hexlify(d).decode()
        if 0 < salt_len < 1024:
            d = process.ReadMemory(salt_ptr, salt_len, error)
            if error.Success(): salt_hex = binascii.hexlify(d).decode()
        prf_names = {3: "SHA1", 4: "SHA256", 5: "SHA512"}
        print(f"[PBKDF2 #{call_count}] PRF={prf_names.get(prf, prf)} rounds={rounds} pwdLen={pwd_len} saltLen={salt_len}", flush=True)
        print(f"  Password: {pwd_hex}", flush=True)
        print(f"  Salt:     {salt_hex}", flush=True)
        return False

    def setup(debugger, command, result, internal_dict):
        target = debugger.GetSelectedTarget()
        bp = target.BreakpointCreateByName("CCKeyDerivationPBKDF")
        bp.SetScriptCallbackFunction(f"{module_name}.pbkdf_callback")
        bp.SetAutoContinue(True)
        target.GetProcess().Continue()

    def __lldb_init_module(debugger, internal_dict):
        debugger.HandleCommand(f'command script add -f {module_name}.setup capture_keys')
    """

    static func capture(dbRoot: URL, log: @escaping (String) -> Void) async throws -> Data {
        let messageDB = dbRoot.appendingPathComponent("message/message_0.db")
        let dbSalt = try CryptoService.readSalt(from: messageDB)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-lldb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let scriptURL = tempDir.appendingPathComponent("capture.py")
        try lldbScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        _ = runCommand("/usr/bin/killall", args: ["WeChat"])
        try await Task.sleep(nanoseconds: 2_000_000_000)

        log("正在启动 LLDB 并等待微信登录…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
        process.arguments = ["-w", "-n", "WeChat", "-o", "command script import \(scriptURL.path)", "-o", "capture_keys"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        _ = runCommand("/usr/bin/open", args: ["-a", "WeChat"])

        let deadline = Date().addingTimeInterval(180)
        var currentRounds = 0
        var currentPassword = ""

        while Date() < deadline {
            let available = pipe.fileHandleForReading.availableData
            if available.isEmpty {
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            guard let chunk = String(data: available, encoding: .utf8) else { continue }
            for line in chunk.components(separatedBy: .newlines) {
                log(line)
                if line.contains("rounds=") {
                    if let range = line.range(of: "rounds=") {
                        let tail = line[range.upperBound...]
                        currentRounds = Int(tail.prefix(while: { $0.isNumber })) ?? 0
                        currentPassword = ""
                    }
                } else if line.contains("Password:") {
                    currentPassword = line.replacingOccurrences(of: "Password:", with: "").trimmingCharacters(in: .whitespaces)
                } else if line.contains("Salt:"), currentRounds == 256_000, currentPassword.count == 64 {
                    let saltHex = line.replacingOccurrences(of: "Salt:", with: "").trimmingCharacters(in: .whitespaces)
                    guard let rawKey = Data(hexString: currentPassword), let salt = Data(hexString: saltHex), salt == dbSalt else { continue }
                    if CryptoService.validateRawKey(rawKey, dbURL: messageDB) {
                        process.terminate()
                        try? FileManager.default.removeItem(at: tempDir)
                        log("密钥捕获成功")
                        return rawKey
                    }
                }
            }
        }

        process.terminate()
        try? FileManager.default.removeItem(at: tempDir)
        throw AppError.keyCaptureFailed
    }

    @discardableResult
    private static func runCommand(_ path: String, args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}
