import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var sleepTimer: SleepTimer

    @State private var showSleepSheet = false
    @State private var showShortcuts = false
    @State private var showClearConfirm = false
    @State private var intro: Double = 0
    @State private var outro: Double = 0
    @State private var loadedDefaults = false

    private let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        Form {
            playbackSection
            skipSection
            storageSection
            automationSection
            aboutSection
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
        }
        .sheet(isPresented: $showShortcuts) {
            ShortcutGuideSheet()
        }
        .confirmationDialog(
            "清空整个书库？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空书库和音频文件", role: .destructive) {
                engine.stop()
                store.clearAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有音频、歌单和收听进度都会删除，不可恢复。")
        }
        .onAppear {
            guard !loadedDefaults else { return }
            loadedDefaults = true
            let source = engine.currentBook ?? store.books.first
            intro = source?.skipIntro ?? 0
            outro = source?.skipOutro ?? 0
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section {
            Picker("播放速度", selection: Binding(
                get: { Double(engine.rate) },
                set: { engine.setRate(Float($0)) }
            )) {
                ForEach(rates, id: \.self) { value in
                    Text(rateLabel(value)).tag(value)
                }
            }

            Button {
                showSleepSheet = true
            } label: {
                HStack {
                    Text("定时播放")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(sleepTimer.description)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("播放")
        } footer: {
            Text("倍速对所有书生效，并会记住。定时播放到点前 3 秒渐弱再暂停。")
        }
    }

    private func rateLabel(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }

    // MARK: - 跳过头尾

    private var skipSection: some View {
        Section {
            Stepper(value: $intro, in: 0...600, step: 5) {
                HStack {
                    Text("跳过片头")
                    Spacer()
                    Text("\(Int(intro)) 秒").foregroundStyle(.secondary)
                }
            }
            Stepper(value: $outro, in: 0...600, step: 5) {
                HStack {
                    Text("跳过片尾")
                    Spacer()
                    Text("\(Int(outro)) 秒").foregroundStyle(.secondary)
                }
            }
            Button {
                store.applySkipSettings(intro: intro, outro: outro)
            } label: {
                Text("应用到全部 \(store.books.count) 本")
            }
            .disabled(store.books.isEmpty)
        } header: {
            Text("跳过头尾")
        } footer: {
            Text("这里改的是全书库的默认值；单本可以长按播放页的「片头片尾」单独调。片尾的意思是：当剩余时间小于这个值时就当作本章听完。")
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            Picker("排序", selection: $store.sortOrder) {
                ForEach(LibraryStore.SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.icon).tag(order)
                }
            }
            LabeledContent("音频数量", value: "\(store.books.count) 个")
            LabeledContent("歌单数量", value: "\(store.playlists.count) 个")
            LabeledContent("总时长", value: Audiobook.timeString(store.totalDuration))
            LabeledContent("占用空间", value: byteText)
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Text("清空书库")
            }
            .disabled(store.books.isEmpty)
        } header: {
            Text("书库")
        } footer: {
            Text("音频保存在 App 的 Documents/Audio 里，不会上传到任何服务器。清空前建议先在电脑上留一份原始文件夹。")
        }
    }

    private var byteText: String {
        ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file)
    }

    // MARK: - 自动化

    private var automationSection: some View {
        Section {
            Button {
                showShortcuts = true
            } label: {
                HStack {
                    Text("快捷指令一览")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("自动化")
        } footer: {
            Text("在「快捷指令」App 里搜「雅拉马喜」就能加到桌面、自动化或 Siri；也可以做成到点自动开播、上车自动续播。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: "0.3.3 (Beta)")
            LabeledContent("最低系统", value: "iOS 16.0")
            LabeledContent("开发者签名", value: "个人免费证书")
        } header: {
            Text("关于")
        } footer: {
            Text("雅拉马喜 · 本地有声书播放器。所有音频、封面、进度都只存在这台手机上，App 不联网。")
        }
    }
}

// MARK: - 快捷指令说明

struct ShortcutGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String)] = [
        ("播放有声书", "不带书名＝继续上次那本；带书名＝直接播那一本"),
        ("暂停播放", "随时暂停"),
        ("快进 / 快退", "传入秒数，负数回退"),
        ("设置定时", "传入分钟数，到点渐弱暂停"),
        ("本章结束停止", "播完当前这集就停"),
        ("取消定时", "清掉正在跑的倒计时")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0).font(.headline)
                            Text(item.1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("用法：打开「快捷指令」→ 新建 → 搜索「雅拉马喜」→ 选动作 → 填参数。长按动作还能加到主屏幕或「轻点背面」。")
                }
            }
            .navigationTitle("快捷指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
