//! Finite OS trace capture. Closing the receiver ends this client's subscription.
use idevice::os_trace_relay::{OsTraceRelayClient, OsTraceRelayReceiver};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::time::{Instant, timeout_at};

trait LogReader {
    async fn entry(&mut self) -> Result<Value, String>;
}

impl LogReader for OsTraceRelayReceiver {
    async fn entry(&mut self) -> Result<Value, String> {
        let entry = self
            .next()
            .await
            .map_err(|e| format!("Read OS trace: {e}"))?;
        serde_json::to_value(entry).map_err(|e| e.to_string())
    }
}

pub async fn capture(
    client: OsTraceRelayClient,
    seconds: u32,
    pid: Option<u32>,
) -> Result<Value, String> {
    let mut receiver = client
        .start_trace(pid)
        .await
        .map_err(|e| format!("Start OS trace: {e}"))?;
    let mut result = collect(
        &mut receiver,
        Duration::from_secs(seconds.into()),
        2000,
        4 * 1024 * 1024,
    )
    .await?;
    result["requestedSeconds"] = json!(seconds);
    result["pid"] = json!(pid);
    Ok(result)
}

// The size cap covers serialized entries, not allocations in the upstream decoder.
async fn collect(
    reader: &mut impl LogReader,
    duration: Duration,
    entry_limit: usize,
    byte_limit: usize,
) -> Result<Value, String> {
    let deadline = Instant::now() + duration;
    let mut entries = Vec::new();
    let mut bytes = 0;
    let reason = loop {
        if entries.len() >= entry_limit {
            break "entryLimit";
        }
        if Instant::now() >= deadline {
            break "duration";
        }
        let entry = match timeout_at(deadline, reader.entry()).await {
            Err(_) => break "duration",
            Ok(result) => result?,
        };
        let size = serde_json::to_vec(&entry).map_err(|e| e.to_string())?.len();
        if size > byte_limit - bytes {
            break "byteLimit";
        }
        bytes += size;
        entries.push(entry);
    };
    Ok(
        json!({"entries": entries, "entryBytes": bytes, "stopReason": reason,
        "truncated": reason != "duration", "experimental": true}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    struct Reader(VecDeque<Result<Value, String>>);
    impl LogReader for Reader {
        async fn entry(&mut self) -> Result<Value, String> {
            match self.0.pop_front() {
                Some(value) => value,
                None => std::future::pending().await,
            }
        }
    }

    #[tokio::test]
    async fn idle_stream_stops_at_deadline() {
        let mut reader = Reader(VecDeque::new());
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            collect(&mut reader, Duration::from_millis(10), 10, 1024),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(result["stopReason"], "duration");
        assert_eq!(result["entries"], json!([]));
        assert_eq!(result["truncated"], false);
    }

    #[tokio::test]
    async fn entry_limit_preserves_order_and_marks_truncation() {
        let mut reader = Reader(VecDeque::from([
            Ok(json!({"message":"one"})),
            Ok(json!({"message":"two"})),
            Ok(json!({"message":"three"})),
        ]));
        let result = collect(&mut reader, Duration::from_secs(1), 2, 1024)
            .await
            .unwrap();
        assert_eq!(result["stopReason"], "entryLimit");
        assert_eq!(
            result["entries"],
            json!([{"message":"one"}, {"message":"two"}])
        );
        assert_eq!(result["truncated"], true);
        assert_eq!(reader.0.len(), 1);
    }

    #[tokio::test]
    async fn byte_limit_excludes_oversized_entry() {
        let entry = json!({"message":"one"});
        let size = serde_json::to_vec(&entry).unwrap().len();
        let mut reader = Reader(VecDeque::from([Ok(entry.clone()), Ok(entry.clone())]));
        let result = collect(&mut reader, Duration::from_secs(1), 10, size)
            .await
            .unwrap();
        assert_eq!(result["entries"], json!([entry]));
        assert_eq!(result["entryBytes"], size);
        assert_eq!(result["stopReason"], "byteLimit");
        assert_eq!(result["truncated"], true);
    }

    #[tokio::test]
    async fn service_failure_is_not_reported_as_complete_capture() {
        let mut reader = Reader(VecDeque::from([
            Ok(json!({"message":"one"})),
            Err("connection lost".into()),
        ]));
        assert_eq!(
            collect(&mut reader, Duration::from_secs(1), 10, 1024)
                .await
                .unwrap_err(),
            "connection lost"
        );
    }
}
