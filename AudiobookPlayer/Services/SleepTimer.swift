import Foundation
import Combine

/// 定时播放：倒计时到点淡出暂停，或等本集播完再停。
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    /// 剩余秒数；nil 表示未启用
    @Published private(set) var remaining: TimeInterval?
    /// 本章结束后停止
    @Published private(set) var stopAtEndOfTrack: Bool = false

    private var timer: Timer?
    /// 用绝对时间戳记截止点，而不是每秒减一。
    /// App 在后台被挂起时 Timer 会停，减一的写法会把这段时间「吞掉」，
    /// 回到前台后剩余时间就偏了。按 deadline 重算是不会漂的。
    private var deadline: Date?

    private init() {}

    var isActive: Bool {
        remaining != nil || stopAtEndOfTrack
    }

    func start(minutes: Int) {
        start(seconds: TimeInterval(minutes) * 60)
    }

    func start(seconds: TimeInterval) {
        cancel()
        guard seconds > 0 else { return }
        stopAtEndOfTrack = false
        deadline = Date().addingTimeInterval(seconds)
        remaining = seconds

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func startStopAtEndOfTrack() {
        cancel()
        stopAtEndOfTrack = true
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        remaining = nil
        stopAtEndOfTrack = false
    }

    private func tick() {
        guard let deadline = deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            timer?.invalidate()
            timer = nil
            self.deadline = nil
            remaining = nil
            fadeOutAndPause()
        } else {
            remaining = left
        }
    }

    /// 交给播放内核做 3 秒音量渐弱，避免直接切断
    private func fadeOutAndPause() {
        AudioEngine.shared.fadeOutAndPause(fadeDuration: 3.0)
    }

    var description: String {
        if stopAtEndOfTrack { return "本章结束后停止" }
        guard let remaining = self.remaining else { return "未开启" }
        let total = Int(remaining.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d 后停止", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d 后停止", total / 60, total % 60)
    }
}