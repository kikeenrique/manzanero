//! Small process boundary around idevice's private CoreDevice interfaces.
//! Arguments are supplied by the Swift planner; stdout is JSON only.
use idevice::{
    RsdService,
    core_device::{ButtonState, IndigoHidClient, UniversalHidServiceClient},
};
use serde_json::{Value, json};
use std::time::Duration;

mod accessibility;
mod archive;
mod ax_tree;
mod gesture;
mod logs;
mod pairing;
mod stream;
mod transport;
mod typing;

#[derive(Debug, PartialEq)]
enum Action {
    Surfaces,
    Logs(u32, Option<u32>),
    AccessibilitySnapshot,
    AccessibilityTree(Option<u32>),
    AccessibilityPress(Option<u32>, String, String),
    Tap(u16, u16),
    MultiTap(Vec<(u16, u16)>),
    MultiDrag(gesture::Gesture),
    Drag(u16, u16, u16, u16, u64),
    Button(u64, u64),
    Key(u64),
    Type(Vec<typing::Stroke>),
}

fn parse(args: &[String]) -> Result<(&str, Action), String> {
    if args.len() < 2 || args[0].is_empty() || args[0].starts_with('-') {
        return Err("Expected UDID and operation".into());
    }
    let values = &args[2..];
    let number = |i: usize| -> Result<u16, String> {
        values
            .get(i)
            .ok_or("Missing coordinate")?
            .parse()
            .map_err(|_| "Expected integer coordinate 0...65535".into())
    };
    let action = match args[1].as_str() {
        "type" if values.len() == 1 => Action::Type(typing::parse(&values[0])?),
        "logs" if (1..=2).contains(&values.len()) => {
            let seconds: u32 = values[0].parse().map_err(|_| "Invalid log duration")?;
            if !(1..=30).contains(&seconds) {
                return Err("Log duration must be 1...30 seconds".into());
            }
            let pid = values
                .get(1)
                .map(|s| s.parse::<u32>().map_err(|_| "Invalid log PID"))
                .transpose()?;
            if pid.is_some_and(|p| p == 0 || p > i32::MAX as u32) {
                return Err("Invalid log PID".into());
            }
            Action::Logs(seconds, pid)
        }
        "hid-info" if values.is_empty() => Action::Surfaces,
        "ax-snapshot" if values.is_empty() => Action::AccessibilitySnapshot,
        "tree" if values.len() <= 1 => {
            let pid = values
                .first()
                .map(|v| {
                    v.parse::<u32>()
                        .map_err(|_| "Invalid AX tree PID".to_string())
                })
                .transpose()?;
            if pid.is_some_and(|pid| pid == 0 || pid > i32::MAX as u32) {
                return Err("Invalid AX tree PID".into());
            }
            Action::AccessibilityTree(pid)
        }
        "press-id" | "press-label" if (1..=2).contains(&values.len()) => {
            let pid = if values.len() == 2 {
                Some(
                    values[0]
                        .parse::<u32>()
                        .map_err(|_| "Invalid AX press PID")?,
                )
            } else {
                None
            };
            let text = values.last().unwrap();
            if pid.is_some_and(|pid| pid == 0 || pid > i32::MAX as u32)
                || text.is_empty()
                || text.len() > 4096
                || text.contains('\0')
            {
                return Err("Invalid AX press PID or selector".into());
            }
            Action::AccessibilityPress(
                pid,
                if args[1] == "press-id" {
                    "identifier"
                } else {
                    "label"
                }
                .into(),
                text.clone(),
            )
        }
        "tap" if values.len() == 2 => Action::Tap(number(0)?, number(1)?),
        "multi-tap" if (4..=10).contains(&values.len()) && values.len() % 2 == 0 => {
            let points = (0..values.len())
                .step_by(2)
                .map(|i| Ok((number(i)?, number(i + 1)?)))
                .collect::<Result<Vec<_>, String>>()?;
            Action::MultiTap(points)
        }
        "multi-drag" => Action::MultiDrag(gesture::parse(values)?),
        "drag" if values.len() == 5 => {
            let ms: u64 = values[4].parse().map_err(|_| "Invalid drag duration")?;
            if !(30..=10000).contains(&ms) {
                return Err("Drag duration must be 30...10000 ms".into());
            }
            Action::Drag(number(0)?, number(1)?, number(2)?, number(3)?, ms)
        }
        "button" if values.len() == 1 => {
            let usage = match values[0].as_str() {
                "home" => 0x40,
                "lock" => 0x30,
                "volume-up" => 0xE9,
                "volume-down" => 0xEA,
                _ => return Err("Supported buttons: home, lock, volume-up, volume-down".into()),
            };
            Action::Button(0x0C, usage)
        }
        "key" if values.len() == 1 => {
            let usage = match values[0].as_str() {
                "return" => 0x28,
                "escape" => 0x29,
                "backspace" => 0x2A,
                "tab" => 0x2B,
                "space" => 0x2C,
                "right" => 0x4F,
                "left" => 0x50,
                "down" => 0x51,
                "up" => 0x52,
                _ => return Err("Unknown keyboard key".into()),
            };
            Action::Key(usage)
        }
        _ => return Err("Unsupported operation or incorrect operands".into()),
    };
    Ok((&args[0], action))
}

async fn connect_display(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    rsd: &idevice::rsd::RsdHandshake,
) -> Result<idevice::core_device::CoreDeviceServiceClient<Box<dyn idevice::ReadWrite>>, String> {
    let feature = "com.apple.coredevice.feature.getdisplayinfo";
    let services = rsd
        .services
        .values()
        .filter(|s| {
            s.uses_remote_xpc
                && s.features.as_ref().is_some_and(|features| {
                    features
                        .iter()
                        .any(|f| f == feature || f == "getdisplayinfo")
                })
        })
        .collect::<Vec<_>>();
    if services.len() != 1 {
        return Err(
            "AX foreground selection requires exactly one advertised display-info service".into(),
        );
    }
    let stream = adapter
        .connect(services[0].port)
        .await
        .map_err(|e| e.to_string())?;
    idevice::core_device::CoreDeviceServiceClient::new(
        Box::new(stream) as Box<dyn idevice::ReadWrite>
    )
    .await
    .map_err(|e| e.to_string())
}

async fn execute(
    udid: &str,
    action: Action,
    record_path: Option<&std::path::Path>,
) -> Result<Value, String> {
    let mut connection = transport::connect(udid, record_path).await?;
    let adapter = &mut connection.adapter;
    let rsd = &mut connection.rsd;

    if let Action::Logs(seconds, pid) = action {
        let client = idevice::os_trace_relay::OsTraceRelayClient::connect_rsd(adapter, rsd)
            .await
            .map_err(|e| format!("OS trace relay connect: {e}"))?;
        let mut result = logs::capture(client, seconds, pid).await?;
        result["backend"] = json!("idevice");
        result["transport"] = json!(connection.name);
        return Ok(result);
    }
    if matches!(
        action,
        Action::AccessibilitySnapshot
            | Action::AccessibilityTree(_)
            | Action::AccessibilityPress(..)
    ) {
        let service = rsd
            .services
            .get("com.apple.accessibility.axAuditDaemon.remoteAXService")
            .ok_or("Device does not advertise the iOS 27 remote accessibility service")?;
        let mut socket = adapter
            .connect(service.port)
            .await
            .map_err(|e| format!("Remote accessibility connect: {e}"))?;
        let mut snapshot = match action {
            Action::AccessibilityTree(Some(pid)) => ax_tree::capture(&mut socket, pid).await?,
            Action::AccessibilityTree(None) => {
                let mut displays = connect_display(adapter, rsd).await?;
                ax_tree::capture_foreground(&mut socket, &mut displays).await?
            }
            Action::AccessibilityPress(pid, selector, text) => {
                let mut displays = connect_display(adapter, rsd).await?;
                ax_tree::press(&mut socket, &mut displays, pid, &selector, &text).await?
            }
            _ => accessibility::capture(&mut socket).await?,
        };
        snapshot["backend"] = json!("idevice");
        snapshot["transport"] = json!(connection.name);
        return Ok(snapshot);
    }

    if action == Action::Surfaces {
        let mut hid = UniversalHidServiceClient::connect_rsd(adapter, rsd)
            .await
            .map_err(|e| e.to_string())?;
        let surfaces = hid
            .list_connected_services()
            .await
            .map_err(|e| e.to_string())?;
        return Ok(
            json!({"backend": "idevice", "transport": connection.name, "surfaces": surfaces.iter().map(|s| json!({
            "serviceID": s.service_id, "product": s.product, "usage": s.primary_usage, "usagePage": s.primary_usage_page
        })).collect::<Vec<_>>()}),
        );
    }

    // Keep UDP sockets and display stream alive while input is dispatched.
    let mut session = stream::start(adapter, rsd).await?;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let result: Result<(), String> = async {
        match action {
            Action::Type(ref strokes) => {
                let mut hid = UniversalHidServiceClient::connect_rsd(adapter, rsd)
                    .await
                    .map_err(|e| e.to_string())?;
                typing::dispatch(&mut hid, strokes).await?;
            }
            Action::Button(_, _) | Action::Key(_) => {
                let mut hid = IndigoHidClient::connect_rsd(adapter, rsd)
                    .await
                    .map_err(|e| e.to_string())?;
                match action {
                    Action::Button(page, usage) => {
                        hid.send_button(page, usage, ButtonState::Down)
                            .await
                            .map_err(|e| e.to_string())?;
                        tokio::time::sleep(Duration::from_millis(80)).await;
                        hid.send_button(page, usage, ButtonState::Up)
                            .await
                            .map_err(|e| e.to_string())?;
                    }
                    Action::Key(usage) => {
                        hid.send_keyboard(usage, ButtonState::Down)
                            .await
                            .map_err(|e| e.to_string())?;
                        hid.send_keyboard(usage, ButtonState::Up)
                            .await
                            .map_err(|e| e.to_string())?;
                    }
                    _ => unreachable!(),
                }
            }
            _ => {
                let mut hid = UniversalHidServiceClient::connect_rsd(adapter, rsd)
                    .await
                    .map_err(|e| e.to_string())?;
                match action {
                    Action::Tap(x, y) => hid.tap(x, y).await,
                    Action::MultiTap(points) => hid.multi_tap(&points).await,
                    Action::MultiDrag(ref gesture) => {
                        gesture::dispatch(&mut hid, gesture).await?;
                        return Ok(());
                    }
                    Action::Drag(x1, y1, x2, y2, ms) => hid.drag(x1, y1, x2, y2, 30, ms / 30).await,
                    _ => unreachable!(),
                }
                .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
    .await;
    // The protocol currently exposes stopAll, so this backend must own the stream.
    let cleanup = session
        .client
        .stop_media_stream()
        .await
        .map_err(|e| format!("Stop media stream: {e}"));
    result?;
    cleanup?;
    Ok(
        json!({"backend": "idevice", "status": "dispatched", "verified": false, "transport": connection.name}),
    )
}

async fn run(args: &[String]) -> Result<Value, String> {
    if args.first().is_some_and(|a| a == "decode-ax-archive") {
        if args.len() != 2 {
            return Err("Expected decode-ax-archive LOCAL-PLIST".into());
        }
        return archive::decode_file(std::path::Path::new(&args[1]));
    }
    if args.first().is_some_and(|a| a == "pair-wifi") {
        if args.len() != 4 {
            return Err("Expected pair-wifi HOST PORT DESTINATION".into());
        }
        let port: u16 = args[2].parse().map_err(|_| "Invalid Wi-Fi port")?;
        return tokio::time::timeout(
            Duration::from_secs(180),
            pairing::pair(&args[1], port, std::path::Path::new(&args[3])),
        )
        .await
        .map_err(|_| "Wi-Fi pairing timed out".to_string())?;
    }
    let (record, args) = if args.first().is_some_and(|a| a == "--pairing-file") {
        if args.len() < 4 || args[1].is_empty() {
            return Err("--pairing-file requires a path and device operation".into());
        }
        (Some(std::path::Path::new(&args[1])), &args[2..])
    } else {
        (None, args)
    };
    let (udid, action) = parse(args)?;
    tokio::time::timeout(Duration::from_secs(60), execute(udid, action, record))
        .await
        .map_err(|_| {
            "CoreDevice operation timed out; inspect device state before retrying input".to_string()
        })?
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--version"] {
        println!("appledevices-idevice 0.1.0 (idevice 89702099f4d7552f704f93b4526756abda319ceb)");
        return;
    }
    let result = run(&args).await;
    match result {
        Ok(value) => println!("{value}"),
        Err(message) => {
            eprintln!(
                "{}",
                json!({"error": {"backend": "idevice", "message": message}})
            );
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }
    #[test]
    fn validates_before_connecting() {
        for values in [
            vec!["test", "tap", "65536", "0"],
            vec!["test", "drag", "0", "0", "1", "1", "0"],
            vec!["test", "multi-tap", "1", "2", "3"],
            vec!["test", "key", "--help"],
            vec!["test", "logs", "0"],
            vec!["test", "logs", "31"],
            vec!["test", "logs", "1", "0"],
            vec!["test", "logs", "1", "4294967295"],
        ] {
            assert!(parse(&args(&values)).is_err());
        }
    }
    #[test]
    fn parses_multitouch() {
        assert_eq!(
            parse(&args(&[
                "test",
                "multi-tap",
                "0",
                "65535",
                "32768",
                "32768"
            ]))
            .unwrap()
            .1,
            Action::MultiTap(vec![(0, 65535), (32768, 32768)])
        );
        assert!(matches!(
            parse(&args(&[
                "test",
                "multi-drag",
                "30",
                "0",
                "0",
                "65535",
                "65535",
                "65535",
                "65535",
                "0",
                "0"
            ]))
            .unwrap()
            .1,
            Action::MultiDrag(_)
        ));
    }
}
