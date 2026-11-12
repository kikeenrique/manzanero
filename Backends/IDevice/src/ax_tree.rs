//! Active AXP reads over the advertised remoteAXService, using MIT ipb wire research.
//! No XCTest, archived Objective-C class instantiation, or cached public handles.
use crate::{accessibility, archive};
use base64::Engine;
use idevice::{
    ReadWrite,
    dvt::message::{Aux, AuxValue, Message, MessageHeader, PayloadHeader},
};
use plist::{Dictionary, Uid, Value as Plist};
use serde_json::{Value, json};
use std::{collections::VecDeque, time::Duration};
use tokio::io::AsyncWriteExt;

fn fields<'a>(value: &'a Value, class: &str) -> Result<&'a Value, String> {
    if value["className"] != class {
        return Err(format!("Expected AX class {class}"));
    }
    value.get("fields").ok_or("Missing AX fields".into())
}

fn identity(value: &Value) -> Result<(u32, u64), String> {
    let value = fields(value, "AXPTranslationObject")?;
    let pid = value["pid"]
        .as_u64()
        .filter(|p| *p > 0 && *p <= i32::MAX as u64)
        .ok_or("Invalid AX PID")?;
    Ok((
        pid as u32,
        value["objectID"].as_u64().ok_or("Invalid AX object ID")?,
    ))
}

struct Encoder {
    objects: Vec<Plist>,
}
impl Encoder {
    fn new() -> Self {
        Self {
            objects: vec!["$null".into()],
        }
    }
    fn add(&mut self, value: Plist) -> Plist {
        self.objects.push(value);
        Plist::Uid(Uid::new((self.objects.len() - 1) as u64))
    }
    fn object(&mut self, class: &str, mut values: Dictionary) -> Plist {
        let cls = self.add(Plist::Dictionary(
            [
                ("$classname".to_string(), class.into()),
                (
                    "$classes".to_string(),
                    Plist::Array(vec![class.into(), "NSObject".into()]),
                ),
            ]
            .into_iter()
            .collect(),
        ));
        values.insert("$class".into(), cls);
        self.add(Plist::Dictionary(values))
    }
    fn encode(&mut self, value: &Value) -> Result<Plist, String> {
        Ok(match value {
            Value::Null => Plist::Uid(Uid::new(0)),
            Value::Bool(v) => self.add(Plist::Boolean(*v)),
            Value::String(v) => self.add(v.as_str().into()),
            Value::Number(n) => self.add(if let Some(n) = n.as_u64() {
                Plist::Integer(n.into())
            } else if let Some(n) = n.as_i64() {
                Plist::Integer(n.into())
            } else {
                return Err("Unsupported AX request number".into());
            }),
            Value::Array(values) => {
                let values = values
                    .iter()
                    .map(|v| self.encode(v))
                    .collect::<Result<Vec<_>, _>>()?;
                self.object(
                    "NSArray",
                    [("NS.objects".to_string(), Plist::Array(values))]
                        .into_iter()
                        .collect(),
                )
            }
            Value::Object(values) if values.contains_key("$data") => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(values["$data"].as_str().ok_or("Invalid AX data")?)
                    .map_err(|e| e.to_string())?;
                self.object(
                    "NSData",
                    [("NS.data".to_string(), Plist::Data(bytes))]
                        .into_iter()
                        .collect(),
                )
            }
            Value::Object(values) => {
                let mut keys = Vec::new();
                let mut entries = Vec::new();
                for (key, value) in values {
                    keys.push(self.encode(&json!(key))?);
                    entries.push(self.encode(value)?);
                }
                self.object(
                    "NSDictionary",
                    [
                        ("NS.keys".to_string(), Plist::Array(keys)),
                        ("NS.objects".to_string(), Plist::Array(entries)),
                    ]
                    .into_iter()
                    .collect(),
                )
            }
        })
    }
    fn token(&mut self, token: &Value) -> Result<Plist, String> {
        identity(token)?;
        let source = fields(token, "AXPTranslationObject")?;
        let mut result = Dictionary::new();
        for key in ["rawElementData", "bridgeDelegateToken", "objectID"] {
            result.insert(
                key.into(),
                self.encode(source.get(key).unwrap_or(&Value::Null))?,
            );
        }
        result.insert(
            "pid".into(),
            Plist::Integer(source["pid"].as_u64().ok_or("Missing PID")?.into()),
        );
        for key in ["isApplicationElement", "didPopuldateAppInfo"] {
            result.insert(
                key.into(),
                Plist::Boolean(source[key].as_bool().unwrap_or(false)),
            );
        }
        Ok(self.object("AXPTranslationObject", result))
    }
}

fn request(kind: u64, parameters: Value, token: Option<&Value>) -> Result<Vec<u8>, String> {
    if ![1, 2].contains(&kind) || (kind == 2 && token.is_none()) {
        return Err("Unsupported AX tree request".into());
    }
    let mut encoder = Encoder::new();
    let params = encoder.encode(&parameters)?;
    let translation = token
        .map(|t| encoder.token(t))
        .transpose()?
        .unwrap_or(Plist::Uid(Uid::new(0)));
    let values = [
        ("requestType".to_string(), Plist::Integer(kind.into())),
        ("clientType".to_string(), 0.into()),
        ("actionType".to_string(), 0.into()),
        (
            "attributeType".to_string(),
            if kind == 2 { 52.into() } else { 0.into() },
        ),
        ("translation".to_string(), translation),
        ("parameters".to_string(), params),
    ]
    .into_iter()
    .collect();
    let root = encoder.object("AXPTranslatorRequest", values);
    let archive = Plist::Dictionary(
        [
            ("$archiver".to_string(), "NSKeyedArchiver".into()),
            ("$version".to_string(), 100000.into()),
            ("$objects".to_string(), Plist::Array(encoder.objects)),
            (
                "$top".to_string(),
                Plist::Dictionary([("root".to_string(), root)].into_iter().collect()),
            ),
        ]
        .into_iter()
        .collect(),
    );
    let mut bytes = Vec::new();
    archive
        .to_writer_binary(&mut bytes)
        .map_err(|e| e.to_string())?;
    Ok(bytes)
}

struct Session<'a, S> {
    socket: &'a mut S,
    next: u32,
    callbacks: VecDeque<Value>,
    bytes: usize,
}
fn header_u32(header: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(header[offset..offset + 4].try_into().unwrap())
}
impl<'a, S: ReadWrite> Session<'a, S> {
    async fn receive(&mut self) -> Result<Message, String> {
        let frame = accessibility::read_frame(self.socket).await?;
        let header = frame.message_header.serialize();
        if frame.data.as_ref().and_then(Plist::as_string) == Some("hostAPIVersion")
            && header_u32(&header, 28) != 0
        {
            let conversation = header_u32(&header, 20)
                .checked_add(1)
                .ok_or("AX DTX conversation overflow")?;
            let channel = header_u32(&header, 24) as i32;
            let channel = if conversation.is_multiple_of(2) {
                channel
            } else {
                channel.checked_neg().ok_or("Invalid AX DTX channel")?
            };
            let response = Message::new(
                MessageHeader::new(0, 1, header_u32(&header, 16), conversation, channel, false),
                PayloadHeader::default(),
                None,
                Some(7.into()),
            )
            .serialize();
            self.socket
                .write_all(&response)
                .await
                .map_err(|e| e.to_string())?;
        } else {
            accessibility::acknowledge(self.socket, &frame).await?;
        }
        if let Some(bytes) = accessibility::snapshot_archive(&frame) {
            self.bytes = self.bytes.saturating_add(bytes.len());
            if self.bytes > 40 * 1024 * 1024 || self.callbacks.len() >= 8 {
                return Err("AX callback budget exceeded".into());
            }
            self.callbacks.push_back(archive::decode_protocol(bytes)?);
        }
        Ok(frame)
    }
    async fn invoke(
        &mut self,
        selector: &str,
        argument: Option<Plist>,
    ) -> Result<Option<Plist>, String> {
        let id = self.next;
        self.next += 1;
        let aux = argument
            .map(|v| {
                ns_keyed_archive::encode::encode_to_bytes(v)
                    .map(|b| Aux::from_values(vec![AuxValue::Array(b)]))
            })
            .transpose()
            .map_err(|e| e.to_string())?;
        let message = Message::new(
            MessageHeader::new(0, 1, id, 0, 0, true),
            PayloadHeader::method_invocation(),
            aux,
            Some(selector.into()),
        )
        .serialize();
        self.socket
            .write_all(&message)
            .await
            .map_err(|e| e.to_string())?;
        tokio::time::timeout(Duration::from_secs(4), async {
            for _ in 0..256 {
                let frame = self.receive().await?;
                let header = frame.message_header.serialize();
                if header_u32(&header, 16) == id
                    && header_u32(&header, 20) == 1
                    && header_u32(&header, 24) == 0
                {
                    // The pinned DTX encoder emits 0 for empty replies and 3
                    // for object replies. Refuse other/error payload kinds.
                    if ![0, 3].contains(&frame.payload_header.serialize()[0]) {
                        return Err("Unsupported or error AX DTX reply payload".into());
                    }
                    return Ok(frame.data);
                }
            }
            Err("AX DTX reply budget exceeded".into())
        })
        .await
        .map_err(|_| format!("AX {selector} reply timed out"))?
    }
    async fn read(
        &mut self,
        kind: u64,
        parameters: Value,
        token: Option<&Value>,
    ) -> Result<Value, String> {
        // Only one semantic request is outstanding. Discard older notifications
        // before sending; a timeout ends this session rather than reusing it.
        self.callbacks.clear();
        let bytes = request(kind, parameters, token)?;
        self.invoke("processDataFromHost:", Some(Plist::Data(bytes)))
            .await?;
        tokio::time::timeout(Duration::from_secs(4), async {
            for _ in 0..256 {
                if let Some(value) = self.callbacks.pop_front() {
                    let reply = fields(&value, "AXPTranslatorResponse")?;
                    if reply["associatedRequestType"].as_u64() != Some(kind) {
                        continue;
                    }
                    if reply["error"].as_i64() != Some(0) {
                        return Err("AX semantic request refused or missing status".into());
                    }
                    if kind == 2
                        && (reply["attribute"] != 52
                            || identity(&reply["associatedTranslationObject"])?
                                != identity(token.unwrap())?)
                    {
                        return Err("AX snapshot response target/attribute mismatch".into());
                    }
                    return reply
                        .get("resultData")
                        .cloned()
                        .filter(|v| !v.is_null())
                        .ok_or("AX request returned no data".into());
                }
                self.receive().await?;
            }
            Err("AX semantic response budget exceeded".into())
        })
        .await
        .map_err(|_| "AX semantic request timed out; connection will close".to_string())?
    }
}

fn rectangle(value: &Value) -> Result<Value, String> {
    let fields = fields(value, "NSValue")?;
    let raw = fields["NS.rectval"]
        .as_str()
        .ok_or("Missing native AX rectangle")?;
    let values = raw
        .replace(['{', '}', ','], " ")
        .split_whitespace()
        .map(|v| {
            v.parse::<f64>()
                .map_err(|_| "Invalid native AX rectangle".to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if values == [f64::INFINITY, f64::INFINITY, 0.0, 0.0] {
        return Ok(json!({"unavailable":"CGRectNull"}));
    }
    if values.len() != 4
        || values.iter().any(|v| !v.is_finite())
        || values[2] < 0.0
        || values[3] < 0.0
    {
        return Err("Invalid native AX rectangle".into());
    }
    Ok(json!({"x":values[0],"y":values[1],"width":values[2],"height":values[3]}))
}

fn normalize(snapshot: &Value, root: &Value) -> Result<Vec<Value>, String> {
    let root_id = identity(root)?;
    if identity(&snapshot["UIAccessibilitySnapshotKeyElement"])? != root_id {
        return Err("AX snapshot root mismatch".into());
    }
    let mut nodes: Vec<Value> = Vec::new();
    let mut pending = VecDeque::from([(snapshot, None::<usize>, 0)]);
    while let Some((record, parent, depth)) = pending.pop_front() {
        if nodes.len() >= 512 || depth > 32 {
            return Err("AX snapshot node/depth limit; no partial tree emitted".into());
        }
        let token = identity(&record["UIAccessibilitySnapshotKeyElement"])?;
        let children = record["UIAccessibilitySnapshotKeyChildren"]
            .as_array()
            .ok_or("Missing AX snapshot children")?;
        if record["UIAccessibilitySnapshotKeyChildrenCount"].as_u64() != Some(children.len() as u64)
        {
            return Err("AX snapshot children count mismatch".into());
        }
        let attrs = record["UIAccessibilitySnapshotKeyAttributes"]
            .as_object()
            .ok_or("Missing native AX attributes")?;
        if token.0 != root_id.0
            && (attrs.get("5003") != Some(&json!("AXRemoteElement")) || !children.is_empty())
        {
            return Err("Unsupported foreign-process AX subtree".into());
        }
        let index = nodes.len();
        let id = format!("n{index}");
        let mut node = json!({"id":id,"parentId":parent.map(|p|format!("n{p}")),"depth":depth,"children":[],"attributeSource":"native-snapshot"});
        for (key, name) in [
            ("2001", "label"),
            ("2002", "hint"),
            ("5019", "identifier"),
            ("2006", "value"),
        ] {
            if let Some(value) = attrs.get(key).filter(|v| !v.is_null()) {
                if value.is_object() || value.is_array() {
                    return Err(format!("Unsupported native AX {name} value"));
                }
                node[name] = value.clone();
            }
        }
        if let Some(value) = attrs.get("2003").filter(|v| !v.is_null()) {
            let frame = rectangle(value)?;
            if frame.get("unavailable").is_some() {
                node["frameUnavailable"] = json!("CGRectNull");
            } else {
                node["frame"] = frame;
            }
        }
        if let Some(traits) = attrs.get("2004").filter(|v| !v.is_null()) {
            let bits = traits
                .as_u64()
                .or_else(|| traits.as_i64().map(|n| n as u64))
                .ok_or("Invalid native AX traits")?;
            node["traits"] = json!(bits.to_string());
        }
        if let Some(visible) = attrs.get("2025").filter(|v| !v.is_null()) {
            node["visible"] = match visible {
                Value::Bool(value) => json!(value),
                Value::Number(value) if value.as_u64().is_some_and(|v| v <= 1) => {
                    json!(value.as_u64() == Some(1))
                }
                _ => return Err("Invalid native AX visibility".into()),
            };
        }
        let mut metadata = serde_json::Map::new();
        for key in ["5003", "5004", "3003"] {
            if let Some(value) = attrs.get(key).filter(|v| !v.is_null()) {
                if !value.is_string() {
                    return Err("Invalid native AX class/bundle metadata".into());
                }
                metadata.insert(key.into(), value.clone());
            }
        }
        if !metadata.is_empty() {
            node["nativeAttributes"] = Value::Object(metadata);
        }
        if token.0 != root_id.0 {
            node["processIdentifier"] = json!(token.0);
            node["externalProcessReference"] = json!(true);
        }
        if let Some(parent) = parent {
            nodes[parent]["children"]
                .as_array_mut()
                .unwrap()
                .push(json!(id));
        }
        nodes.push(node);
        pending.extend(children.iter().map(|child| (child, Some(index), depth + 1)));
    }
    Ok(nodes)
}

pub async fn capture(socket: &mut impl ReadWrite, pid: u32) -> Result<Value, String> {
    let mut session = Session {
        socket,
        next: 1,
        callbacks: VecDeque::new(),
        bytes: 0,
    };
    let mut subscribed = false;
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        let version = session.invoke("deviceAPIVersion", None).await?;
        if version.as_ref().and_then(Plist::as_unsigned_integer) != Some(26) { return Err("Unsupported remote AX API version".into()); }
        subscribed = true;
        session.invoke("clientNeedsAccessibility:", Some(true.into())).await?;
        let root = session.read(1, json!({"pid":pid}), None).await?;
        if identity(&root)?.0 != pid || fields(&root,"AXPTranslationObject")?["isApplicationElement"] != true { return Err("AX application identity mismatch".into()); }
        let snapshot = session.read(2, json!({"parameter":{"attributes":[2001,2002,2003,2004,5019,2006,2025,5003,5004,3003],
            "maxDepth":48,"maxChildren":512,"maxArrayCount":512,"traverseFromParentsToChildren":true,"snapshotKeyHonorModalViews":false}}), Some(&root)).await?;
        let nodes = normalize(&snapshot, &root)?;
        let after = session.read(1, json!({"pid":pid}), None).await?;
        if identity(&after)? != identity(&root)? || fields(&after,"AXPTranslationObject")?["isApplicationElement"] != true { return Err("AX application identity changed during observation".into()); }
        Ok(json!({"format":"accessibility-tree","schemaVersion":1,"parsedHierarchy":true,"experimental":true,
            "application":{"pid":pid,"selection":"explicit-pid"},"deviceAPIVersion":26,"snapshotId":uuid::Uuid::new_v4().to_string(),
            "nodeCount":nodes.len(),"nodes":nodes,"atomic":false,"rootStabilityScope":"application-identity",
            "referenceScope":"snapshot-local-paths","coordinateSpace":"device-logical-points",
            "limitations":["Explicit PID can identify a background app; foreground selection is not checked.",
            "Accessibility snapshot is not every UIView, nor a combined system/app snapshot. IDs are not reusable action handles.",
            "Device snapshot child/depth caps and offscreen coverage are not independently complete-coverage guarantees."]}))
    }).await.map_err(|_| "AX tree observation timed out".to_string()).and_then(|r| r);
    let cleanup = if subscribed {
        tokio::time::timeout(
            Duration::from_secs(3),
            session.invoke("clientNeedsAccessibility:", Some(false.into())),
        )
        .await
        .map_err(|_| "AX tree subscription cleanup timed out".to_string())
        .and_then(|r| r)
        .map(|_| ())
    } else {
        Ok(())
    };
    match (result, cleanup) {
        (Ok(mut value), Ok(())) => {
            value["cleanup"] = json!({"subscriptionStop":"confirmed"});
            Ok(value)
        }
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(cleanup)) => Err(format!("{error}; {cleanup}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(id: u64) -> Value {
        json!({"className":"AXPTranslationObject","fields":{"pid":123,"objectID":id,
            "rawElementData":{"$data":"AQIDBA=="},"bridgeDelegateToken":null,
            "isApplicationElement":id == 1,"didPopuldateAppInfo":false}})
    }
    fn record(id: u64, children: Vec<Value>) -> Value {
        json!({"UIAccessibilitySnapshotKeyElement":token(id),
            "UIAccessibilitySnapshotKeyChildrenCount":children.len(),"UIAccessibilitySnapshotKeyChildren":children,
            "UIAccessibilitySnapshotKeyAttributes":{"2001":"Fixture label","5019":"fixture.control","2004":1,"2025":true,
                "2003":{"className":"NSValue","fields":{"NS.rectval":"{{10, 20}, {30, 40}}"}},"5003":"FixtureView"}})
    }
    // Build synthetic archives independently of real device content. Typed
    // objects retain their class wrappers; numeric request/response fields may
    // be primitive or referenced, as the keyed-archive decoder supports both.
    fn fixture_value(encoder: &mut Encoder, value: &Value) -> Plist {
        if value["className"] == "AXPTranslationObject" {
            return encoder.token(value).unwrap();
        }
        if let Some(class) = value["className"].as_str() {
            let values = value["fields"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), fixture_value(encoder, v)))
                .collect();
            return encoder.object(class, values);
        }
        match value {
            Value::Array(values) => {
                let items = values.iter().map(|v| fixture_value(encoder, v)).collect();
                encoder.object(
                    "NSArray",
                    [("NS.objects".to_string(), Plist::Array(items))]
                        .into_iter()
                        .collect(),
                )
            }
            Value::Object(values) if !values.contains_key("$data") => {
                let mut keys = Vec::new();
                let mut items = Vec::new();
                for (key, value) in values {
                    keys.push(encoder.encode(&json!(key)).unwrap());
                    items.push(fixture_value(encoder, value));
                }
                encoder.object(
                    "NSDictionary",
                    [
                        ("NS.keys".to_string(), Plist::Array(keys)),
                        ("NS.objects".to_string(), Plist::Array(items)),
                    ]
                    .into_iter()
                    .collect(),
                )
            }
            _ => encoder.encode(value).unwrap(),
        }
    }
    fn fixture_bytes(value: &Value) -> Vec<u8> {
        let mut encoder = Encoder::new();
        let root = fixture_value(&mut encoder, value);
        let document = Plist::Dictionary(
            [
                ("$archiver".to_string(), "NSKeyedArchiver".into()),
                ("$objects".to_string(), Plist::Array(encoder.objects)),
                (
                    "$top".to_string(),
                    Plist::Dictionary([("root".to_string(), root)].into_iter().collect()),
                ),
            ]
            .into_iter()
            .collect(),
        );
        let mut bytes = Vec::new();
        document.to_writer_binary(&mut bytes).unwrap();
        bytes
    }

    #[test]
    fn request_roundtrip_preserves_opaque_token_and_read_only_contract() {
        let app = token(u64::MAX);
        let bytes = request(
            2,
            json!({"parameter":{"attributes":[2001,2003],"maxDepth":48}}),
            Some(&app),
        )
        .unwrap();
        let value = archive::decode_protocol(&bytes).unwrap();
        let fields = fields(&value, "AXPTranslatorRequest").unwrap();
        assert_eq!(fields["requestType"], 2);
        assert_eq!(fields["attributeType"], 52);
        assert_eq!(fields["actionType"], 0);
        assert_eq!(fields["translation"], app);
        assert_eq!(
            fields["parameters"]["parameter"]["attributes"],
            json!([2001, 2003])
        );
        assert!(request(7, Value::Null, Some(&app)).is_err());
        assert!(request(2, Value::Null, None).is_err());
        // Public structural decoding continues to hide opaque bytes.
        assert!(
            !archive::decode(&bytes)
                .unwrap()
                .to_string()
                .contains("AQIDBA==")
        );
    }

    #[test]
    fn preserves_path_occurrences_and_rejects_incomplete_or_invalid_graphs() {
        let root = token(1);
        let snapshot = record(1, vec![record(2, vec![]), record(2, vec![])]);
        let nodes = normalize(&snapshot, &root).unwrap();
        assert_eq!(nodes.len(), 3);
        assert_eq!(nodes[0]["children"], json!(["n1", "n2"]));
        assert_eq!(nodes[1]["label"], "Fixture label");
        assert_eq!(nodes[1]["visible"], true);
        assert_eq!(
            nodes[1]["frame"],
            json!({"x":10.0,"y":20.0,"width":30.0,"height":40.0})
        );
        assert!(!json!(nodes).to_string().contains("objectID"));
        let mut bad = snapshot.clone();
        bad["UIAccessibilitySnapshotKeyChildrenCount"] = json!(3);
        assert!(normalize(&bad, &root).is_err());
        assert!(normalize(&snapshot, &token(8)).is_err());
        let mut bad = record(1, vec![]);
        bad["UIAccessibilitySnapshotKeyAttributes"]["2025"] = json!(2);
        assert!(normalize(&bad, &root).is_err());
        let too_many = record(1, (0..512).map(|_| record(2, vec![])).collect());
        assert!(normalize(&too_many, &root).is_err());
        let mut deep = record(2, vec![]);
        for _ in 0..33 {
            deep = record(2, vec![deep]);
        }
        // Protocol decoding needs a separate wrapper-depth budget from the
        // public structural inspector; native view depth is checked below.
        let bytes = fixture_bytes(&deep);
        assert!(archive::decode_protocol(&bytes).is_ok());
        assert!(archive::decode(&bytes).is_err());
        assert!(normalize(&record(1, vec![deep]), &root).is_err());
        let null = json!({"className":"NSValue","fields":{"NS.rectval":"{{inf, inf}, {0, 0}}"}});
        assert_eq!(
            rectangle(&null).unwrap(),
            json!({"unavailable":"CGRectNull"})
        );
        for raw in ["{{0,0},{-1,2}}", "{{NaN,0},{1,2}}", "{{0,0},{1}}"] {
            assert!(
                rectangle(&json!({"className":"NSValue","fields":{"NS.rectval":raw}})).is_err()
            );
        }
    }

    async fn peer(mut socket: tokio::io::DuplexStream, failure: &str) {
        let mut reads = 0;
        loop {
            let call = accessibility::read_frame(&mut socket).await.unwrap();
            let header = call.message_header.serialize();
            let id = header_u32(&header, 16);
            let selector = call.data.as_ref().and_then(Plist::as_string).unwrap();
            let mut return_value = None;
            match selector {
                "deviceAPIVersion" => {
                    let host = Message::new(
                        MessageHeader::new(0, 1, 99, 0, 0, true),
                        PayloadHeader::method_invocation(),
                        None,
                        Some("hostAPIVersion".into()),
                    );
                    socket.write_all(&host.serialize()).await.unwrap();
                    let reply = accessibility::read_frame(&mut socket).await.unwrap();
                    assert_eq!(
                        reply.data.as_ref().and_then(Plist::as_unsigned_integer),
                        Some(7)
                    );
                    return_value = Some(26.into());
                }
                "clientNeedsAccessibility:" => {
                    let aux = &call.aux.as_ref().unwrap().values[0];
                    let enabled = match aux {
                        AuxValue::Array(bytes) => archive::decode_protocol(bytes).unwrap(),
                        _ => panic!("Boolean argument"),
                    };
                    if enabled == false {
                        assert!(reads >= 2);
                        if failure == "cleanup" {
                            return;
                        }
                        accessibility::acknowledge(&mut socket, &call)
                            .await
                            .unwrap();
                        return;
                    }
                    assert_eq!(enabled, true);
                }
                "processDataFromHost:" => {
                    reads += 1;
                    let request = match &call.aux.as_ref().unwrap().values[0] {
                        AuxValue::Array(bytes) => archive::decode_protocol(bytes).unwrap(),
                        _ => panic!("Data argument"),
                    };
                    let params = fields(&request, "AXPTranslatorRequest").unwrap();
                    let kind = params["requestType"].as_u64().unwrap();
                    assert_eq!(params["actionType"], 0);
                    let result = if kind == 1 {
                        token(if failure == "changed-root" && reads == 3 {
                            2
                        } else {
                            1
                        })
                    } else {
                        record(1, vec![record(2, vec![])])
                    };
                    let mut reply = json!({"className":"AXPTranslatorResponse","fields":{
                        "associatedRequestType":kind,"error":0,"attribute":if failure == "wrong-attribute" { 51 } else { 52 },
                        "associatedTranslationObject":token(1),"resultData":result}});
                    if kind == 2 && failure == "missing-status" {
                        reply["fields"].as_object_mut().unwrap().remove("error");
                    }
                    let outer = ns_keyed_archive::encode::encode_to_bytes(Plist::Data(
                        fixture_bytes(&reply),
                    ))
                    .unwrap();
                    let callback = Message::new(
                        MessageHeader::new(0, 1, 100 + reads, 0, 0, true),
                        PayloadHeader::method_invocation(),
                        Some(Aux::from_values(vec![AuxValue::Array(outer)])),
                        Some("processDataFromRemoteDevice:".into()),
                    );
                    // Semantic callback deliberately precedes the DTX call reply.
                    socket.write_all(&callback.serialize()).await.unwrap();
                    accessibility::read_frame(&mut socket).await.unwrap();
                }
                _ => panic!("Unexpected selector {selector}"),
            }
            let reply = Message::new(
                MessageHeader::new(0, 1, id, 1, 0, false),
                PayloadHeader::default(),
                None,
                return_value,
            );
            let mut bytes = reply.serialize();
            if selector == "processDataFromHost:" && reads == 2 && failure == "bad-dtx" {
                bytes[32] = 255; // Unsupported reply kind must not confirm success.
            }
            socket.write_all(&bytes).await.unwrap();
        }
    }

    #[tokio::test]
    async fn correlates_native_reads_and_requires_cleanup_and_stable_application() {
        for failure in [
            "",
            "wrong-attribute",
            "changed-root",
            "cleanup",
            "missing-status",
            "bad-dtx",
        ] {
            let (mut client, server) = tokio::io::duplex(65536);
            let task = tokio::spawn(peer(server, failure));
            let result = capture(&mut client, 123).await;
            if failure.is_empty() {
                let result = result.unwrap();
                assert_eq!(result["nodeCount"], 2);
                assert_eq!(result["cleanup"]["subscriptionStop"], "confirmed");
                assert_eq!(result["atomic"], false);
                assert!(!result.to_string().contains("rawElementData"));
            } else {
                assert!(result.is_err(), "{failure}");
            }
            task.await.unwrap();
        }
    }
}
