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
                        Button("保存到当前书") {
                            save(book: book)
                        }
                        Button("应用到全部 \(store.books.count) 本") {
                            store.applySkipSettings(intro: intro, outro: outro)
                            engine.refreshCurrentBookFromStore()
                            dismiss()
                        }
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

    private func save(book: Audiobook) {
        var copy = book
        copy.skipIntro = intro
        copy.skipOutro = outro
        store.update(copy)
        engine.refreshCurrentBookFromStore()
        dismiss()
    }
}
