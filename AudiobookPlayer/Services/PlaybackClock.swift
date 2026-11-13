import Foundation
import Combine

/// 播放进度时钟。
///
/// 为什么单独拆一个对象：SwiftUI 的 `EnvironmentObject` 通知是「整包」的，
/// 只要 `AudioEngine` 有任何 `@Published` 变化，所有订阅它的视图都会重算 body。
/// 进度每 0.25 秒动一次，而书库列表有 1500 行，于是列表在播放时每秒被重排 4 次。
/// 把时钟摘出来以后，只有真正显示时间的视图（播放页）会跟着刷新。
@MainActor
final class PlaybackClock: ObservableObject {
    /// 当前播放位置（秒），0.25 秒粒度，供播放页滑块使用
    @Published private(set) var currentTime: Double = 0
    /// 当前音频总时长（秒）
    @Published private(set) var duration: Double = 0

    /// 播放计时器每 0.25 秒调一次；只在变化足够明显时才发通知，避免空刷新。
    func ticking(time: Double, duration newDuration: Double) {
        if abs(newDuration - duration) > 0.002 {
            duration = newDuration
        }
        guard time != currentTime else { return }
        if abs(time - currentTime) >= 0.2 || time == 0 {
            currentTime = time
        }
    }

    /// 跳转 / 换书 / 停止时调：无条件同步，保证界面立刻对齐真实位置。
    func reset(time: Double, duration newDuration: Double) {
        if duration != newDuration { duration = newDuration }
        if currentTime != time { currentTime = time }
    }
}
