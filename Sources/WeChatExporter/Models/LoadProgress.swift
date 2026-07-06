import Foundation

/// 加载进度更新：先时间预估，拿到实际总量后切换为真实进度。
struct LoadProgressUpdate: Sendable {
    var fraction: Double
    var message: String

    static func initial(_ message: String) -> LoadProgressUpdate {
        LoadProgressUpdate(fraction: 0.02, message: message)
    }
}

/// 合并预估进度与实际进度，保证进度条只增不减。
final class LoadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt = Date()
    private var lastFraction: Double = 0
    private var hasActualTotal = false

    func reset() {
        lock.lock()
        startedAt = Date()
        lastFraction = 0
        hasActualTotal = false
        lock.unlock()
    }

    /// 尚无总量时，按已等待时间缓慢推进（最多约 30%）。
    func estimated(message: String) -> LoadProgressUpdate {
        lock.lock()
        defer { lock.unlock() }
        guard !hasActualTotal else {
            return LoadProgressUpdate(fraction: lastFraction, message: message)
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let target = min(0.30, 0.05 + elapsed / 120.0 * 0.25)
        lastFraction = max(lastFraction, target)
        return LoadProgressUpdate(fraction: lastFraction, message: message)
    }

    /// 解密阶段：stderr 提示数据库数量时，略快推进到约 35%。
    func decryptWarmup(totalDBs: Int, message: String) -> LoadProgressUpdate {
        lock.lock()
        defer { lock.unlock() }
        guard !hasActualTotal else {
            return LoadProgressUpdate(fraction: lastFraction, message: message)
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let dbFactor = min(1.0, Double(totalDBs) / 80.0)
        let target = min(0.35, 0.08 + elapsed / 180.0 * 0.22 * dbFactor)
        lastFraction = max(lastFraction, target)
        return LoadProgressUpdate(fraction: lastFraction, message: message)
    }

    /// 分页加载：用已加载 / 总量映射到 35%…99%。
    func actual(loaded: Int, total: Int, message: String) -> LoadProgressUpdate {
        lock.lock()
        defer { lock.unlock() }
        hasActualTotal = true
        let safeTotal = max(total, loaded, 1)
        let ratio = min(1.0, Double(loaded) / Double(safeTotal))
        let target = 0.35 + ratio * 0.64
        lastFraction = max(lastFraction, min(0.99, target))
        return LoadProgressUpdate(fraction: lastFraction, message: message)
    }

    func complete(message: String) -> LoadProgressUpdate {
        lock.lock()
        lastFraction = 1.0
        lock.unlock()
        return LoadProgressUpdate(fraction: 1.0, message: message)
    }
}
