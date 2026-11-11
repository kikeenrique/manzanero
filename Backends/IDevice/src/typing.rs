//! US-layout ASCII mapping to the pinned library's owned virtual keyboard.
use idevice::{
    ReadWrite,
    core_device::{KeyboardUsage, MainKeyboardService, UniversalHidServiceClient},
};
use std::time::Duration;

#[derive(Debug, PartialEq)]
pub struct Stroke {
    pub usage: u16,
    pub shift: bool,
}

pub fn parse(text: &str) -> Result<Vec<Stroke>, String> {
    if text.is_empty() || text.len() > 512 {
        return Err("Physical typing requires 1...512 US-layout ASCII characters".into());
    }
    text.bytes()
        .map(|byte| {
            let (usage, shift) = match byte {
                b'a'..=b'z' => ((byte - b'a' + 4) as u16, false),
                b'A'..=b'Z' => ((byte - b'A' + 4) as u16, true),
                b'1'..=b'9' => ((byte - b'1' + 0x1e) as u16, false),
                b'0' => (0x27, false),
                b' ' => (0x2c, false),
                b'\n' => (0x28, false),
                b'\t' => (0x2b, false),
                b'-' => (0x2d, false),
                b'_' => (0x2d, true),
                b'=' => (0x2e, false),
                b'+' => (0x2e, true),
                b'[' => (0x2f, false),
                b'{' => (0x2f, true),
                b']' => (0x30, false),
                b'}' => (0x30, true),
                b'\\' => (0x31, false),
                b'|' => (0x31, true),
                b';' => (0x33, false),
                b':' => (0x33, true),
                b'\'' => (0x34, false),
                b'"' => (0x34, true),
                b'`' => (0x35, false),
                b'~' => (0x35, true),
                b',' => (0x36, false),
                b'<' => (0x36, true),
                b'.' => (0x37, false),
                b'>' => (0x37, true),
                b'/' => (0x38, false),
                b'?' => (0x38, true),
                byte if b"!@#$%^&*()".contains(&byte) => (
                    0x1e + b"!@#$%^&*()".iter().position(|b| *b == byte).unwrap() as u16,
                    true,
                ),
                _ => return Err(
                    "Physical typing supports printable US-layout ASCII, tab, and LF newline only"
                        .into(),
                ),
            };
            Ok(Stroke { usage, shift })
        })
        .collect()
}

trait Keyboard {
    async fn set(&mut self, pressed: &[u16]) -> Result<(), String>;
    async fn remove(&mut self) -> Result<(), String>;
}

struct OwnedKeyboard<'a> {
    hid: &'a mut UniversalHidServiceClient<Box<dyn ReadWrite>>,
    service: MainKeyboardService,
}

impl Keyboard for OwnedKeyboard<'_> {
    async fn set(&mut self, pressed: &[u16]) -> Result<(), String> {
        let usages = pressed
            .iter()
            .map(|raw| KeyboardUsage::new(*raw).map_err(|e| e.to_string()))
            .collect::<Result<Vec<_>, _>>()?;
        self.hid
            .set_main_keyboard_usages(&mut self.service, usages)
            .await
            .map_err(|e| e.to_string())
    }
    async fn remove(&mut self) -> Result<(), String> {
        self.hid
            .remove_main_keyboard(&mut self.service)
            .await
            .map_err(|e| e.to_string())
    }
}

pub async fn dispatch(
    hid: &mut UniversalHidServiceClient<Box<dyn ReadWrite>>,
    strokes: &[Stroke],
) -> Result<(), String> {
    let service = hid
        .create_main_keyboard()
        .await
        .map_err(|e| format!("Create virtual keyboard: {e}"))?;
    send(
        &mut OwnedKeyboard { hid, service },
        strokes,
        Duration::from_millis(5),
    )
    .await
}

async fn send(
    keyboard: &mut impl Keyboard,
    strokes: &[Stroke],
    pause: Duration,
) -> Result<(), String> {
    send_with_deadlines(
        keyboard,
        strokes,
        pause,
        Duration::from_secs(30),
        Duration::from_secs(3),
    )
    .await
}

async fn send_with_deadlines(
    keyboard: &mut impl Keyboard,
    strokes: &[Stroke],
    pause: Duration,
    dispatch_limit: Duration,
    cleanup_limit: Duration,
) -> Result<(), String> {
    let result = tokio::time::timeout(dispatch_limit, async {
        for stroke in strokes {
            let pressed = if stroke.shift {
                vec![0xe1, stroke.usage]
            } else {
                vec![stroke.usage]
            };
            keyboard.set(&pressed).await?;
            tokio::time::sleep(pause).await;
            keyboard.set(&[]).await?;
            tokio::time::sleep(pause).await;
        }
        Ok::<(), String>(())
    })
    .await
    .map_err(|_| "Physical typing dispatch timed out".to_string())
    .and_then(|result| result);
    // Always reset/remove our owned keyboard after normal completion or dispatch error.
    let cleanup = tokio::time::timeout(cleanup_limit, keyboard.remove())
        .await
        .map_err(|_| "Virtual keyboard cleanup timed out".to_string())
        .and_then(|result| result);
    match (result, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(dispatch), Ok(())) => Err(dispatch),
        (Ok(()), Err(cleanup)) => Err(format!("Virtual keyboard cleanup failed: {cleanup}")),
        (Err(dispatch), Err(cleanup)) => Err(format!(
            "{dispatch}; virtual keyboard cleanup also failed: {cleanup}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_printable_ascii_and_control_keys() {
        assert!(parse(&(32u8..=126).map(char::from).collect::<String>()).is_ok());
        let strokes = parse("aAzZ10!?_\t\n").unwrap();
        assert_eq!(
            strokes
                .iter()
                .map(|s| (s.usage, s.shift))
                .collect::<Vec<_>>(),
            vec![
                (4, false),
                (4, true),
                (29, false),
                (29, true),
                (0x1e, false),
                (0x27, false),
                (0x1e, true),
                (0x38, true),
                (0x2d, true),
                (0x2b, false),
                (0x28, false)
            ]
        );
    }

    #[test]
    fn rejects_unsupported_text_before_connecting() {
        for text in ["", "é", "🙂", "\0", "\r", "\u{1b}"] {
            assert!(parse(text).is_err());
        }
        assert!(parse(&"a".repeat(512)).is_ok());
        assert!(parse(&"a".repeat(513)).is_err());
    }

    struct MockKeyboard {
        events: Vec<Vec<u16>>,
        removed: bool,
        fail_at: Option<usize>,
        fail_remove: bool,
        stall_set: bool,
        stall_remove: bool,
    }
    impl Keyboard for MockKeyboard {
        async fn set(&mut self, pressed: &[u16]) -> Result<(), String> {
            self.events.push(pressed.to_vec());
            if self.stall_set {
                return std::future::pending().await;
            }
            if self.fail_at == Some(self.events.len()) {
                return Err("fixture dispatch failure".into());
            }
            Ok(())
        }
        async fn remove(&mut self) -> Result<(), String> {
            self.removed = true;
            if self.stall_remove {
                return std::future::pending().await;
            }
            if self.fail_remove {
                Err("fixture cleanup failure".into())
            } else {
                Ok(())
            }
        }
    }
    fn keyboard(fail_at: Option<usize>, fail_remove: bool) -> MockKeyboard {
        MockKeyboard {
            events: vec![],
            removed: false,
            fail_at,
            fail_remove,
            stall_set: false,
            stall_remove: false,
        }
    }

    #[tokio::test]
    async fn releases_shift_between_characters_and_removes_owned_keyboard() {
        let mut keyboard = keyboard(None, false);
        send(&mut keyboard, &parse("Aa").unwrap(), Duration::ZERO)
            .await
            .unwrap();
        assert_eq!(
            keyboard.events,
            vec![vec![0xe1, 4], vec![], vec![4], vec![]]
        );
        assert!(keyboard.removed);
    }

    #[tokio::test]
    async fn removes_after_press_or_release_failure_and_stops_typing() {
        for fail_at in [1, 2] {
            let mut keyboard = keyboard(Some(fail_at), false);
            assert!(
                send(&mut keyboard, &parse("Ab").unwrap(), Duration::ZERO)
                    .await
                    .is_err()
            );
            assert!(keyboard.removed);
            assert_eq!(keyboard.events.len(), fail_at);
        }
    }

    #[tokio::test]
    async fn cleanup_failure_prevents_success_and_preserves_dispatch_failure() {
        for fail_at in [None, Some(1)] {
            let mut keyboard = keyboard(fail_at, true);
            let error = send(&mut keyboard, &parse("a").unwrap(), Duration::ZERO)
                .await
                .unwrap_err();
            assert!(error.contains("cleanup failure"));
            if fail_at.is_some() {
                assert!(error.contains("dispatch failure"));
            }
        }
    }

    #[tokio::test]
    async fn dispatch_timeout_still_attempts_removal() {
        let mut keyboard = keyboard(None, false);
        keyboard.stall_set = true;
        let error = send_with_deadlines(
            &mut keyboard,
            &parse("a").unwrap(),
            Duration::ZERO,
            Duration::from_millis(10),
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert!(error.contains("dispatch timed out"));
        assert!(keyboard.removed);
    }

    #[tokio::test]
    async fn cleanup_timeout_does_not_return_success() {
        let mut keyboard = keyboard(None, false);
        keyboard.stall_remove = true;
        let error = send_with_deadlines(
            &mut keyboard,
            &parse("a").unwrap(),
            Duration::ZERO,
            Duration::from_secs(1),
            Duration::from_millis(10),
        )
        .await
        .unwrap_err();
        assert!(error.contains("cleanup timed out"));
    }
}
