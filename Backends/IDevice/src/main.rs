//! Small process boundary around idevice's private CoreDevice interfaces.
//! Arguments are supplied by the Swift planner; stdout is JSON only.
use idevice::{
    RsdService,
    core_device::{ButtonState, IndigoHidClient, UniversalHidServiceClient},
};
use serde_json::{Value, json};
use std::time::Duration;

mod pairing;
mod stream;
mod transport;

#[derive(Debug, PartialEq)]
enum Action {
    Surfaces,
    Tap(u16, u16),
    MultiTap(Vec<(u16, u16)>),
    Drag(u16, u16, u16, u16, u64),
    Button(u64, u64),
    Key(u64),
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
        "hid-info" if values.is_empty() => Action::Surfaces,
        "tap" if values.len() == 2 => Action::Tap(number(0)?, number(1)?),
        "multi-tap" if (4..=10).contains(&values.len()) && values.len() % 2 == 0 => {
            let points = (0..values.len())
                .step_by(2)
                .map(|i| Ok((number(i)?, number(i + 1)?)))
                .collect::<Result<Vec<_>, String>>()?;
            Action::MultiTap(points)
        }
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

async fn execute(
    udid: &str,
    action: Action,
    record_path: Option<&std::path::Path>,
) -> Result<Value, String> {
    let mut connection = transport::connect(udid, record_path).await?;
    let adapter = &mut connection.adapter;
    let rsd = &mut connection.rsd;

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
    }
}
