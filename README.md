# 雅拉马喜 · iOS（Beta 0.4.2）

一个自用的本地有声书播放器：导入音频 / 整个文件夹、按歌单连播、后台播放、断点续播、跳过片头片尾、定时关闭、快捷指令控制。只有两个页面：书库和设置。

**核心结论：能做完，而且不需要买 Mac。** iOS 的编译链只有 Xcode（只能在 macOS 上跑），但可以用 GitHub 的免费 macOS 机器把代码编译成 `.ipa`，再在 Windows 上用 Sideloadly 签进你的 iPhone。

---

## 一、你的 5 条需求落在哪

| 需求 | 实现方式 | 对应代码 |
| --- | --- | --- |
| 1. 本地导入音频 | 系统文件选择器 / 文件夹 / 拖拽 → 拷贝进 App 沙盒 `Documents/Audio/`；**文件夹导入自动生成同名歌单** | `Services/ImportService.swift`、`Views/LibraryView.swift` |
| 2. 定时播放 | 倒计时到点前 3 秒淡出再暂停；另有「本章结束后停止」 | `Services/SleepTimer.swift`、`Services/AudioEngine.swift`（`fadeOutAndPause`） |
| 3. 自定义跳过头尾 | 每本书单独设置片头/片尾秒数，可一键应用全部 | `Services/AudioEngine.swift`（`resumePosition` / `tick()` / `handleFinish`） |
| 4. 快捷指令 | App Intents + Siri 短语：播放、暂停、快进后退、定时、取消定时、本章结束停 | `Intents/PlaybackIntents.swift` |
| 5. 断点续播 | 播放中每 30 秒 + 暂停/切后台时把位置写入 `library.json`，冷启动自动装回上次那本 | `Services/AudioEngine.swift`（`persistProgress` / `restoreLastSession`） |

顺手做了的：歌单管理（播放/重命名/整单删除）、后台播放、锁屏/耳机线控/车机控制、15 秒快退 30 秒快进、0.75–2x 倍速、来电打断后续播、搜索、四种排序、自动提取音频内嵌封面、设置页（倍速/跳过头尾/占用空间/清空书库/快捷指令说明）。

技术栈：SwiftUI + AVAudioPlayer + MediaPlayer + App Intents，最低 iOS 16，无第三方依赖。

### 0.2.0 比 0.1.0 多了什么

- 封面：导入时从 mp3/m4a 内嵌图里抓封面，书库和播放页都显示；没有封面就画波形占位图
- 导入：支持一次选多个文件、整个文件夹（递归展开、按文件名自然排序）、从「文件」App 拖进窗口
- 定时：到点前 3 秒音量渐弱，不是硬切断；「本章结束后停止」不会跳到下一集
- 打断：来电/闹钟结束后自动续播；切后台立刻落盘
- 书库：搜索、按添加时间/书名/最近听/进度排序、删除时连文件一起清、进度条与「已听完」标记
- 自修复：启动时对齐索引与磁盘，文件丢了不显示死条目，手工塞进 `Documents/Audio` 的文件会被自动收养
- 播放页：左上角「从头播放」，倍速、定时、片头片尾三个入口
- 快进指令：快捷指令里可直接「快进 300 秒」（负数即后退）

### 0.4.2 修四个手感问题

- 播放页底部四个功能改成等分一行（图标在上、文字在下），不再超宽要横滑
- 左上角「从头播放」修好了：以前点它只会重开文件的读取位置，进度条不动，听起来像没反应
- 快捷指令全部改成后台执行：不再把 App 拉到前台，也不再弹运行结果通知
- 「播放有声书」快捷指令不再问书名，直接接着上次的位置和上次的播放列表继续
- 连播队列现在会存进 UserDefaults，冷启动后「继续播放」还是同一个歌单的顺序
### 0.4.1 播放页能看播放列表了

- 播放页多了一个「播放列表」按钮，点开是当前要连播的整份清单（来自哪个歌单会写在标题下面）
- 清单里点任意一集，就从那一集开始播，后面继续按原顺序往下走
- 正在播的那集用波形/暂停图标标出来，还会自动滚到它那一行；每行带时长、已听百分比、已听完标记
### 0.4.0 界面按 Apple 播客重做

- 底部只剩两个 Tab：**主页**、**资料库**（设置挪到资料库右上角齿轮）
- 主页 = 继续收听大卡片 + 最近添加横滑 + 歌单横滑
- 迷你播放条改成播客那种悬浮圆角卡片：封面、标题、副标题、快进 30 秒、播放/暂停，顶部一条 2pt 进度线
- 迷你条浮在 TabBar 之上，不再贴屏幕底边

### 0.3.4 文件夹拖进去就是歌单

- 往 Audio/ 里直接拖**一个文件夹**，文件夹名变成歌单名，里面的音频自动收进书库并归到这个歌单
- 从别的 App 切回来时自动扫描，不用点导入
- 文件夹里没有音频、或音频都搬完后，空文件夹会被清掉，不会每次启动重复扫

### 0.3.3 修了「导入已在 Audio 目录里的文件会存两份」

从「文件」App 选中已经躺在 `Documents/Audio/` 里的音频再导入时，原先会无条件 `copyItem` 到新的 UUID 文件名，等于同目录复制出第二份。现在发现源文件已经在该目录，就直接收养进书库，零拷贝。

### 0.3.2 换了个图标

- App 图标换成喜马拉雅红底白字标的左右镜像版（`Assets.xcassets/AppIcon.appiconset/icon-1024.png`，1024×1024 RGB 无透明通道）
- 功能无改动，仅为视觉区分

### 0.3.1 修了什么（1500 本播放时卡顿）

症状：导入 1500 多个文件后开始播放，再上下滑动书库/歌单列表就卡；不播的时候不卡。

根因是播放中的进度刷新在「每秒 4 次叫醒整个界面」，跟文件多少叠加放大：

| 根因 | 后果 | 改法 |
| --- | --- | --- |
| `AudioEngine.currentTime` 每 0.25 秒 `@Published` 一次 | 所有订阅 `engine` 的视图（含 1500 行列表）每秒重算 4 次 body | 拆出独立的 `PlaybackClock` 环境对象，只有播放页/迷你条读它；`engine.currentTime` 变成只读转发 |
| 每 5 秒回写进度就整表替换 `books` | `@Published books` 全量刷新 + 主线程编码 600KB JSON 写盘（30–80ms 尖峰） | `books` 不再 `@Published`，进度走 `recordProgress(_:notifyUI:)` 静默路径；落盘降到 30 秒一次、编码放后台串行队列 |
| `visibleBooks` 每次 body 全量排序、每个歌单行重建 1500 项字典 | 滑动时 CPU 打满 | 排序结果 / id 索引 / 占用空间都加缓存，数据变才失效；歌单行改用 O(1) 的 `playlistStats(_:)` |
| 列表封面缓存 1200px 原图 | 1500 张解码约 8.5GB，NSCache 反复驱逐、滚动时反复解全尺寸 | 新增 `CGImageSourceCreateThumbnailAtIndex` 降采样缩略图缓存（列表 144px、迷你条 120px、播放页 720px 分层） |

另外：主线程不再有任何同步写盘；`library.json` 去掉 `prettyPrinted`；锁屏进度条改为 5 秒对齐一次。

### 0.3.0 比 0.2.0 多了什么

- **改名**：桌面图标和 App 内都叫「雅拉马喜」（`project.yml` 里的 `CFBundleDisplayName`）
- **歌单**：选文件夹导入时，文件夹名自动变成歌单名；点歌单从第一集没听完的开始连播，播完自动下一集；左滑删除能选「只解散歌单」或「连音频一起删」；长按可重命名、播放整单
- **连播队列**：歌单播放时进的是队列，`playNext` / `playPrevious` 走队列顺序；手动点单本会退出队列、回到书库顺序
- **两个页面**：底部 Tab 只有「书库」和「设置」，关于页收进设置
- **设置页**：倍速、定时播放状态、全书库片头片尾统一设置、排序、音频数/歌单数/总时长/占用空间、清空书库、快捷指令一览
- **迷你播放条**：显示当前歌单名；定时倒计时也显示在条上
- **索引格式升级**：`library.json` 从裸数组变成 `{version, books, playlists}`，**旧的 0.2 数据自动兼容读取**，升级不会丢书

---

## 二、三条路，选一条

| 路线 | 花钱 | 耗时 | 能干什么 |
| --- | --- | --- | --- |
| **A. GitHub Actions 云编译**（推荐） | 0（公开仓库免费） | 首次约 30 分钟，之后每次 3–5 分钟 | 出 ipa，装机自用；不能断点调试 |
| B. 按小时租云 Mac | 几十元 | 2 小时 | 能真机调试、改一行看一行，体验最好 |
| C. 二手 Mac mini（M1）+ Xcode | 2000 元左右 | 1 天 | 长期开发最舒服 |

下面按 A 走；想调试时再转 B/C，项目是同一份代码。

---

## 三、从零到装进手机（Windows 全程可做）

### 0. 准备

- Windows 电脑（你现在这台就行）
- iPhone（iOS 16 以上）
- 一个 Apple ID（免费账号即可，不用开发者账号）
- 数据线

### 1. 注册 GitHub 并建仓库

装 [Git for Windows](https://git-scm.com/download/win)，然后：

```bash
cd ios-audiobook
git init -b main
git add .
git commit -m "init: audiobook player"
```

在 GitHub 网页新建仓库（**选 Public**，私有仓库的 Actions 分钟数有限额），然后：

```bash
git remote add origin https://github.com/<你的用户名>/audiobook.git
git push -u origin main
```

**不会用命令行？** 装 [GitHub Desktop](https://desktop.github.com/)，登录 → Clone 你刚建的仓库 → 把解压出来的所有文件拷进那个文件夹 → Commit → Push。图形界面，不用敲一条命令。

> 关键：**`.github` 文件夹必须在仓库根目录**，它是触发云端编译的开关。浏览器拖拽上传有时会跳过点开头的文件夹，用 GitHub Desktop 最省心。传完去仓库首页看一眼，`.github/workflows/build-ipa.yml` 在不在。

### 2. 等云端编译

推上去后自动触发 `Build unsigned IPA`（`.github/workflows/build-ipa.yml`）：

1. 仓库页 → **Actions** → 点最新一次运行
2. 约 3–5 分钟，全部打绿勾
3. 页面底部 **Artifacts** → 下载 `AudiobookPlayer-unsigned-ipa`（是个 zip，里面有 `.ipa`）

> 编译失败的话，Actions 页面会多出两个东西：`Show compile errors` 步骤里直接列出 `error:` 那几行，Artifacts 里还有完整 `build-log`。把 error 行贴回来就能定位，不用猜。
>
> 第一次跑最容易撞的是 `xcodegen` 或 SDK 版本差异，属于一次性问题。

### 3. Windows 上签名安装

1. 装 **iTunes**（Apple 官网下载版，不要 Microsoft Store 版）和 **iCloud for Windows**——Sideloadly 依赖它们的驱动
2. 装 [Sideloadly](https://sideloadly.io/)
3. iPhone 插线，手机上点「信任此电脑」
4. 把 `AudiobookPlayer-unsigned.ipa` 拖进 Sideloadly，Apple ID 填你的账号
5. 点 **Start**，输入密码；开了双重认证的话，去 appleid.apple.com 生成一个**App 专用密码**填进去
6. 完成后手机上：**设置 → 通用 → VPN与设备管理 → 开发者 App → 信任**
7. 如果提示需要开发者模式：**设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启**

### 4. 打开「雅拉马喜」，导入书

- 点「导入音频文件」选一个或多个 mp3、m4a、m4b、flac
- 或点「导入文件夹（自动成歌单）」，整个专辑/整季一次性进来，按文件名自然排序，并在书库顶部生成一个同名歌单
- 或从「文件」App 长按音频拖进 App 窗口
- 文件会被拷进 App 沙盒，之后即使原文件删了也能播
- 另一条路：数据线连电脑 → iTunes → 文件共享 → 有声书 → 把文件拖进 Documents（下次启动自动收养）

### 5. 配快捷指令

打开系统「快捷指令」App → 新建 → 搜索 App 名「雅拉马喜」，能看到这些动作：

| 动作 | 用途 |
| --- | --- |
| 播放有声书 | 可留空（续播上次），或填书名关键字 |
| 暂停播放 | 暂停 |
| 快进或后退 | 填秒数，负数表示后退，例如 300 或 -30 |
| 设置定时播放 | 填分钟数，例如 30 |
| 关闭定时播放 | 取消定时 |
| 本章结束后停止 | 这一集播完就停，不跳下一集 |

常见组合：

- 睡前自动化：`设置定时播放 30 分钟` → `播放有声书`
- 通勤：`播放有声书` 书名填「三体」
- 也能直接对 Siri 说「用雅拉马喜播放」「用雅拉马喜设置定时播放」

---

## 四、免费签名的三个硬限制

1. **7 天过期**：免费 Apple ID 签的 App 一周后打不开，重跑一遍 Sideloadly 即可（ipa 留着）。
2. **最多 3 个自签 App**：装第 4 个要删一个。
3. **不能给别人用**：想发给朋友 / 上 TestFlight，需要 99 美元/年的开发者账号，那时可以加一个 fastlane 上传步骤，我可以补。

想彻底免掉 7 天限制：买 99 美元开发者账号，用同一份代码签名，有效期 1 年且可 TestFlight 分发。

**不想每周插线重签**：装 [SideStore](https://sidestore.io/) 或 AltStore，它们能在手机上自动完成 7 天续签（需要常驻一个 VPN 配置），装一次之后基本不用管。ipa 还是用 Sideloadly 出第一版就行。

---

## 五、代码地图

```
ios-audiobook/
├── project.yml                      # XcodeGen 工程定义（CI 里自动生成 .xcodeproj）
├── .github/workflows/build-ipa.yml  # 云端编译 + 打包 ipa + 失败时抓 error 行
├── tools/make_icon.py               # 生成 1024 图标
└── AudiobookPlayer/
    ├── App/AudiobookPlayerApp.swift # 入口，注入三个单例
    ├── Models/Audiobook.swift       # 单本音频：进度/已听完/片头片尾
    ├── Models/Playlist.swift        # 歌单：只存书 ID，删歌单不误删文件
    ├── Store/LibraryStore.swift     # 书库 + 歌单：JSON 落盘、增删、排序搜索、占用统计、自修复
    ├── Services/
    │   ├── ImportService.swift      # 安全作用域授权 → 拷贝 → 读时长 → 抓封面
    │   ├── CoverService.swift       # 从音频元数据提封面，带内存缓存
    │   ├── AudioEngine.swift        # 播放内核：断点、片头片尾、倍速、淡出、锁屏、打断
    │   └── SleepTimer.swift         # 定时关闭
    ├── Intents/PlaybackIntents.swift# App Intents + Siri 短语
    ├── Views/
    │   ├── RootView.swift           # 两个 Tab + 迷你播放条 + 冷启动恢复
    │   ├── LibraryView.swift        # 书库：导入、歌单、全部音频、搜索、排序
    │   ├── PlayerView.swift         # 播放页（封面、进度、倍速、定时、片头片尾）
    │   ├── SettingsView.swift       # 设置：倍速、片头片尾、存储、快捷指令说明
    │   └── Sheets.swift             # 定时播放、片头片尾、歌单重命名弹窗
    └── Assets.xcassets/             # 图标
```

几个实现细节，改代码时会用到：

- **片头**在 `resumePosition(book:duration:)` 里生效：起播点 = max(上次位置, 片头)。书已听完时自动回到片头重听。
- **片尾**靠 `tick()` 每 0.25 秒判断 `duration - currentTime <= skipOutro`，命中就 `handleFinish`。
- **断点**每 5 秒写一次盘（`tickCounter >= 20`），暂停/切歌/结束/切后台也会立刻写，避免掉电丢进度。
- **后台播放**依赖 `Info.plist` 的 `UIBackgroundModes: audio` + `AVAudioSession(.playback, .spokenAudio)`。
- **锁屏信息**在 `updateNowPlaying()`，耳机线控在 `registerRemoteCommands()`。
- **打断续播**在 `observeInterruptions()`：`began` 暂停，`ended` 且 `shouldResume` 时续播。
- **淡出**在 `fadeOutAndPause()`：`setVolume(0, fadeDuration:)` 让系统做 3 秒线性衰减，再 pause。
- **自修复**在 `LibraryStore.reconcile()`：启动时丢掉磁盘上已不存在的条目，收养手工丢进 `Audio/` 的文件。
- **文件夹即歌单**在 `ImportService.importFiles`：目录导入结束后 `store.createPlaylist(name:bookIDs:)`，同名歌单自动合并，不会越导越多。
- **连播队列**在 `AudioEngine.queue` + `orderedBooks`：有队列走队列，没有就走书库；`play()` 会先 `clearQueue()`，歌单内部用 `playTrack()` 避免自己把自己清掉。
- **删歌单**在 `LibraryStore.removePlaylist(id:deleteFiles:)`：`deleteFiles` 为真时才真删音频文件，否则只是解散歌单，书还在「全部音频」里。

---

## 六、下一步可以加什么

- 章节识别（m4b 内嵌章节、CUE 文件）
- 按文件名把「书名-01.mp3」这类多集自动归成一本（现在是一集一条，靠文件夹歌单兜住）
- iCloud 书库同步
- CarPlay / 蓝牙车载
- 手动换封面、编辑书名
- 定时「听完这一集再关」的精确剩余时间显示

优先级我建议：**先按现在这版装到手机上跑一周**，把真正别扭的地方记下来，再动手。自用 App 最容易死在「功能都想加、一个都没用顺」。

---

## 七、踩坑速查

| 现象 | 原因 / 处理 |
| --- | --- |
| 安装报 `Unable to install` | bundle id 冲突，Sideloadly 里换个 bundle id 后缀 |
| 打开闪退 | 描述文件没信任，或 iOS 版本低于 16 |
| Artifacts 下不到 | Actions 没跑完；或仓库私有导致额度耗尽，改 Public |
| 编译报红 | 看 Actions 里 `Show compile errors` 步骤，或下 `build-log` 搜 `error:` |
| 后台不放 | 检查手机没开低电量模式（会限制后台音频），以及 App 没被手动划掉 |
| 导入了但列表没出现 | 文件扩展名不在白名单，看 `ImportService.supportedExtensions` |
| 导入提示「跳过重复」 | 同名书已在库里（按标题判重），改名后再导 |
| 快捷指令里搜不到 App | 先手动打开一次 App，再回到快捷指令 App 搜索 |
| 改名后桌面还是「有声书」 | 卸掉重装（图标名随 ipa 走，覆盖安装有时读缓存） |
| 歌单点不动 / 是空的 | 歌单里的音频被单本删掉了，删掉这个歌单重新导文件夹 |
| 书没封面 | 该文件本身没内嵌图，或格式是 wav/flac 这类不含封面的容器 |