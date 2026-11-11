//! Coordinated linear contact paths using the pinned idevice multitouch API.
use idevice::{
    ReadWrite,
    core_device::{TouchscreenContact, UniversalHidServiceClient},
};
use std::time::Duration;

const STEPS: u32 = 30;

#[derive(Debug, PartialEq)]
pub struct Gesture {
    milliseconds: u64,
    paths: Vec<[u16; 4]>,
}

pub fn parse(values: &[String]) -> Result<Gesture, String> {
    if !(9..=21).contains(&values.len()) || (values.len() - 1) % 4 != 0 {
        return Err(
            "multi-drag requires duration and two to five start-x/start-y/end-x/end-y paths".into(),
        );
    }
    let milliseconds = values[0]
        .parse::<u64>()
        .map_err(|_| "Invalid gesture duration")?;
    if !(30..=10000).contains(&milliseconds) {
        return Err("Gesture duration must be 30...10000 ms".into());
    }
    let paths = values[1..]
        .chunks_exact(4)
        .map(|chunk| {
            let mut path = [0; 4];
            for (index, value) in chunk.iter().enumerate() {
                path[index] = value
                    .parse()
                    .map_err(|_| "Expected integer coordinate 0...65535")?;
            }
            Ok(path)
        })
        .collect::<Result<_, String>>()?;
    Ok(Gesture {
        milliseconds,
        paths,
    })
}

fn frame(gesture: &Gesture, step: u32) -> Vec<TouchscreenContact> {
    let interpolate = |start: u16, end: u16| -> u16 {
        // Signed arithmetic preserves decreasing paths without unsigned wraparound.
        (i64::from(start)
            + ((i64::from(end) - i64::from(start)) * i64::from(step)) / i64::from(STEPS))
            as u16
    };
    gesture
        .paths
        .iter()
        .enumerate()
        .map(|(index, p)| TouchscreenContact {
            identity: index as u8,
            touching: true,
            x: interpolate(p[0], p[2]),
            y: interpolate(p[1], p[3]),
        })
        .collect()
}

trait Touchscreen {
    async fn send(&mut self, contacts: &[TouchscreenContact]) -> Result<(), String>;
}

impl Touchscreen for UniversalHidServiceClient<Box<dyn ReadWrite>> {
    async fn send(&mut self, contacts: &[TouchscreenContact]) -> Result<(), String> {
        self.send_multitouch(contacts, None)
            .await
            .map_err(|e| e.to_string())
    }
}

pub async fn dispatch(
    hid: &mut UniversalHidServiceClient<Box<dyn ReadWrite>>,
    gesture: &Gesture,
) -> Result<(), String> {
    send(
        hid,
        gesture,
        Duration::from_millis(gesture.milliseconds + 5000),
        Duration::from_secs(3),
    )
    .await
}

async fn send(
    hid: &mut impl Touchscreen,
    gesture: &Gesture,
    limit: Duration,
    cleanup_limit: Duration,
) -> Result<(), String> {
    let mut contacts = frame(gesture, 0);
    let result = tokio::time::timeout(limit, async {
        hid.send(&contacts).await?;
        let started = tokio::time::Instant::now();
        for step in 1..=STEPS {
            // Absolute offsets avoid accumulated integer-millisecond truncation and drift.
            tokio::time::sleep_until(
                started
                    + Duration::from_nanos(
                        gesture.milliseconds * 1_000_000 * u64::from(step) / u64::from(STEPS),
                    ),
            )
            .await;
            contacts = frame(gesture, step);
            hid.send(&contacts).await?;
        }
        Ok::<(), String>(())
    })
    .await
    .map_err(|_| "Multitouch dispatch timed out".to_string())
    .and_then(|r| r);

    // A failed send may have reached the phone. Release every identity at its last attempted position.
    contacts.iter_mut().for_each(|c| c.touching = false);
    let cleanup = tokio::time::timeout(cleanup_limit, hid.send(&contacts))
        .await
        .map_err(|_| "Multitouch release timed out".to_string())
        .and_then(|r| r);
    match (result, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(dispatch), Ok(())) => Err(dispatch),
        (Ok(()), Err(cleanup)) => Err(format!("Multitouch release failed: {cleanup}")),
        (Err(dispatch), Err(cleanup)) => Err(format!(
            "{dispatch}; multitouch release also failed: {cleanup}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::core_device::build_multitouch_report;

    fn gesture(count: usize) -> Gesture {
        Gesture {
            milliseconds: 30,
            paths: (0..count).map(|i| [0, 65535, 65535, i as u16]).collect(),
        }
    }

    #[test]
    fn validates_shape_range_and_duration_before_io() {
        for values in [
            vec!["30"; 8],
            vec!["30"; 10],
            vec!["30"; 25],
            vec!["0"; 9],
            vec!["10001"; 9],
            vec!["65536"; 9],
        ] {
            assert!(parse(&values.iter().map(|s| s.to_string()).collect::<Vec<_>>()).is_err());
        }
        for count in 2..=5 {
            let mut values = vec!["65535".to_string(); 1 + count * 4];
            values[0] = "10000".into();
            assert_eq!(parse(&values).unwrap().paths.len(), count);
            values[1] = "-1".into();
            assert!(parse(&values).is_err());
        }
    }

    struct Mock {
        frames: Vec<Vec<TouchscreenContact>>,
        fail: Option<usize>,
        fail_release: bool,
        stall_active: bool,
        stall_release: bool,
    }
    impl Touchscreen for Mock {
        async fn send(&mut self, contacts: &[TouchscreenContact]) -> Result<(), String> {
            self.frames.push(contacts.to_vec());
            let release = contacts.iter().all(|c| !c.touching);
            if (release && self.stall_release) || (!release && self.stall_active) {
                return std::future::pending().await;
            }
            if self.fail == Some(self.frames.len()) || (release && self.fail_release) {
                return Err("fixture send failure".into());
            }
            Ok(())
        }
    }
    fn mock() -> Mock {
        Mock {
            frames: vec![],
            fail: None,
            fail_release: false,
            stall_active: false,
            stall_release: false,
        }
    }

    #[tokio::test]
    async fn includes_all_stable_identities_exact_endpoints_and_release_in_wire_frames() {
        for count in 2..=5 {
            let mut hid = mock();
            let g = gesture(count);
            send(&mut hid, &g, Duration::from_secs(1), Duration::from_secs(1))
                .await
                .unwrap();
            assert_eq!(hid.frames.len(), STEPS as usize + 2);
            for (step, contacts) in hid.frames.iter().enumerate() {
                let report = build_multitouch_report(contacts, Some(0)).unwrap();
                assert_eq!(report.len(), 58);
                assert_eq!(contacts.len(), count);
                for (id, c) in contacts.iter().enumerate() {
                    assert_eq!(c.identity, id as u8);
                    assert_eq!(c.touching, step <= STEPS as usize);
                    assert_eq!(
                        report[3 + id * 5],
                        if c.touching {
                            0xc0 | id as u8
                        } else {
                            id as u8
                        }
                    );
                    assert_eq!(&report[4 + id * 5..6 + id * 5], &c.x.to_le_bytes());
                    assert_eq!(&report[6 + id * 5..8 + id * 5], &c.y.to_le_bytes());
                }
            }
            for (i, c) in hid.frames[STEPS as usize].iter().enumerate() {
                assert_eq!((c.x, c.y), (65535, i as u16));
            }
            assert_eq!(hid.frames[0][0].x, 0);
            assert_eq!(hid.frames[0][0].y, 65535);
            assert_eq!(hid.frames[15][0].x, 32767);
            assert_eq!(hid.frames[15][0].y, 32768);
        }
    }

    #[tokio::test]
    async fn errors_and_timeout_attempt_release_without_success() {
        for fail in [1, 10, 31] {
            let mut hid = mock();
            hid.fail = Some(fail);
            assert!(
                send(
                    &mut hid,
                    &gesture(2),
                    Duration::from_secs(1),
                    Duration::from_secs(1)
                )
                .await
                .is_err()
            );
            let release = hid.frames.last().unwrap();
            assert!(release.iter().all(|c| !c.touching));
            assert_eq!(release[0].x, hid.frames[hid.frames.len() - 2][0].x);
            assert_eq!(hid.frames.len(), fail + 1);
        }
        let mut hid = mock();
        hid.stall_active = true;
        let error = send(
            &mut hid,
            &gesture(2),
            Duration::from_millis(5),
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert!(error.contains("dispatch timed out"));
        assert!(hid.frames.last().unwrap().iter().all(|c| !c.touching));
    }

    #[tokio::test]
    async fn release_error_and_release_timeout_prevent_success() {
        let mut hid = mock();
        hid.fail_release = true;
        assert!(
            send(
                &mut hid,
                &gesture(2),
                Duration::from_secs(1),
                Duration::from_secs(1)
            )
            .await
            .unwrap_err()
            .contains("release failed")
        );
        let mut hid = mock();
        hid.stall_release = true;
        assert!(
            send(
                &mut hid,
                &gesture(2),
                Duration::from_secs(1),
                Duration::from_millis(5)
            )
            .await
            .unwrap_err()
            .contains("release timed out")
        );
        let mut hid = mock();
        hid.fail = Some(1);
        hid.fail_release = true;
        assert!(
            send(
                &mut hid,
                &gesture(2),
                Duration::from_secs(1),
                Duration::from_secs(1)
            )
            .await
            .unwrap_err()
            .contains("also failed")
        );
    }
}
