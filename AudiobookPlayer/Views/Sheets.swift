import SwiftUI

// MARK: - 定时播放

struct SleepTimerSheet: View {
    @EnvironmentObject private var sleepTimer: SleepTimer
    @Environment(\.dismiss) private var dismiss

    private let options = [5, 10, 15, 20, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(sleepTimer.description)
                        .font(.headline)
                }

                Section {
                    ForEach(options, id: \.self) { minutes in
                        Button {
                            sleepTimer.start(minutes: minutes)
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(minutes) 分钟")
                                Spacer()
                                if let r = sleepTimer.remaining, Int(r) == minutes * 60 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } footer: {
                    Text("到点前 3 秒音量渐弱再暂停；倒计时走系统时钟，切到后台、锁屏都照常生效。")
                }

                Section {
                    Button {
                        sleepTimer.startStopAtEndOfTrack()
                        dismiss()
                    } label: {
                        HStack {
                            Text("本章结束后停止")
                            Spacer()
                            if sleepTimer.stopAtEndOfTrack {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } footer: {
                    Text("「本章结束后停止」在播完当前这一集后暂停，不会跳到下一集。")
                }

                if sleepTimer.isActive {
                    Section {
                        Button("关闭定时播放", role: .destructive) {
                            sleepTimer.cancel()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("定时播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 片头片尾

struct BookTuningSheet: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var intro: Double = 0
    @State private var outro: Double = 0
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                if let book = engine.currentBook {
                    Section {
                        Stepper(value: $intro, in: 0...600, step: 5) {
                            LabeledContent("跳过片头", value: "\(Int(intro)) 秒")
                        }
                        Stepper(value: $outro, in: 0...600, step: 5) {
                            LabeledContent("跳过片尾", value: "\(Int(outro)) 秒")
                        }
                    } header: {
                        Text("《\(book.title)》")
                    } footer: {
                        Text("片头：每次从开头播放时自动跳过。片尾：剩余时间小于该值时直接进入下一集。")
                    }

                    Section {
                        Button("应用到当前歌单") {
                            apply(book: book)
                        }
                    } footer: {
                        Text(engine.queue.isEmpty
                             ? "当前没有歌单队列，只会改正在播的这一本。"
                             : "把这个设置写进当前歌单里的每一集。")
                    }
                } else {
                    Section {
                        Text("当前没有在播放的书。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("片头片尾")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                if let book = engine.currentBook {
                    intro = book.skipIntro
                    outro = book.skipOutro
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    /// 「应用到当前歌单」：有队列就作用于整张歌单，没有队列就只改当前这本
    private func apply(book: Audiobook) {
        if engine.queue.isEmpty {
            var copy = book
            copy.skipIntro = intro
            copy.skipOutro = outro
            store.update(copy)
        } else {
            store.applySkipSettings(intro: intro, outro: outro, to: Set(engine.queue))
        }
        engine.refreshCurrentBookFromStore()
        dismiss()
    }
}

// MARK: - 歌单批量片头片尾

/// 对一个歌单整体设置跳过头尾。
/// 片头片尾是存在每本书上的字段，所以「作用于歌单」= 把同一组值写进这个歌单里的每一本，
/// 已经听过一半的书不会因此丢失进度（只动 skipIntro / skipOutro）。
struct PlaylistTuningSheet: View {
    let playlist: Playlist

    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var intro: Double = 0
    @State private var outro: Double = 0
    @State private var didLoad = false
    /// 各集设置不一致时才提示；只在 onAppear 算一次，避免每次拖 Stepper 都遍历整张歌单
    @State private var isMixed = false

    /// 直接取 id，不解析成 Audiobook（歌单可能有上千集，body 里别做重活）
    private var memberIDs: [UUID] { playlist.bookIDs }
    private var memberCount: Int { memberIDs.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $intro, in: 0...600, step: 5) {
                        LabeledContent("跳过片头", value: "\(Int(intro)) 秒")
                    }
                    Stepper(value: $outro, in: 0...600, step: 5) {
                        LabeledContent("跳过片尾", value: "\(Int(outro)) 秒")
                    }
                } header: {
                    Text("「\(playlist.name)」· \(memberCount) 集")
                } footer: {
                    if isMixed {
                        Text("这个歌单里各集的设置目前不一致，上面显示的是第一集的值。设置一次就会统一。")
                    } else {
                        Text("片头：每次从开头播放时自动跳过。片尾：剩余时间小于该值时直接进下一集。只改跳过头尾，不动收听进度。")
                    }
                }

                Section {
                    Button("应用到这 \(memberCount) 集") {
                        store.applySkipSettings(intro: intro, outro: outro, to: Set(memberIDs))
                        engine.refreshCurrentBookFromStore()
                        dismiss()
                    }
                    .disabled(memberCount == 0)

                    if memberCount > 0 {
                        Button("清空（片头片尾都设为 0）", role: .destructive) {
                            store.applySkipSettings(intro: 0, outro: 0, to: Set(memberIDs))
                            engine.refreshCurrentBookFromStore()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("片头片尾")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                let list = store.books(in: playlist)
                guard let first = list.first else { return }
                intro = first.skipIntro
                outro = first.skipOutro
                isMixed = list.contains {
                    $0.skipIntro != first.skipIntro || $0.skipOutro != first.skipOutro
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 歌单重命名

struct PlaylistNameSheet: View {
    let title: String
    let initial: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("歌单名称", text: $text)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
