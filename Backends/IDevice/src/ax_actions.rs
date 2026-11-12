//! One fresh AX press with no coordinate fallback or automatic replay.
use super::*;
use idevice::core_device::CoreDeviceServiceClient;
use std::collections::BTreeMap;

pub(crate) trait DisplaySource {
    async fn display(&mut self) -> Result<Value, String>;
}
impl<S: ReadWrite> DisplaySource for CoreDeviceServiceClient<S> {
    async fn display(&mut self) -> Result<Value, String> {
        let value = self
            .invoke("com.apple.coredevice.feature.getdisplayinfo", None)
            .await
            .map_err(|e| format!("AX display query: {e}"))?;
        serde_json::to_value(value).map_err(|e| e.to_string())
    }
}

#[derive(Debug, PartialEq)]
pub(super) struct Display {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    id: Value,
    scale: f64,
}
impl Display {
    pub(super) fn parse(info: &Value) -> Result<Self, String> {
        let primary = info["displays"]
            .as_array()
            .ok_or("Missing display metadata")?
            .iter()
            .filter(|v| v["primary"] == true)
            .collect::<Vec<_>>();
        if primary.len() != 1 {
            return Err("Ambiguous primary display".into());
        }
        let value = primary[0];
        if value["currentOrientation"] != "rot0" || value["nativeOrientation"] != "rot0" {
            return Err("AX press does not yet support rotated displays".into());
        }
        let scale = value["pointScale"]
            .as_f64()
            .filter(|n| n.is_finite() && *n > 0.0)
            .ok_or("Invalid display scale")?;
        let bounds = value["bounds"]
            .as_array()
            .filter(|v| v.len() == 2)
            .ok_or("Invalid display bounds")?;
        let mut coordinates = Vec::new();
        for pair in bounds {
            for n in pair
                .as_array()
                .filter(|v| v.len() == 2)
                .ok_or("Invalid display bounds")?
            {
                coordinates.push(
                    n.as_f64()
                        .filter(|n| n.is_finite())
                        .ok_or("Invalid display coordinate")?
                        / scale,
                );
            }
        }
        if coordinates[2] <= 0.0 || coordinates[3] <= 0.0 {
            return Err("Invalid display size".into());
        }
        if !value["displayId"].is_number() {
            return Err("Missing display identity".into());
        }
        Ok(Self {
            x: coordinates[0],
            y: coordinates[1],
            width: coordinates[2],
            height: coordinates[3],
            id: value["displayId"].clone(),
            scale,
        })
    }
    pub(super) fn center(&self) -> (f64, f64) {
        (self.x + self.width / 2.0, self.y + self.height / 2.0)
    }
    pub(super) fn metadata(&self) -> Value {
        json!({"bounds":{"x":self.x,"y":self.y,"width":self.width,"height":self.height},
            "displayId":self.id,"pointScale":self.scale,"orientation":"rot0"})
    }
    fn target_center(&self, frame: &Value) -> Result<(f64, f64), String> {
        let number = |key| {
            frame[key]
                .as_f64()
                .filter(|n| n.is_finite())
                .ok_or("Missing target geometry")
        };
        let (x, y, w, h) = (
            number("x")?,
            number("y")?,
            number("width")?,
            number("height")?,
        );
        if w <= 0.0
            || h <= 0.0
            || x < self.x
            || y < self.y
            || x + w > self.x + self.width
            || y + h > self.y + self.height
        {
            return Err("AX target frame is not wholly within the primary display".into());
        }
        Ok((x + w / 2.0, y + h / 2.0))
    }
}

fn resolve(
    snapshot: &Value,
    root: &Value,
    selector: &str,
    text: &str,
) -> Result<(Value, Value), String> {
    let nodes = normalize(snapshot, root)?;
    let attribute = match selector {
        "identifier" => "5019",
        "label" => "2001",
        _ => return Err("Unsupported AX selector".into()),
    };
    let mut matches = BTreeMap::new();
    let mut records = VecDeque::from([snapshot]);
    let mut index = 0;
    while let Some(record) = records.pop_front() {
        let attrs = &record["UIAccessibilitySnapshotKeyAttributes"];
        if attrs[attribute].as_str() == Some(text) {
            let token = &record["UIAccessibilitySnapshotKeyElement"];
            let key = identity(token)?;
            if let Some((_, old_attrs, _)) = matches.get(&key) {
                if old_attrs != attrs {
                    return Err("AX match has inconsistent native path occurrences".into());
                }
            }
            matches.insert(key, (token.clone(), attrs.clone(), nodes[index].clone()));
        }
        index += 1;
        records.extend(
            record["UIAccessibilitySnapshotKeyChildren"]
                .as_array()
                .unwrap(),
        );
    }
    if matches.len() != 1 {
        return Err(format!(
            "AX selector matches {}; exactly one distinct element is required",
            matches.len()
        ));
    }
    let (token, _, node) = matches.into_values().next().unwrap();
    if identity(&token)?.0 != identity(root)?.0 {
        return Err("AX target belongs to another process".into());
    }
    Ok((token, node))
}

fn known_true(value: &Value) -> bool {
    value == &json!(true) || value.as_u64() == Some(1)
}

pub(crate) async fn press(
    socket: &mut impl ReadWrite,
    displays: &mut impl DisplaySource,
    requested_pid: Option<u32>,
    selector: &str,
    text: &str,
) -> Result<Value, String> {
    if !["identifier", "label"].contains(&selector)
        || text.is_empty()
        || text.len() > 4096
        || text.contains('\0')
    {
        return Err("Invalid AX press selector".into());
    }
    let mut session = Session {
        socket,
        next: 1,
        callbacks: VecDeque::new(),
        bytes: 0,
        expected_kind: None,
        connection_closed: false,
    };
    let mut subscribed = false;
    let mut state = "not-sent";
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        if session.invoke("deviceAPIVersion",None).await?.as_ref().and_then(Plist::as_unsigned_integer) != Some(26) { return Err("Unsupported AX device API version".into()); }
        subscribed = true;
        session.invoke("clientNeedsAccessibility:",Some(true.into())).await?;
        let display = Display::parse(&displays.display().await?)?;
        let (cx,cy) = display.center();
        let selected = session.exchange(6,point_request(cx,cy)?,None).await?;
        let selected_pid = identity(&selected)?.0;
        if requested_pid.is_some_and(|pid| pid != selected_pid) { return Err(format!("Requested AX PID {} differs from display-centre hit PID {selected_pid}",requested_pid.unwrap())); }
        let pid = selected_pid;
        let root = session.read(1,json!({"pid":pid}),None).await?;
        if identity(&root)?.0 != pid || fields(&root,"AXPTranslationObject")?["isApplicationElement"] != true { return Err("AX application identity mismatch".into()); }
        let snapshot = session.read(2,snapshot_options(),Some(&root)).await?;
        let (first, _) = resolve(&snapshot,&root,selector,text)?;
        let confirmed = session.read(2,snapshot_options(),Some(&root)).await?;
        let (target, node) = resolve(&confirmed,&root,selector,text)?;
        if identity(&first)? != identity(&target)? { return Err("AX selector target changed between snapshots".into()); }
        let live = session.read(5,json!({"attributes":[21,25,27,32]}),Some(&target)).await?;
        if !known_true(&live["27"]) || !known_true(&live["32"]) { return Err("AX target is not known enabled and visible".into()); }
        if let Some(identifier) = node.get("identifier") {
            if &live["25"] != identifier { return Err("AX identifier changed before press".into()); }
        }
        if rectangle(&live["21"])? != node["frame"] { return Err("AX target geometry changed before press".into()); }
        let (x,y) = display.target_center(&node["frame"])?;
        let hit = session.exchange(6,point_request(x,y)?,None).await?;
        if identity(&hit)? != identity(&target)? { return Err("AX frame-centre hit is not the selected element".into()); }
        let after = session.read(1,json!({"pid":pid}),None).await?;
        if identity(&after)? != identity(&root)? || fields(&after,"AXPTranslationObject")?["isApplicationElement"] != true { return Err("AX application identity changed before press".into()); }
        let displayed = session.exchange(6,point_request(cx,cy)?,None).await?;
        if identity(&displayed)?.0 != pid { return Err("Displayed AX process changed before press".into()); }
        if Display::parse(&displays.display().await?)? != display { return Err("Display geometry/orientation changed before press".into()); }
        let request = press_request(&target)?;
        state = "submitted";
        let accepted = session.exchange(7,request,Some(&target)).await?;
        if !known_true(&accepted) {
            if accepted == false || accepted.as_u64() == Some(0) { state = "refused"; }
            return Err("AX press refused or returned an unknown native result".into());
        }
        state = "accepted";
        let mut public_target = serde_json::Map::new();
        for key in ["label","identifier","frame","nativeAttributes"] { if let Some(value) = node.get(key) { public_target.insert(key.into(),value.clone()); } }
        Ok(json!({"operation":"press","status":"accepted","nativeAccepted":true,"verified":false,"effectVerified":false,
            "application":{"pid":pid,"selection":if requested_pid.is_some() { "explicit-pid+centre-hit-test" } else { "centre-hit-test" }},"selector":{"by":selector,"text":text},
            "target":public_target,"coordinateSpace":"device-logical-points","atomic":false}))
    }).await.map_err(|_| "AX press operation timed out".to_string()).and_then(|r|r);
    session.expected_kind = None;
    let cleanup = if subscribed {
        session.stop_subscription().await
    } else {
        Ok(json!({"subscriptionStop":"not-subscribed"}))
    };
    match (result, cleanup) {
        (Ok(mut value), Ok(cleanup)) => {
            value["cleanup"] = cleanup;
            Ok(value)
        }
        (result, cleanup) => {
            let errors = [result.err(), cleanup.err()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join("; ");
            Err(if state == "not-sent" {
                format!("No AX press sent: {errors}")
            } else {
                format!(
                    "AX press state={state}; UI effect unverified. Inspect device before retrying; no automatic retry. {errors}"
                )
            })
        }
    }
}

#[cfg(test)]
#[path = "ax_actions_tests.rs"]
mod tests;
