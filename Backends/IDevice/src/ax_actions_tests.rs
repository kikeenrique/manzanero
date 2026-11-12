use super::*;
use crate::ax_tree::tests::{fixture_bytes, record, token};

struct Displays {
    calls: usize,
    failure: &'static str,
}
impl DisplaySource for Displays {
    async fn display(&mut self) -> Result<Value, String> {
        self.calls += 1;
        Ok(
            json!({"displays":[{"primary":true,"displayId":1,"nativeOrientation":"rot0",
            "currentOrientation":if self.failure == "rotated" { "rot90" } else { "rot0" },
            "bounds":[[0,0],[1125,2436]],"pointScale":if self.failure == "display-change" && self.calls == 2 { 2 } else { 3 }}]}),
        )
    }
}
fn snapshot(failure: &str, iteration: usize) -> Value {
    let mut child = record(
        if failure == "target-change" && iteration == 2 {
            3
        } else {
            2
        },
        vec![],
    );
    child["UIAccessibilitySnapshotKeyAttributes"]["2001"] = json!("Navigate");
    if failure == "outside" {
        child["UIAccessibilitySnapshotKeyAttributes"]["2003"]["fields"]["NS.rectval"] =
            json!("{{400,20},{30,40}}");
    }
    let mut children = vec![child.clone()];
    if failure == "duplicate-path" {
        children.push(child.clone());
    }
    if failure == "ambiguous" {
        child["UIAccessibilitySnapshotKeyElement"] = token(3);
        children.push(child);
    }
    let mut root = record(1, children);
    root["UIAccessibilitySnapshotKeyAttributes"]["5019"] = json!("app");
    root["UIAccessibilitySnapshotKeyAttributes"]["2001"] = json!("Application");
    root
}
async fn peer(mut socket: tokio::io::DuplexStream, failure: &'static str) -> usize {
    let mut snapshots = 0;
    let mut hits = 0;
    let mut presses = 0;
    loop {
        let call = accessibility::read_frame(&mut socket).await.unwrap();
        let selector = call.data.as_ref().and_then(Plist::as_string).unwrap();
        if selector == "deviceAPIVersion" {
            let h = call.message_header.serialize();
            let reply = Message::new(
                MessageHeader::new(0, 1, header_u32(&h, 16), 1, 0, false),
                PayloadHeader::default(),
                None,
                Some(26.into()),
            );
            socket.write_all(&reply.serialize()).await.unwrap();
            continue;
        }
        let argument = match &call.aux.as_ref().unwrap().values[0] {
            AuxValue::Array(bytes) => archive::decode_protocol(bytes).unwrap(),
            _ => panic!("Expected archived argument"),
        };
        if selector == "clientNeedsAccessibility:" {
            if argument == false {
                if failure != "cleanup-loss" {
                    accessibility::acknowledge(&mut socket, &call)
                        .await
                        .unwrap();
                }
                return presses;
            }
            assert_eq!(argument, true);
            accessibility::acknowledge(&mut socket, &call)
                .await
                .unwrap();
            continue;
        }
        assert_eq!(selector, "processDataFromHost:");
        let request = fields(&argument, "AXPTranslatorRequest").unwrap();
        let kind = request["requestType"].as_u64().unwrap();
        assert_eq!(request["actionType"], if kind == 7 { 5 } else { 0 });
        let result = match kind {
            1 => token(1),
            2 => {
                snapshots += 1;
                snapshot(failure, snapshots)
            }
            5 => json!({"21":record(2,vec![])["UIAccessibilitySnapshotKeyAttributes"]["2003"],
                "25":"fixture.control","27":failure != "disabled","32":failure != "hidden"}),
            6 => {
                hits += 1;
                assert_eq!(
                    fields(&request["translation"], "AXPTranslationObject").unwrap()["pid"],
                    0
                );
                assert_eq!(request["parameters"]["displayId"], 0);
                let point = fields(&request["parameters"]["point"], "NSValue").unwrap();
                assert_eq!(
                    point["NS.pointval"],
                    if hits == 2 {
                        "{25, 40}"
                    } else {
                        "{187.5, 406}"
                    }
                );
                let mut target = token(if hits == 2 {
                    if failure == "hit-mismatch" { 9 } else { 2 }
                } else {
                    1
                });
                if (failure == "background" && hits == 1) || (failure == "pid-change" && hits == 3)
                {
                    target["fields"]["pid"] = json!(124);
                }
                target
            }
            7 => {
                presses += 1;
                assert_eq!(presses, 1);
                assert_eq!(identity(&request["translation"]).unwrap(), (123, 2));
                if failure == "wire-after-action" {
                    return presses;
                }
                json!(failure != "native-refused")
            }
            _ => panic!("Unexpected request kind {kind}"),
        };
        let mut result = result;
        if kind == 5 && failure == "frame-change" {
            result["21"]["fields"]["NS.rectval"] = json!("{{11,20},{30,40}}");
        }
        if kind == 5 && failure == "outside" {
            result["21"]["fields"]["NS.rectval"] = json!("{{400,20},{30,40}}");
        }
        if kind == 5 && failure == "unknown-visibility" {
            result.as_object_mut().unwrap().remove("32");
        }
        let reply = json!({"className":"AXPTranslatorResponse","fields":{"associatedRequestType":kind,"error":0,"attribute":52,"associatedTranslationObject":token(1),"resultData":result}});
        let outer =
            ns_keyed_archive::encode::encode_to_bytes(Plist::Data(fixture_bytes(&reply))).unwrap();
        let callback = Message::new(
            MessageHeader::new(0, 1, 999, 0, 0, true),
            PayloadHeader::method_invocation(),
            Some(Aux::from_values(vec![AuxValue::Array(outer)])),
            Some("processDataFromRemoteDevice:".into()),
        );
        socket.write_all(&callback.serialize()).await.unwrap();
        accessibility::read_frame(&mut socket).await.unwrap();
        accessibility::acknowledge(&mut socket, &call)
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn fresh_guards_prevent_submission_and_partial_failures_preserve_action_state() {
    for failure in [
        "",
        "duplicate-path",
        "background",
        "ambiguous",
        "disabled",
        "hidden",
        "unknown-visibility",
        "frame-change",
        "hit-mismatch",
        "pid-change",
        "display-change",
        "target-change",
        "outside",
        "rotated",
        "native-refused",
        "wire-after-action",
        "cleanup-loss",
    ] {
        let (mut client, server) = tokio::io::duplex(65536);
        let task = tokio::spawn(peer(server, failure));
        let mut displays = Displays { calls: 0, failure };
        let result = press(
            &mut client,
            &mut displays,
            123,
            "identifier",
            "fixture.control",
        )
        .await;
        let sent = task.await.unwrap();
        if ["", "duplicate-path"].contains(&failure) {
            let result = result.unwrap();
            assert_eq!(sent, 1);
            assert_eq!(result["nativeAccepted"], true);
            assert_eq!(result["effectVerified"], false);
            assert!(!result.to_string().contains("rawElementData"));
        } else {
            let message = result.unwrap_err();
            let state = match failure {
                "native-refused" => "refused",
                "wire-after-action" => "submitted",
                "cleanup-loss" => "accepted",
                _ => "not-sent",
            };
            if state == "not-sent" {
                assert_eq!(sent, 0, "{failure}");
                assert!(message.starts_with("No AX press sent:"), "{message}");
            } else {
                assert_eq!(sent, 1);
                assert!(message.contains(&format!("state={state}")), "{message}");
            }
        }
    }
}

#[test]
fn label_resolution_and_display_scaling_are_exact() {
    let root = token(1);
    let value = snapshot("", 1);
    assert_eq!(
        identity(&resolve(&value, &root, "label", "Navigate").unwrap().0).unwrap(),
        (123, 2)
    );
    assert!(resolve(&value, &root, "label", "navigate").is_err());
    let info = json!({"displays":[{"primary":true,"displayId":1,"nativeOrientation":"rot0","currentOrientation":"rot0","bounds":[[0,0],[1125,2436]],"pointScale":3}]});
    let display = Display::parse(&info).unwrap();
    assert_eq!(display.center(), (187.5, 406.0));
    assert!(
        display
            .target_center(&json!({"x":0,"y":0,"width":0,"height":10}))
            .is_err()
    );
}
