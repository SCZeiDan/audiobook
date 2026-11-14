import AppIntents
import Foundation

// 说明：所有 intent 都设 openAppWhenRun = false，并且不返回 dialog。
// 这样从「快捷指令」/ 小组件 / Siri 触发时只在后台把音频播起来，
// 不会把雅拉马喜拉到前台，也不会弹运行结果通知。

// MARK: - 播放 / 继续播放

/// 不带任何参数：接着上次听到的位置继续播，连播顺序沿用上次的播放列表。
struct PlayAudiobookIntent: AppIntent {
    static var title: LocalizedStringResource = "播放有声书"
    static var description = IntentDescription("接着上次听到的位置继续播放，连播顺序沿用上次的列表。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let engine = AudioEngine.shared
            if engine.currentBook == nil {
                engine.restoreLastSession()
            }
            engine.resume()
        }
        return .result()
    }
}

// MARK: - 暂停

struct PausePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "暂停播放"
    static var description = IntentDescription("暂停当前正在播放的有声书。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AudioEngine.shared.pause()
        }
        return .result()
    }
}

// MARK: - 快进 / 后退

struct SkipPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "快进或后退"
    static var description = IntentDescription("按秒数向前或向后跳转，负数表示后退。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "秒数（负数后退）")
    var seconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("跳转 \(\.$seconds) 秒")
    }

    func perform() async throws -> some IntentResult {
        let delta = Double(seconds)
        await MainActor.run {
            AudioEngine.shared.skip(by: delta)
        }
        return .result()
    }
}

// MARK: - 定时播放

struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "设置定时播放"
    static var description = IntentDescription("指定分钟数后自动淡出停止播放，适合睡前听书。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "分钟")
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$minutes) 分钟后停止播放")
    }

    func perform() async throws -> some IntentResult {
        let value = max(1, minutes)
        await MainActor.run {
            SleepTimer.shared.start(minutes: value)
        }
        return .result()
    }
}

// MARK: - 停止定时

struct CancelSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "关闭定时播放"
    static var description = IntentDescription("取消当前的定时停止。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SleepTimer.shared.cancel()
        }
        return .result()
    }
}

// MARK: - 本章结束后停止

struct StopAtEndOfTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "本章结束后停止"
    static var description = IntentDescription("当前这一集播完后暂停，不跳到下一集。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SleepTimer.shared.startStopAtEndOfTrack()
        }
        return .result()
    }
}

// MARK: - Siri / 快捷指令短语

struct AudiobookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayAudiobookIntent(),
            phrases: [
                "用\(.applicationName)播放有声书",
                "\(.applicationName)继续播放",
                "用\(.applicationName)听书"
            ],
            shortTitle: "播放有声书",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "用\(.applicationName)设置定时播放",
                "\(.applicationName)定时停止"
            ],
            shortTitle: "定时播放",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "用\(.applicationName)暂停播放"
            ],
            shortTitle: "暂停播放",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: SkipPlaybackIntent(),
            phrases: [
                "用\(.applicationName)快进"
            ],
            shortTitle: "快进或后退",
            systemImageName: "goforward"
        )
    }
}