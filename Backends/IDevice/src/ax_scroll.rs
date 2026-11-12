//! One native scroll-to-visible request followed by a fresh, read-only observation.
use super::*;

fn known_bool(value: &Value) -> Option<bool> {
    if known_true(value) {
        Some(true)
    } else if value == &json!(false) || value.as_u64() == Some(0) {
        Some(false)
    } else {
        None
    }
}

fn public_state(node: &Value, live: &Value) -> Result<Value, String> {
    let mut state = serde_json::Map::new();
    for key in ["label", "identifier", "nativeAttributes"] {
        if let Some(value) = node.get(key) {
            state.insert(key.into(), value.clone());
        }
    }
    state.insert("frame".into(), rectangle(&live["21"])?);
    state.insert(
        "enabled".into(),
        known_bool(&live["27"])
            .ok_or("AX enabled state unavailable")?
            .into(),
    );
    state.insert(
        "visible".into(),
        known_bool(&live["32"])
            .ok_or("AX visibility unavailable")?
            .into(),
    );
    Ok(state.into())
}

async fn validate_selection<S: ReadWrite>(
    session: &mut Session<'_, S>,
    displays: &mut impl DisplaySource,
    root: &Value,
    display: &Display,
) -> Result<(), String> {
    let pid = identity(root)?.0;
    let after = session.read(1, json!({"pid":pid}), None).await?;
    if identity(&after)? != identity(root)?
        || fields(&after, "AXPTranslationObject")?["isApplicationElement"] != true
    {
        return Err("AX application identity changed".into());
    }
    let (x, y) = display.center();
    if identity(&session.exchange(6, point_request(x, y)?, None).await?)?.0 != pid {
        return Err("Displayed AX process changed".into());
    }
    if Display::parse(&displays.display().await?)? != *display {
        return Err("Display geometry/orientation changed".into());
    }
    Ok(())
}

async fn observe<S: ReadWrite>(
    session: &mut Session<'_, S>,
    displays: &mut impl DisplaySource,
    root: &Value,
    display: &Display,
    target: &Value,
    selector: &str,
    text: &str,
) -> Result<Value, String> {
    let snapshot = session.read(2, snapshot_options(), Some(root)).await?;
    let (after_target, node) = resolve(&snapshot, root, selector, text)?;
    if identity(&after_target)? != identity(target)? {
        return Err("Target identity changed after scroll".into());
    }
    let live = session
        .read(5, json!({"attributes":[21,25,27,32]}), Some(&after_target))
        .await?;
    if node.get("identifier").is_some_and(|id| id != &live["25"]) {
        return Err("Target identifier changed after scroll".into());
    }
    let after = public_state(&node, &live)?;
    if after["enabled"] != true || after["visible"] != true || node["visible"] != true {
        return Err("Target is not known enabled and visible after scroll".into());
    }
    if after["frame"] != node["frame"] {
        return Err("Target frame changed during post-scroll observation".into());
    }
    let (x, y) = display.target_center(&after["frame"])?;
    if identity(&session.exchange(6, point_request(x, y)?, None).await?)? != identity(target)? {
        return Err("Target centre hit differs after scroll".into());
    }
    validate_selection(session, displays, root, display).await?;
    Ok(after)
}

pub(crate) async fn scroll_to_visible(
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
        return Err("Invalid AX scroll selector".into());
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
    let result = tokio::time::timeout(Duration::from_secs(30),async {
        if session.invoke("deviceAPIVersion",None).await?.as_ref().and_then(Plist::as_unsigned_integer) != Some(26) {
            return Err("Unsupported AX device API version".into());
        }
        subscribed = true;
        session.invoke("clientNeedsAccessibility:",Some(true.into())).await?;
        let display = Display::parse(&displays.display().await?)?;
        let (x,y) = display.center();
        let pid = identity(&session.exchange(6,point_request(x,y)?,None).await?)?.0;
        if requested_pid.is_some_and(|p|p!=pid) { return Err("Requested AX PID differs from display-centre process".into()); }
        let root = session.read(1,json!({"pid":pid}),None).await?;
        if identity(&root)?.0 != pid || fields(&root,"AXPTranslationObject")?["isApplicationElement"] != true {
            return Err("AX application identity mismatch".into());
        }
        let first = session.read(2,snapshot_options(),Some(&root)).await?;
        let (first_target,_) = resolve(&first,&root,selector,text)?;
        let confirmed = session.read(2,snapshot_options(),Some(&root)).await?;
        let (target,node) = resolve(&confirmed,&root,selector,text)?;
        if identity(&first_target)? != identity(&target)? { return Err("AX selector target changed between snapshots".into()); }
        let live = session.read(5,json!({"attributes":[21,25,27,32]}),Some(&target)).await?;
        let before = public_state(&node,&live)?;
        if before["enabled"] != true { return Err("AX scroll target is not known enabled".into()); }
        if node.get("identifier").is_some_and(|id| id != &live["25"]) { return Err("AX identifier changed before scroll".into()); }
        if before["frame"] != node["frame"] || before["frame"]["width"].as_f64().unwrap_or(0.0)<=0.0 || before["frame"]["height"].as_f64().unwrap_or(0.0)<=0.0 {
            return Err("AX scroll target frame is unavailable or changed".into());
        }
        if before["visible"] != node["visible"] { return Err("AX target visibility is unavailable or changed".into()); }
        validate_selection(&mut session,displays,&root,&display).await?;
        let request = action_request(&target,11)?;
        state = "submitted";
        let native = session.exchange(7,request,Some(&target)).await?;
        let native = known_bool(&native).ok_or("AX scroll returned an unknown native result")?;
        state = if native { "native-true" } else { "native-false" };
        let observation = observe(&mut session,displays,&root,&display,&target,selector,text).await;
        let verified = observation.is_ok();
        let mut value = json!({"operation":"scroll-to-visible","nativeResult":native,
            "status":if verified { "postcondition-verified" } else { "postcondition-failed" },
            "postconditionVerified":verified,"verified":false,"atomic":false,
            "application":{"pid":pid,"selection":if requested_pid.is_some() { "explicit-pid+centre-hit-test" } else { "centre-hit-test" }},
            "selector":{"by":selector,"text":text},"before":before,"coordinateSpace":"device-logical-points"});
        match observation {
            Ok(after) => value["after"] = after,
            Err(error) => value["postconditionFailure"] = error.into(),
        }
        Ok(value)
    }).await.map_err(|_|"AX scroll operation timed out".to_string()).and_then(|r|r);
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
                format!("No AX scroll sent: {errors}")
            } else {
                format!(
                    "AX scroll state={state}; inspect device before retrying; no automatic retry. {errors}"
                )
            })
        }
    }
}
