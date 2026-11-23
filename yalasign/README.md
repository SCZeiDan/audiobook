# yalasign

把 unsigned IPA 重签并装进本机 iPhone 的小命令行工具。**它不重新登录、不重新注册 App ID、不吃新的证书** —— 它复用 [iloader](https://github.com/nab138/iloader) 已经存在 Windows 凭据管理器里的那一套东西。

## 为什么需要它

苹果从 2026-10 起拒绝了非 Mac 机器生成的 anisette 数据，Sideloadly 之类的工具登录直接报 `-80046`。iloader 换成了远端 anisette（`mac-ani.jkcoxson.com`），能过；但 iloader 是个 GUI，没有命令行，也没有自动重签 —— 每 7 天得手动拖一次 ipa。

`yalasign` 把 iloader 背后那个签名库（[isideload](https://github.com/nab138/isideload)）直接拿出来用，做成一个可以塞进计划任务的 exe。

## 前置条件

1. 电脑上装过 iloader，并且**登录过一次**（勾了 `Save Credentials`）
2. 手机插线、解锁、点过「信任」
3. `Apple Mobile Device Service` 在运行（装了 iTunes 或 Apple Devices 就有）

它从凭据管理器读这些条目，service 名都是 `iloader`：

| 条目 | 用途 |
| --- | --- |
| `<apple-id>` | Apple ID 密码 |
| `anisette_state` | 远端 v3 anisette 的 adi.pb |
| `<userhash>/key` | 开发证书私钥 |
| `rppairing1.1_file_<UDID>` | 远程配对记录 |

## 用法

```powershell
# 看设备
.\yalasign.exe --list-devices

# 试运行：登录 + 查团队，不签名
.\yalasign.exe --ipa "C:\path\app.ipa" --dry-run

# 真装
.\yalasign.exe --ipa "C:\path\app.ipa"

# 指定账号 / 换 anisette 服务端
.\yalasign.exe --ipa app.ipa --apple-id you@example.com --anisette https://mac-ani.jkcoxson.com
```

首次运行会打印日志。如果 Apple 要求 2FA，会停下来问你要 6 位验证码；只要 iloader 那边的会话还有效，通常不会问。

## 关键实现细节

这几个参数**必须**和 iloader 一模一样，否则它认不出你已有的证书，会去注册新的（免费账号 7 天只有 10 个 App ID 配额）：

```rust
.machine_name("iloader")
.storage(KeyringStorage::new("iloader"))
.anisette_provider(
    RemoteV3AnisetteProvider::default()?
        .set_serial_number("0")
        .set_client_info_override(Some(AnisetteClientInfo {
            client_info: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            user_agent: "akd/1.0 CFNetwork/811.5.4",
        }))
        .set_url("https://mac-ani.jkcoxson.com")
)
```

`machine_name` 是证书 identity 的盐；`client_info_override` 是绕过 2026-10 那道校验的关键（iloader 源码里注释写着 *"just temporary while waiting for the anisette servers to start reporting this"*）。

## 编译

没有预编译包，自己编或者用 Actions：

```powershell
cargo build --release
# 产物：target\release\yalasign.exe
```

`.github/workflows/build.yml` 会在 push 到 main 时用 `windows-latest` 编译并上传 artifact。

## 许可证

MIT。签名逻辑全部来自 [isideload](https://github.com/nab138/isideload)（MIT），通信来自 [idevice](https://github.com/jkcoxson/idevice)。

本项目与 iloader、isideload 的作者无关，只是它们的使用者。
