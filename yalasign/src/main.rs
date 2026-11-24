//! yalasign — 重签并安装 unsigned IPA 到本机 iOS 设备。
//!
//! 复用 iloader 已经存进 Windows 凭据管理器（service = "iloader"）的东西：
//!   - `<apple-id>`                 Apple ID 密码
//!   - `anisette_state`             远端 v3 anisette 的 adi.pb
//!   - `<userhash>/key`             开发证书私钥
//!   - `rppairing1.1_file_<UDID>`   远程配对记录
//!
//! 因此签名的 machine_name / storage / anisette 参数必须和 iloader 完全一致，
//! 否则它会去注册一张新证书、消耗免费账号的 App ID 配额。

use futures::FutureExt;
use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};
use isideload::{
    anisette::{AnisetteClientInfo, remote_v3::RemoteV3AnisetteProvider},
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::developer_session::DeveloperSession,
    sideload::{
        builder::{
            ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior, TeamSelection,
        },
        SideloaderBuilder,
    },
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
        keyring_storage::KeyringStorage,
    },
};
use std::{env, io::Write, path::PathBuf};
use tracing::Level;
use tracing_subscriber::FmtSubscriber;

const DEFAULT_ANISETTE_URL: &str = "https://mac-ani.jkcoxson.com";
/// 2FA 验证码 handoff 文件：外部把 6 位码写进去，进程读到就提交。
const TFA_HANDOFF: &str = r"C:\yalasign-work\2fa.txt";
/// X-Mme-Client-Info / UA。
///
/// 实证（2026-11-14 ~ 11-16，同一台机器连续装 0.4.1…0.4.7 全部成功）：
/// 使用下面这套「2026 年 Mac15,7 + macOS 27」的声明能通过 GSA。
/// 反过来信任 anisette 服务端 `/v3/client_info` 返回的
/// 「MacBookPro13,3 + Mac OS X 10.12.6」会稳定拿到 -22410
/// —— 服务端的 MD 数据实际绑的是新机器，client_info 端点是老模板。
const CLIENT_INFO: &str =
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
const USER_AGENT: &str = "akd/1.0 CFNetwork/811.5.4";
const MACHINE_NAME: &str = "iloader";
const KEYRING_SERVICE: &str = "iloader";

struct Args {
    ipa: Option<PathBuf>,
    apple_id: Option<String>,
    anisette_url: String,
    dry_run: bool,
    list_devices: bool,
    /// true = 用 CLIENT_INFO 常量的旧值（Mac15,7 / macOS 27）覆盖 anisette 服务端的 client_info。
    legacy_client_info: bool,
}

impl Default for Args {
    fn default() -> Self {
        Args {
            ipa: None,
            apple_id: None,
            anisette_url: DEFAULT_ANISETTE_URL.to_string(),
            dry_run: false,
            list_devices: false,
            legacy_client_info: false,
        }
    }
}

fn usage() -> ! {
    eprintln!(
        "yalasign — 用 iloader 的凭据重签并安装 IPA\n\n\
用法:\n  \
yalasign --ipa <path> [--apple-id <mail>] [--anisette <url>] [--dry-run]\n  \
yalasign --list-devices\n\n\
参数:\n  \
--ipa <path>        要安装的 .ipa 文件\n  \
--apple-id <mail>   Apple ID，默认从 iloader 的 data.json 读取\n  \
--anisette <url>    anisette 服务端，默认 {DEFAULT_ANISETTE_URL}\n  \
--legacy-client-info 用硬编码的 Mac15,7 / macOS 27 声明覆盖服务端 client_info\n  \
--dry-run           只登录并检查证书/设备，不实际安装\n  \
--list-devices      列出当前连接的设备\n"
    );
    std::process::exit(2);
}

fn parse_args() -> Args {
    let mut a = Args::default();
    let mut it = env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--ipa" => a.ipa = Some(PathBuf::from(it.next().unwrap_or_else(|| usage()))),
            "--apple-id" => a.apple_id = Some(it.next().unwrap_or_else(|| usage())),
            "--anisette" => {
                let mut u = it.next().unwrap_or_else(|| usage());
                if !u.starts_with("http") {
                    u = format!("https://{u}");
                }
                a.anisette_url = u;
            }
            "--legacy-client-info" => a.legacy_client_info = true,
            "--dry-run" => a.dry_run = true,
            "--list-devices" => a.list_devices = true,
            "-h" | "--help" => usage(),
            other => {
                eprintln!("未知参数: {other}");
                usage();
            }
        }
    }
    a
}

fn apple_id_from_iloader() -> Option<String> {
    let base = env::var_os("APPDATA").map(PathBuf::from)?;
    let path = base.join("me.nabdev.iloader").join("data.json");
    let text = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    v.get("ids")?
        .as_array()?
        .first()?
        .as_str()
        .map(|s| s.to_string())
}

fn read_password(email: &str) -> Result<String, String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, email)
        .map_err(|e| format!("打开凭据条目失败: {e}"))?;
    entry.get_password().map_err(|e| {
        format!("读取 Apple ID 密码失败（是否在 iloader 里勾过 Save Credentials？）: {e}")
    })
}

type TfaBox = Box<
    dyn Fn(TwoFactorCallbackParams) -> futures::future::BoxFuture<'static, Result<TwoFactorCallbackResponse, rootcause::Report>>
        + Send
        + Sync,
>;

fn two_factor_callback() -> TfaBox {
    Box::new(move |params: TwoFactorCallbackParams| {
        async move {
            if params.unknown {
                eprintln!("[2FA] 上一次验证方式失效，请改用其他方式。");
            } else if params.sms {
                eprintln!("[2FA] 验证码已通过短信发送到你的手机。");
            } else {
                eprintln!("[2FA] 验证码已推送到你的受信任设备。");
            }

            // 优先读环境变量，其次轮询 handoff 文件。
            // 绝不返回空码——苹果对错误/空码计数，累计后返回
            // -22982 Too many verification attempts，账号会被锁一段时间。
            if let Ok(v) = std::env::var("YALASIGN_2FA") {
                let v = v.trim().to_string();
                if v.len() >= 6 {
                    eprintln!("[2FA] 使用 YALASIGN_2FA 环境变量里的验证码");
                    return Ok(TwoFactorCallbackResponse::SubmitCode(v));
                }
            }

            let path = std::path::PathBuf::from(TFA_HANDOFF);
            eprintln!(
                "[2FA] 等待验证码文件：{}（写入 6 位码后本进程会自动读取并提交）",
                path.display()
            );
            for _ in 0..240 {
                if let Ok(s) = std::fs::read_to_string(&path) {
                    let s = s.trim().to_string();
                    if s.len() >= 6 {
                        let _ = std::fs::remove_file(&path);
                        eprintln!("[2FA] 已读取验证码，提交中");
                        return Ok(TwoFactorCallbackResponse::SubmitCode(s));
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            }
            Err(rootcause::report!(
                "等待 2FA 验证码超时（20 分钟）：既没有 YALASIGN_2FA，也没等到 {}",
                path.display()
            ))
        }
        .boxed()
    })
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();

    let _ = tracing::subscriber::set_global_default(
        FmtSubscriber::builder()
            .with_max_level(Level::INFO)
            .finish(),
    );

    let args = parse_args();

    if args.list_devices {
        match UsbmuxdConnection::default().await {
            Ok(mut mux) => match mux.get_devices().await {
                Ok(devs) if devs.is_empty() => {
                    println!("没有检测到设备（请插线、解锁手机并点「信任」）")
                }
                Ok(devs) => {
                    for d in &devs {
                        println!("{}", d.udid);
                    }
                }
                Err(e) => println!("读取设备列表失败: {e}"),
            },
            Err(e) => println!("连接 usbmuxd 失败（Apple Mobile Device Service 是否在运行？）: {e}"),
        }
        return;
    }

    let ipa = match args.ipa.clone() {
        Some(p) => p,
        None => usage(),
    };
    if !ipa.exists() {
        eprintln!("IPA 不存在: {}", ipa.display());
        std::process::exit(1);
    }

    let email = args
        .apple_id
        .clone()
        .or_else(apple_id_from_iloader)
        .unwrap_or_else(|| {
            eprintln!("拿不到 Apple ID：请用 --apple-id 指定，或先在 iloader 里登录一次");
            std::process::exit(1);
        });

    println!("Apple ID : {email}");
    println!("anisette : {}", args.anisette_url);
    println!("IPA      : {}", ipa.display());

    let password = match read_password(&email) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };

    let anisette = match RemoteV3AnisetteProvider::default() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("初始化 anisette 失败: {e:?}");
            std::process::exit(1);
        }
    }
    .set_serial_number("0".to_string())
    .set_storage(Box::new(KeyringStorage::new(KEYRING_SERVICE.to_string())));
    // 默认跟随 anisette 服务端 /v3/client_info；--legacy-client-info 时用旧硬编码值。
    let anisette = if args.legacy_client_info {
        anisette.set_client_info_override(Some(AnisetteClientInfo {
            client_info: CLIENT_INFO.to_string(),
            user_agent: USER_AGENT.to_string(),
        }))
    } else {
        anisette
    };
    let anisette = anisette.set_url(&args.anisette_url);

    println!("[1/4] 登录 Apple ID …");
    let mut account = match AppleAccount::builder(&email.to_lowercase())
        .anisette_provider(anisette)
        .login(&password, two_factor_callback())
        .await
    {
        Ok(a) => a,
        Err(e) => {
            eprintln!("登录失败: {e}");
            std::process::exit(1);
        }
    };
    println!("      登录成功");

    let dev_session = match DeveloperSession::from_account(&mut account).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("创建开发者会话失败: {e}");
            std::process::exit(1);
        }
    };

    let max_certs: MaxCertsCallbackBox = Box::new(|certs| {
        Box::pin(async move {
            eprintln!("[警告] 开发证书已达上限（{} 张）", certs.len());
            Ok(None)
        })
    });

    let mut sideloader =
        SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(
            dev_session,
            email.to_lowercase(),
        )
        .machine_name(MACHINE_NAME.to_string())
        .storage(Box::new(KeyringStorage::new(KEYRING_SERVICE.to_string())))
        .extensions_behavior(ExtensionsBehaviorSelection::Fixed(
            ExtensionsBehavior::ReuseMain,
        ))
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Prompt(max_certs))
        .delete_app_after_install(true)
        .build();

    println!("[2/4] 查找设备 …");
    let mut mux = match UsbmuxdConnection::default().await {
        Ok(m) => m,
        Err(e) => {
            eprintln!("连接 usbmuxd 失败: {e}");
            std::process::exit(1);
        }
    };
    let devices = match mux.get_devices().await {
        Ok(d) => d,
        Err(e) => {
            eprintln!("读取设备列表失败: {e}");
            std::process::exit(1);
        }
    };
    let device = match devices.first() {
        Some(d) => d,
        None => {
            eprintln!("没有检测到设备：请插线、解锁手机并点「信任」");
            std::process::exit(1);
        }
    };
    let udid = device.udid.clone();
    println!("      设备: {udid}");

    let provider = device.to_provider(UsbmuxdAddr::default(), "yalasign");

    match sideloader.get_team().await {
        Ok(t) => println!(
            "      团队: {} ({})",
            t.name.as_deref().unwrap_or("<无名>"),
            t.team_id
        ),
        Err(e) => {
            eprintln!("获取开发者团队失败: {e}");
            std::process::exit(1);
        }
    }

    if args.dry_run {
        println!("[3/4] --dry-run，跳过签名");
        return;
    }

    println!("[3/4] 签名并安装 …");
    let result = sideloader
        .install_app(
            &provider,
            ipa,
            true,
            None::<fn(f32) -> std::future::Ready<()>>,
            None,
        )
        .await;

    match result {
        Ok(_) => {
            println!("[4/4] 安装完成，7 天内有效");
        }
        Err(e) => {
            eprintln!("安装失败: {e}");
            std::process::exit(1);
        }
    }
}
