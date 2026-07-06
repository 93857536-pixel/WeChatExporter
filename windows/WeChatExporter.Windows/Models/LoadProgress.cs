namespace WeChatExporter.Models;

public readonly record struct LoadProgressUpdate(double Fraction, string Message)
{
    public static LoadProgressUpdate Initial(string message) => new(0.02, message);
}

/// <summary>
/// 先时间预估，拿到实际结果后切换为真实进度；进度只增不减。
/// </summary>
public sealed class LoadProgressTracker
{
    private readonly object _lock = new();
    private DateTime _startedAt = DateTime.UtcNow;
    private double _lastFraction;
    private bool _hasActualTotal;

    public void Reset()
    {
        lock (_lock)
        {
            _startedAt = DateTime.UtcNow;
            _lastFraction = 0;
            _hasActualTotal = false;
        }
    }

    public LoadProgressUpdate Estimated(string message)
    {
        lock (_lock)
        {
            if (_hasActualTotal)
                return new LoadProgressUpdate(_lastFraction, message);

            var elapsed = (DateTime.UtcNow - _startedAt).TotalSeconds;
            var target = Math.Min(0.30, 0.05 + elapsed / 120.0 * 0.25);
            _lastFraction = Math.Max(_lastFraction, target);
            return new LoadProgressUpdate(_lastFraction, message);
        }
    }

    public LoadProgressUpdate Warmup(string message)
    {
        lock (_lock)
        {
            if (_hasActualTotal)
                return new LoadProgressUpdate(_lastFraction, message);

            var elapsed = (DateTime.UtcNow - _startedAt).TotalSeconds;
            var target = Math.Min(0.35, 0.08 + elapsed / 180.0 * 0.22);
            _lastFraction = Math.Max(_lastFraction, target);
            return new LoadProgressUpdate(_lastFraction, message);
        }
    }

    public LoadProgressUpdate Actual(int loaded, int total, string message)
    {
        lock (_lock)
        {
            _hasActualTotal = true;
            var safeTotal = Math.Max(Math.Max(total, loaded), 1);
            var ratio = Math.Min(1.0, (double)loaded / safeTotal);
            var target = 0.35 + ratio * 0.64;
            _lastFraction = Math.Max(_lastFraction, Math.Min(0.99, target));
            return new LoadProgressUpdate(_lastFraction, message);
        }
    }

    public LoadProgressUpdate Complete(string message)
    {
        lock (_lock)
        {
            _lastFraction = 1.0;
            return new LoadProgressUpdate(1.0, message);
        }
    }
}
