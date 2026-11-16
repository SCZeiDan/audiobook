import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// 播放内核。单例，供 UI、App Intents、锁屏控制共用。
@MainActor
final class AudioEngine: NSObject, ObservableObject {
    static let shared = AudioEngine()

    @Published private(set) var currentBook: Audiobook?
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Float = 1.0

    /// 播放位置和总时长放在独立对象里。
    /// 它们每 0.25 秒变一次，如果留在这里，所有订阅 `engine` 的视图（包括 1500 行的
    /// 书库列表）都会被拖着重算 body —— 这就是「一播放就卡」的根因。
    let clock: PlaybackClock

    /// 只读转发，老代码 `engine.currentTime` 照常能用
    var currentTime: Double { clock.currentTime }
    var duration: Double { clock.duration }
    /// 播放失败等需要告诉用户的错误，UI 弹完记得清空
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var tickCounter = 0
    private var isHandlingFinish = false
    private var pendingPause: DispatchWorkItem?
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - 淡入淡出

    /// 播放开始 / 暂停 / 换集时的音量渐变时长。
    /// 50ms：刚好抹掉波形硬切的那声「咔哒」，又短到听不出「渐入」的拖沓。
    /// 想更柔和就把这里调大（0.15 左右能明显感到渐入），想更干脆调到 0.02。
    static let fadeDuration: Double = 0.05

    private override init() {
        clock = PlaybackClock()
        super.init()
        rate = AudioEngine.storedRate
        configureSession()
        registerRemoteCommands()
        observeInterruptions()
        loadPersistedQueue()
    }

    // MARK: - 音频会话（后台 + 锁屏）

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .spokenAudio 让系统对人声做优化，有声书场景更合适
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            print("[AudioEngine] session category error: \(error)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioEngine] session activate error: \(error)")
        }
    }

    /// 来电、其他 App 抢音频时保住进度，恢复后自动续播
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let typeRaw = (info?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let optionRaw = (info?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optionRaw: optionRaw)
            }
        }
    }

    private func handleInterruption(typeRaw: UInt, optionRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if isPlaying { pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            if options.contains(.shouldResume), currentBook != nil {
                resume()
            }
        @unknown default:
            break
        }
    }

    // MARK: - 播放控制

    func play(_ book: Audiobook, from position: Double? = nil) {
        // 手动点单本 = 离开歌单连播
        clearQueue()
        playTrack(book, from: position)
    }

    /// 不清空连播队列的底层播放，供歌单连播使用
    private func playTrack(_ book: Audiobook, from position: Double? = nil) {
        cancelPendingPause()
        lastError = nil

        let url = LibraryStore.shared.fileURL(for: book)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "《\(book.title)》的音频文件不见了，重新导入一次就好。"
            return
        }

        let isSameBook = currentBook?.id == book.id
        if !isSameBook || player == nil {
            // 换集时先让旧的一集淡出 50ms 再停，否则波形硬切会「咔」一声
            if let old = player, old.isPlaying {
                old.setVolume(0, fadeDuration: AudioEngine.fadeDuration)
                DispatchQueue.main.asyncAfter(deadline: .now() + AudioEngine.fadeDuration + 0.01) {
                    old.stop()
                }
            }
            stopTicker()
            player = nil
            do {
                let fresh = try AVAudioPlayer(contentsOf: url)
                fresh.delegate = self
                fresh.enableRate = true
                fresh.volume = 0          // 淡入起点
                fresh.prepareToPlay()
                player = fresh
            } catch {
                lastError = "《\(book.title)》播放失败：\(error.localizedDescription)"
                return
            }
        }

        guard let player = self.player else { return }
        activateSession()

        let start = position ?? AudioEngine.resumePosition(book: book, duration: player.duration)
        // position 可能是 0（「从头播放」）。旧写法 `if start > 0` 会把这个请求整个忽略，
        // 表现就是播放页左上角的重播按钮点了没反应。
        player.currentTime = min(max(0, start), max(0, player.duration - 0.2))

        currentBook = book
        clock.reset(time: player.currentTime, duration: player.duration)

        player.volume = 0
        player.play()
        player.rate = rate
        player.setVolume(1, fadeDuration: AudioEngine.fadeDuration)   // 淡入
        isPlaying = true

        startTicker()
        updateNowPlaying()
        syncDurationIfNeeded(book: book, actual: player.duration)
    }

    /// 导入后 / 想重头听：忽略历史进度，直接从片头之后开始（保留当前连播队列）
    func startFresh(_ book: Audiobook) {
        playTrack(book, from: max(0, book.skipIntro))
    }

    func pause() {
        guard let player = self.player else {
            isPlaying = false
            stopTicker()
            persistProgress()
            updateNowPlaying()
            return
        }

        // 先淡出再停：50ms 内音量降到 0，真正的 pause 放在淡出之后，
        // 这样既没有爆音，UI 也是立刻响应（isPlaying 马上置 false）。
        // 淡出期间又按了播放的话，resume() 的 cancelPendingPause() 会撤掉这次暂停，
        // 音量从当前位置平滑升回 1，不会闪一下。
        if player.isPlaying {
            player.setVolume(0, fadeDuration: AudioEngine.fadeDuration)
        }
        isPlaying = false
        stopTicker()
        persistProgress()
        updateNowPlaying()

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.player?.pause()
            }
        }
        pendingPause = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioEngine.fadeDuration + 0.01, execute: work)
    }

    func resume() {
        cancelPendingPause()
        guard let book = currentBook else {
            if let first = LibraryStore.shared.books.first {
                play(first)
            }
            return
        }
        guard let player = self.player else {
            play(book, from: book.lastPosition)
            return
        }
        activateSession()
        player.play()
        player.rate = rate
        player.setVolume(1, fadeDuration: AudioEngine.fadeDuration)   // 淡入
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        cancelPendingPause()
        player?.stop()
        player = nil
        isPlaying = false
        clock.reset(time: 0, duration: 0)
        currentBook = nil
        stopTicker()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to time: Double) {
        guard let player = self.player else { return }
        let upper = max(0, player.duration - 0.25)
        let clamped = min(max(0, time), upper)
        player.currentTime = clamped
        clock.reset(time: clamped, duration: player.duration)
        persistProgress()
        updateNowPlaying()
    }

    func skip(by delta: Double) {
        guard let player = self.player else { return }
        seek(to: player.currentTime + delta)
    }

    func setRate(_ value: Float) {
        let clamped = min(max(value, 0.5), 2.5)
        rate = clamped
        AudioEngine.storedRate = clamped
        player?.enableRate = true
        if isPlaying {
            player?.rate = clamped
        }
        updateNowPlaying()
    }

    /// 定时到点时用：3 秒音量渐弱再暂停，避免突然静音吓一跳
    func fadeOutAndPause(fadeDuration: Double = 3.0) {
        guard let player = self.player, player.isPlaying else {
            pause()
            return
        }
        cancelPendingPause()
        player.setVolume(0, fadeDuration: fadeDuration)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                // 音量已经是 0，pause() 内部再淡出一次也无害；不要把音量拨回 1，
                // 否则下次 resume 又会从满音量起播，淡入就白做了
                self?.pause()
            }
        }
        pendingPause = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.1, execute: work)
    }

    private func cancelPendingPause() {
        pendingPause?.cancel()
        pendingPause = nil
    }

    // MARK: - 队列

    /// 当前连播队列（来自歌单）；为空时按书库顺序播放
    @Published private(set) var queue: [UUID] = [] {
        didSet { persistQueue() }
    }
    /// 正在连播的歌单名，用于界面提示
    @Published private(set) var queueName: String? {
        didSet { persistQueue() }
    }

    private static let queueIDsKey = "engine.queueIDs"
    private static let queueNameKey = "engine.queueName"

    /// 队列要跨冷启动保留，否则「继续播放」会掉回书库顺序
    private func persistQueue() {
        let defaults = UserDefaults.standard
        if queue.isEmpty {
            defaults.removeObject(forKey: AudioEngine.queueIDsKey)
        } else {
            defaults.set(queue.map { $0.uuidString }, forKey: AudioEngine.queueIDsKey)
        }
        if let name = queueName {
            defaults.set(name, forKey: AudioEngine.queueNameKey)
        } else {
            defaults.removeObject(forKey: AudioEngine.queueNameKey)
        }
    }

    private func loadPersistedQueue() {
        let defaults = UserDefaults.standard
        if let raw = defaults.stringArray(forKey: AudioEngine.queueIDsKey), !raw.isEmpty {
            queue = raw.compactMap { UUID(uuidString: $0) }
        }
        queueName = defaults.string(forKey: AudioEngine.queueNameKey)
    }

    func clearQueue() {
        if !queue.isEmpty { queue = [] }
        if queueName != nil { queueName = nil }
    }

    /// 从歌单开始连播：优先从还没听完的那本开始
    func playPlaylist(_ playlist: Playlist) {
        let list = LibraryStore.shared.books(in: playlist)
        guard !list.isEmpty else {
            lastError = "「\(playlist.name)」里还没有音频。"
            return
        }
        let start = list.first(where: { !$0.isFinished }) ?? list[0]
        queue = list.map { $0.id }
        queueName = playlist.name
        playTrack(start)
    }

    /// 连播顺序：有队列走队列，否则走书库
    private var orderedBooks: [Audiobook] {
        if !queue.isEmpty {
            let store = LibraryStore.shared
            let list = queue.compactMap { store.book(id: $0) }
            if !list.isEmpty { return list }
        }
        return LibraryStore.shared.books
    }

    /// 播放列表界面用：有队列走队列，没有队列就是书库全部（与自动连播顺序一致）
    var queueBooks: [Audiobook] { orderedBooks }

    /// 在播放列表里点某一集：沿用当前队列，从这一集开始播
    func playFromQueue(_ book: Audiobook) {
        if currentBook?.id == book.id {
            if !isPlaying { resume() }
            return
        }
        playTrack(book)
    }

    func playNext() {
        let books = orderedBooks
        guard let current = currentBook,
              let index = books.firstIndex(where: { $0.id == current.id }) else { return }
        guard index + 1 < books.count else {
            pause()
            return
        }
        playTrack(books[index + 1])
    }

    /// 返回上一集。
    /// 旧实现有个「播过 3 秒就先回本集开头」的分支，等于把按钮变成了第二颗回退键 ——
    /// 一本 40 分钟的书永远播过 3 秒，所以这个按钮再也切不到上一集。
    /// 回退有专门的 gobackward.15 按钮负责，这里只做一件事：切上一集。
    func playPrevious() {
        let books = orderedBooks
        guard let current = currentBook,
              let index = books.firstIndex(where: { $0.id == current.id }) else { return }
        if index > 0 {
            playTrack(books[index - 1])
        } else {
            // 已经是第一集：回本集开头（跳片头），别让按钮白点
            seek(to: max(0, current.skipIntro))
        }
    }

    // MARK: - 冷启动恢复

    /// App 启动后把「上次听的那本」装进播放器（不自动出声），迷你播放条立刻可用
    func restoreLastSession() {
        guard currentBook == nil, player == nil else { return }
        let books = LibraryStore.shared.books
        guard !books.isEmpty else { return }
        let latest = books.max { a, b in
            (a.lastPlayedAt ?? .distantPast) < (b.lastPlayedAt ?? .distantPast)
        }
        guard let book = latest else { return }
        prepare(book)
    }

    private func prepare(_ book: Audiobook) {
        let url = LibraryStore.shared.fileURL(for: book)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let fresh = try AVAudioPlayer(contentsOf: url)
            fresh.delegate = self
            fresh.enableRate = true
            fresh.prepareToPlay()
            player = fresh
            currentBook = book
            let position = AudioEngine.resumePosition(book: book, duration: fresh.duration)
            fresh.currentTime = min(position, max(0, fresh.duration - 1))
            clock.reset(time: fresh.currentTime, duration: fresh.duration)
            isPlaying = false
            updateNowPlaying()
        } catch {
            // 启动阶段静默失败，别一开 App 就弹窗
            print("[AudioEngine] restore error: \(error)")
        }
    }

    // MARK: - 片头片尾 / 计时

    private static func resumePosition(book: Audiobook, duration: Double) -> Double {
        // 防御：片头设得比整本书还长（比如 600 秒片头配 5 分钟的短音频），
        // 起点会被推到末尾、立刻触发片尾跳集，看着就像「一开播就跳」。片头最多吃一半。
        let introCap = duration > 0 ? duration * 0.5 : Double.greatestFiniteMagnitude
        let intro = min(max(0, book.skipIntro), introCap)
        let outroCap = duration > 0 ? duration * 0.5 : 0
        let outro = min(max(0, book.skipOutro), outroCap)

        var pos = max(book.lastPosition, intro)
        // 上次停在尾部（≈已被片尾逻辑吃掉），从片头重新开始
        if duration > 0, pos >= duration - outro - 0.5 {
            pos = intro
        }
        return pos
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player = self.player, let book = currentBook else { return }
        // 只喂给时钟对象，不碰 engine 自己的 @Published，列表不会跟着重算
        clock.ticking(time: player.currentTime, duration: player.duration)

        // 片尾跳过：剩余时长 <= skipOutro 时直接结算。
        // 同样要防误设：片尾值不超过总时长的一半，且至少播过半秒，
        // 否则一本 5 分钟的短音频配上 600 秒片尾会「一开播就跳下一集」。
        let outroCap = player.duration > 0 ? player.duration * 0.5 : 0
        let outro = min(max(0, book.skipOutro), outroCap)
        if outro > 0, player.currentTime > 0.5, player.duration - player.currentTime <= outro {
            handleFinish(autoAdvance: true)
            return
        }

        tickCounter += 1
        // 锁屏进度条每 5 秒对齐一次（只写字典，很便宜）
        if tickCounter % 20 == 0 {
            updateNowPlaying()
        }
        // 落盘每 30 秒一次：够防丢进度，又不会让 1500 条的 JSON 编码反复打扰主线程
        if tickCounter >= 120 {
            tickCounter = 0
            persistProgress(notifyUI: false)
        }
    }

    private func handleFinish(autoAdvance: Bool) {
        guard !isHandlingFinish else { return }
        isHandlingFinish = true
        defer { isHandlingFinish = false }

        cancelPendingPause()
        let finishedDuration = player?.duration ?? duration

        if var book = currentBook {
            book.duration = finishedDuration
            book.lastPosition = 0
            book.lastPlayedAt = Date()
            LibraryStore.shared.update(book)
            currentBook = book
        }

        stopTicker()
        isPlaying = false

        // 「本章结束后停止」
        if SleepTimer.shared.stopAtEndOfTrack {
            SleepTimer.shared.cancel()
            clock.reset(time: finishedDuration, duration: finishedDuration)
            updateNowPlaying()
            return
        }

        if autoAdvance {
            playNext()
        } else {
            clock.reset(time: finishedDuration, duration: finishedDuration)
            updateNowPlaying()
        }
    }

    /// 片头片尾或标题在外部被改动后，把内存里的 currentBook 同步成最新
    func refreshCurrentBookFromStore() {
        guard let current = currentBook,
              let latest = LibraryStore.shared.books.first(where: { $0.id == current.id }) else { return }
        currentBook = latest
    }

    func persistProgress(notifyUI: Bool = true) {
        guard let player = self.player, var book = currentBook else { return }
        book.lastPosition = player.currentTime
        book.lastPlayedAt = Date()
        if book.duration <= 0 {
            book.duration = player.duration
        }
        LibraryStore.shared.recordProgress(book, notifyUI: notifyUI)
        if notifyUI {
            currentBook = book
        }
    }

    /// 索引里的时长和真实时长对不上（导入时读失败过）就修正
    private func syncDurationIfNeeded(book: Audiobook, actual: Double) {
        guard actual > 0, abs(book.duration - actual) > 1 else { return }
        var copy = book
        copy.duration = actual
        LibraryStore.shared.update(copy)
        currentBook = copy
    }

    // MARK: - 倍速持久化

    private static let rateKey = "audiobook.playbackRate"

    private static var storedRate: Float {
        get {
            let value = UserDefaults.standard.float(forKey: rateKey)
            return value > 0 ? value : 1.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: rateKey)
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.handleFinish(autoAdvance: true)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.lastError = "解码失败，这个文件可能损坏了。"
            self.pause()
        }
    }
}

// MARK: - 锁屏 / 耳机线控 / 车机

extension AudioEngine {
    func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    func updateNowPlaying() {
        guard let book = currentBook else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: "有声书",
            MPMediaItemPropertyAlbumTitle: "本地书库",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let artwork = artwork(for: book) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 有内嵌封面就用封面，没有就退回 App 图标。锁屏图不需要 1200px，降到 600px 省内存
    private func artwork(for book: Audiobook) -> MPMediaItemArtwork? {
        if let name = book.coverFileName,
           let image = CoverService.thumbnail(
                named: name,
                directory: LibraryStore.shared.coverDirectory,
                maxPixel: 600
           ) {
            return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        if let icon = UIImage(named: "AppIcon") {
            return MPMediaItemArtwork(boundsSize: icon.size) { _ in icon }
        }
        return nil
    }
}