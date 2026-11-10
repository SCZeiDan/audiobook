import AppIntents
import Foundation

// MARK: - 播放 / 继续播放

struct PlayAudiobookIntent: AppIntent {
    static var title: LocalizedStringResource = "播放有声书"
    static var description = IntentDescription("继续播放上次的位置，或按书名播放指定的一本。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "书名（可留空）")
    var bookTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("播放 \(\.$bookTitle)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message: String = await MainActor.run {
            let store = LibraryStore.shared
            let engine = AudioEngine.shared

            let keyword = (bookTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyword.isEmpty,
               let book = store.books.first(where: {
                   $0.title.localizedCaseInsensitiveContains(keyword)
               }) {
                engine.play(book)
                return "开始播放《\(book.title)》"
            }

            if let current = engine.currentBook {
                engine.resume()
                return "继续播放《\(current.title)》"
            }

            let recent = store.books.max {
                ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast)
            }
            if let recent = recent {
                engine.play(recent)
                return "开始播放《\(recent.title)》"
            }

            return "书库是空的，先在 App 里导入音频文件。"
        }
        return .result(dialog: "\(message)")
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let delta = Double(seconds)
        await MainActor.run {
            AudioEngine.shared.skip(by: delta)
        }
        let amount = Int(abs(delta))
        let message = delta >= 0 ? "已快进 \(amount) 秒" : "已后退 \(amount) 秒"
        return .result(dialog: "\(message)")
    }
}

// MARK: - 定时播放

struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "设置定时播放"
    static var description = IntentDescription("指定分钟数后自动淡出停止播放，适合睡前听书。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "分钟")
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$minutes) 分钟后停止播放")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = max(1, minutes)
        await MainActor.run {
            SleepTimer.shared.start(minutes: value)
        }
        return .result(dialog: "\(value) 分钟后停止播放")
    }
}

// MARK: - 停止定时

struct CancelSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "关闭定时播放"
    static var description = IntentDescription("取消当前的定时停止。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            SleepTimer.shared.cancel()
        }
        return .result(dialog: "定时播放已关闭")
    }
}

// MARK: - 本章结束后停止

struct StopAtEndOfTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "本章结束后停止"
    static var description = IntentDescription("当前这一集播完后暂停，不跳到下一集。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            SleepTimer.shared.startStopAtEndOfTrack()
        }
        return .result(dialog: "本章结束后停止")
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