//! Experimental iOS 27 remote accessibility observation. No proprietary code is linked.
//! DTX encoding comes from idevice; selectors are interoperability research facts.
use base64::Engine;
use idevice::{
    ReadWrite,
    dvt::message::{Aux, AuxValue, Message, MessageHeader, PayloadHeader},
};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const MAX_FRAME: usize = 16 * 1024 * 1024;
const CALLBACK: &str = "processDataFromRemoteDevice:";

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("validated DTX header"),
    )
}

fn validate_header(
    header: &[u8; 32],
    expected_fragment: u16,
    total: usize,
) -> Result<(u16, usize), String> {
    let fragment = u16::from_le_bytes([header[8], header[9]]);
    let count = u16::from_le_bytes([header[10], header[11]]);
    let length = u32_at(header, 12) as usize;
    if u32_at(header, 0) != 0x1f3d5b79
        || u32_at(header, 4) != 32
        || count == 0
        || count > 64
        || fragment != expected_fragment
        || fragment >= count
        || length > MAX_FRAME
        || total.saturating_add(length) > MAX_FRAME
    {
        return Err("Invalid or oversized DTX accessibility frame".into());
    }
    Ok((count, length))
}

async fn read_frame(socket: &mut (impl tokio::io::AsyncRead + Unpin)) -> Result<Message, String> {
    let mut wire = Vec::new();
    let mut payload = Vec::new();
    let mut expected_count = None;
    for fragment in 0..64 {
        let mut header = [0u8; 32];
        socket
            .read_exact(&mut header)
            .await
            .map_err(|e| format!("Read DTX header: {e}"))?;
        let (count, length) = validate_header(&header, fragment, payload.len())?;
        if expected_count.is_some_and(|c| c != count) {
            return Err("DTX fragment count changed".into());
        }
        expected_count = Some(count);
        wire.extend_from_slice(&header);
        // DTX's fragment zero is a header-only announcement for fragmented messages.
        if count > 1 && fragment == 0 {
            continue;
        }
        let mut body = vec![0; length];
        socket
            .read_exact(&mut body)
            .await
            .map_err(|e| format!("Read DTX body: {e}"))?;
        payload.extend_from_slice(&body);
        wire.extend_from_slice(&body);
        if fragment + 1 == count {
            if payload.len() < 16 {
                return Err("Truncated DTX payload header".into());
            }
            let aux = u32_at(&payload, 4) as usize;
            let total = u32_at(&payload, 8) as usize;
            if aux > total || total != payload.len() - 16 {
                return Err("Invalid DTX payload lengths".into());
            }
            return Message::from_reader(&mut wire.as_slice())
                .await
                .map_err(|e| format!("Decode DTX accessibility frame: {e}"));
        }
    }
    Err("Too many DTX fragments".into())
}

fn request(identifier: u32, enabled: bool) -> Result<Vec<u8>, String> {
    let argument = ns_keyed_archive::encode::encode_to_bytes(plist::Value::Boolean(enabled))
        .map_err(|e| e.to_string())?;
    Ok(Message::new(
        MessageHeader::new(0, 1, identifier, 0, 0, true),
        PayloadHeader::method_invocation(),
        Some(Aux::from_values(vec![AuxValue::Array(argument)])),
        Some("clientNeedsAccessibility:".into()),
    )
    .serialize())
}

async fn acknowledge(socket: &mut impl ReadWrite, frame: &Message) -> Result<(), String> {
    let header = frame.message_header.serialize();
    if u32_at(&header, 28) == 0 {
        return Ok(());
    }
    let conversation = u32_at(&header, 20)
        .checked_add(1)
        .ok_or("DTX conversation overflow")?;
    let channel = i32::from_le_bytes(header[24..28].try_into().unwrap());
    let reply_channel = if conversation.is_multiple_of(2) {
        channel
    } else {
        channel.checked_neg().ok_or("Invalid DTX reply channel")?
    };
    let reply = Message::new(
        MessageHeader::new(
            0,
            1,
            u32_at(&header, 16),
            conversation,
            reply_channel,
            false,
        ),
        PayloadHeader::default(),
        None,
        None,
    )
    .serialize();
    socket
        .write_all(&reply)
        .await
        .map_err(|e| format!("Reply to accessibility callback: {e}"))
}

fn snapshot_archive(frame: &Message) -> Option<&[u8]> {
    if frame.data.as_ref().and_then(plist::Value::as_string) != Some(CALLBACK) {
        return None;
    }
    frame
        .aux
        .as_ref()?
        .values
        .iter()
        .find_map(|value| match value {
            AuxValue::Array(bytes)
                if bytes.starts_with(b"bplist00") || bytes.starts_with(b"<?xml") =>
            {
                Some(bytes.as_slice())
            }
            _ => None,
        })
}

pub async fn capture(socket: &mut impl ReadWrite) -> Result<Value, String> {
    socket
        .write_all(&request(1, true)?)
        .await
        .map_err(|e| format!("Enable remote accessibility: {e}"))?;
    let observation = tokio::time::timeout(Duration::from_secs(30), async {
        for _ in 0..256 {
            let frame = read_frame(socket).await?;
            acknowledge(socket, &frame).await?;
            if let Some(bytes) = snapshot_archive(&frame) {
                return Ok(json!({
                    "format": "nskeyedarchive-base64", "archive": base64::engine::general_purpose::STANDARD.encode(bytes),
                    "service": "com.apple.accessibility.axAuditDaemon.remoteAXService",
                    "parsedHierarchy": false, "experimental": true
                }));
            }
        }
        Err("Remote accessibility sent no snapshot within the frame budget".into())
    }).await.map_err(|_| "Remote accessibility snapshot timed out".to_string()).and_then(|v| v);

    // Disable even when acquisition fails. Only a correlated reply confirms cleanup.
    let cleanup = tokio::time::timeout(Duration::from_secs(3), async {
        socket
            .write_all(&request(2, false)?)
            .await
            .map_err(|e| e.to_string())?;
        for _ in 0..32 {
            let frame = read_frame(socket).await?;
            acknowledge(socket, &frame).await?;
            let header = frame.message_header.serialize();
            if u32_at(&header, 16) == 2 && u32_at(&header, 20) == 1 {
                return Ok::<_, String>(());
            }
        }
        Err("No correlated accessibility goodbye reply".into())
    })
    .await
    .map_err(|_| "Accessibility cleanup timed out".to_string())
    .and_then(|v| v);
    let snapshot = observation?;
    cleanup?;
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_bad_and_oversized_headers() {
        let mut header: [u8; 32] = MessageHeader::new(0, 1, 1, 0, 0, false)
            .serialize()
            .try_into()
            .unwrap();
        header[12..16].copy_from_slice(&((MAX_FRAME as u32) + 1).to_le_bytes());
        assert!(validate_header(&header, 0, 0).is_err());
        header[12..16].copy_from_slice(&16u32.to_le_bytes());
        header[0] = 0;
        assert!(validate_header(&header, 0, 0).is_err());
    }

    #[tokio::test]
    async fn accepts_only_snapshot_callback_and_confirms_cleanup() {
        let (mut client, mut server) = tokio::io::duplex(8192);
        let peer = tokio::spawn(async move {
            let enabled = read_frame(&mut server).await.unwrap();
            assert_eq!(
                enabled.data.as_ref().and_then(plist::Value::as_string),
                Some("clientNeedsAccessibility:")
            );
            let unrelated = Message::new(
                MessageHeader::new(0, 1, 98, 0, 0, false),
                PayloadHeader::method_invocation(),
                None,
                Some("unrelated:".into()),
            );
            server.write_all(&unrelated.serialize()).await.unwrap();
            let archive =
                ns_keyed_archive::encode::encode_to_bytes(plist::Value::String("fixture".into()))
                    .unwrap();
            let callback = Message::new(
                MessageHeader::new(0, 1, 99, 0, 0, true),
                PayloadHeader::method_invocation(),
                Some(Aux::from_values(vec![AuxValue::Array(archive)])),
                Some(CALLBACK.into()),
            );
            server.write_all(&callback.serialize()).await.unwrap();
            let ack = read_frame(&mut server).await.unwrap();
            let h = ack.message_header.serialize();
            assert_eq!(u32_at(&h, 16), 99);
            assert_eq!(u32_at(&h, 20), 1);
            let goodbye = read_frame(&mut server).await.unwrap();
            let h = goodbye.message_header.serialize();
            assert_eq!(u32_at(&h, 16), 2);
            acknowledge(&mut server, &goodbye).await.unwrap();
        });
        let result = capture(&mut client).await.unwrap();
        assert_eq!(result["format"], "nskeyedarchive-base64");
        assert_eq!(result["parsedHierarchy"], false);
        peer.await.unwrap();
    }

    #[tokio::test]
    async fn rejects_payload_length_mismatch() {
        let mut bytes = request(1, true).unwrap();
        bytes[40..44].copy_from_slice(&0u32.to_le_bytes());
        assert!(read_frame(&mut bytes.as_slice()).await.is_err());
    }

    #[tokio::test]
    async fn reassembles_fragments_and_rejects_wrong_order() {
        let bytes = request(1, true).unwrap();
        let body = &bytes[32..];
        let mut wire = Vec::new();
        for (index, piece) in [&[][..], &body[..20], &body[20..]].iter().enumerate() {
            let mut header = bytes[..32].to_vec();
            header[8..10].copy_from_slice(&(index as u16).to_le_bytes());
            header[10..12].copy_from_slice(&3u16.to_le_bytes());
            header[12..16].copy_from_slice(
                &(if index == 0 { body.len() } else { piece.len() } as u32).to_le_bytes(),
            );
            wire.extend(header);
            wire.extend_from_slice(piece);
        }
        let decoded = read_frame(&mut wire.as_slice()).await.unwrap();
        assert_eq!(
            decoded.data.as_ref().and_then(plist::Value::as_string),
            Some("clientNeedsAccessibility:")
        );
        wire[40..42].copy_from_slice(&2u16.to_le_bytes());
        assert!(read_frame(&mut wire.as_slice()).await.is_err());
    }
}
