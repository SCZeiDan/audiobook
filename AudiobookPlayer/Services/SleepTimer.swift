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
        remaining = nil
        stopAtEndOfTrack = false
    }

    private func tick() {
        guard let current = remaining else { return }
        let next = current - 1
        if next <= 0 {
            timer?.invalidate()
            timer = nil
            remaining = nil
            fadeOutAndPause()
        } else {
            remaining = next
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