//! Bounded, data-only inspection of keyed archives. Never instantiates archived classes.
use plist::Value as Plist;
use serde_json::{Value, json};
use std::{
    io::{Cursor, Read},
    path::Path,
};

const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_VALUES: usize = 100_000;
const MAX_DEPTH: usize = 64;

#[derive(Default)]
struct Decoder {
    values: usize,
    archives: usize,
    expanded_bytes: usize,
}

impl Decoder {
    fn charge(&mut self, count: usize) -> Result<(), String> {
        self.expanded_bytes = self.expanded_bytes.saturating_add(count);
        if self.expanded_bytes > MAX_BYTES * 2 {
            return Err("Archive expanded byte limit exceeded".into());
        }
        Ok(())
    }
    fn archive(&mut self, bytes: &[u8], depth: usize) -> Result<Value, String> {
        if bytes.len() > MAX_BYTES || depth > MAX_DEPTH || self.archives >= 4 {
            return Err("Accessibility archive byte, depth, or nesting limit exceeded".into());
        }
        self.archives += 1;
        let parsed = Plist::from_reader(Cursor::new(bytes))
            .map_err(|e| format!("Read keyed archive: {e}"))?;
        let archive = parsed
            .as_dictionary()
            .ok_or("Keyed archive must be a dictionary")?;
        if archive.get("$archiver").and_then(Plist::as_string) != Some("NSKeyedArchiver") {
            return Err("Not an NSKeyedArchiver archive".into());
        }
        let objects = archive
            .get("$objects")
            .and_then(Plist::as_array)
            .ok_or("Missing archive object table")?;
        if objects.len() > MAX_VALUES {
            return Err("Archive object count exceeded".into());
        }
        let root = archive
            .get("$top")
            .and_then(Plist::as_dictionary)
            .and_then(|v| v.get("root"))
            .ok_or("Missing archive root")?;
        if !matches!(root, Plist::Uid(_)) {
            return Err("Archive root must be an object reference".into());
        }
        self.value(root, objects, &mut Vec::new(), depth + 1)
    }

    fn value(
        &mut self,
        value: &Plist,
        objects: &[Plist],
        stack: &mut Vec<usize>,
        depth: usize,
    ) -> Result<Value, String> {
        self.values += 1;
        if self.values > MAX_VALUES || depth > MAX_DEPTH {
            return Err("Archive expansion or depth limit exceeded".into());
        }
        match value {
            Plist::Uid(uid) => {
                let id = usize::try_from(uid.get()).map_err(|_| "Archive reference overflow")?;
                let value = objects.get(id).ok_or("Archive reference is out of range")?;
                if id == 0 && value.as_string() == Some("$null") {
                    return Ok(Value::Null);
                }
                if stack.contains(&id) {
                    return Err("Cyclic archive reference is unsupported".into());
                }
                stack.push(id);
                let result = self.value(value, objects, stack, depth + 1);
                stack.pop();
                result
            }
            Plist::String(s) => {
                self.charge(s.len())?;
                Ok(json!(s))
            }
            Plist::Boolean(b) => Ok(json!(b)),
            Plist::Integer(i) => i
                .as_signed()
                .map(|v| json!(v))
                .or_else(|| i.as_unsigned().map(|v| json!(v)))
                .ok_or("Unsupported archive integer".into()),
            Plist::Real(n) if n.is_finite() => Ok(json!(n)),
            Plist::Real(_) => Err("Non-finite archive number".into()),
            Plist::Date(date) => Ok(json!({"$date": date.to_xml_format()})),
            Plist::Data(bytes) => {
                if bytes.starts_with(b"bplist00") || bytes.starts_with(b"<?xml") {
                    Ok(
                        json!({"byteCount": bytes.len(), "nestedArchive": self.archive(bytes, depth + 1)?}),
                    )
                } else {
                    Ok(json!({"dataBytes": bytes.len()}))
                }
            }
            Plist::Array(items) => items
                .iter()
                .map(|v| self.value(v, objects, stack, depth + 1))
                .collect::<Result<Vec<_>, _>>()
                .map(Value::Array),
            Plist::Dictionary(dict) => {
                let class = if let Some(reference) = dict.get("$class") {
                    let id = reference
                        .as_uid()
                        .ok_or("Invalid archive class reference")?
                        .get();
                    objects
                        .get(usize::try_from(id).map_err(|_| "Class reference overflow")?)
                        .and_then(Plist::as_dictionary)
                        .and_then(|d| d.get("$classname"))
                        .and_then(Plist::as_string)
                        .ok_or("Invalid archive class description")?
                } else {
                    ""
                };
                match class {
                    "NSData" | "NSMutableData" | "__NSCFData" => self.value(
                        dict.get("NS.data").ok_or("Missing NSData bytes")?,
                        objects,
                        stack,
                        depth + 1,
                    ),
                    "NSString" | "NSMutableString" | "__NSCFString" => self.value(
                        dict.get("NS.string").ok_or("Missing NSString content")?,
                        objects,
                        stack,
                        depth + 1,
                    ),
                    "NSArray" | "NSMutableArray" | "__NSArrayI" | "__NSArrayM" | "NSSet"
                    | "NSMutableSet" => self.value(
                        dict.get("NS.objects").ok_or("Missing collection objects")?,
                        objects,
                        stack,
                        depth + 1,
                    ),
                    "NSDictionary"
                    | "NSMutableDictionary"
                    | "__NSDictionaryI"
                    | "__NSDictionaryM" => {
                        let keys = dict
                            .get("NS.keys")
                            .and_then(Plist::as_array)
                            .ok_or("Missing dictionary keys")?;
                        let values = dict
                            .get("NS.objects")
                            .and_then(Plist::as_array)
                            .ok_or("Missing dictionary values")?;
                        if keys.len() != values.len() {
                            return Err("Archive dictionary key/value count mismatch".into());
                        }
                        let mut result = serde_json::Map::new();
                        for (k, v) in keys.iter().zip(values) {
                            let key = match self.value(k, objects, stack, depth + 1)? {
                                Value::String(s) => s,
                                Value::Number(n) => n.to_string(),
                                _ => return Err("Unsupported archive dictionary key".into()),
                            };
                            let value = self.value(v, objects, stack, depth + 1)?;
                            self.charge(key.len())?;
                            if result.insert(key, value).is_some() {
                                return Err("Duplicate decoded dictionary key".into());
                            }
                        }
                        Ok(Value::Object(result))
                    }
                    _ => {
                        let mut fields = serde_json::Map::new();
                        for (k, v) in dict.iter().filter(|(k, _)| k.as_str() != "$class") {
                            self.charge(k.len())?;
                            fields.insert(k.clone(), self.value(v, objects, stack, depth + 1)?);
                        }
                        self.charge(class.len())?;
                        Ok(json!({"className": class, "fields": fields}))
                    }
                }
            }
            _ => Err("Unsupported property-list value".into()),
        }
    }
}

pub fn decode(bytes: &[u8]) -> Result<Value, String> {
    let mut decoder = Decoder::default();
    let decoded = decoder.archive(bytes, 0)?;
    Ok(
        json!({"format":"decoded-nskeyedarchive", "experimental":true, "parsedHierarchy":false,
        "decoded": decoded, "statistics":{"archives":decoder.archives,"expandedValues":decoder.values},
        "limitations":["Structural decoding only; numeric accessibility attribute meanings and hierarchy semantics are not established.",
            "Opaque data is represented by byte counts. No selector-targetable tree or stable element references are produced."]}),
    )
}

pub fn decode_file(path: &Path) -> Result<Value, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("Open accessibility archive: {e}"))?;
    let mut bytes = Vec::new();
    file.take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("Read accessibility archive: {e}"))?;
    decode(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::{Dictionary, Uid};
    fn dictionary<const N: usize>(fields: [(String, Plist); N]) -> Dictionary {
        fields.into_iter().collect()
    }
    fn archive(objects: Vec<Plist>) -> Vec<u8> {
        let value = Plist::Dictionary(dictionary([
            ("$archiver".into(), "NSKeyedArchiver".into()),
            ("$objects".into(), Plist::Array(objects)),
            (
                "$top".into(),
                Plist::Dictionary(dictionary([("root".into(), Plist::Uid(Uid::new(1)))])),
            ),
        ]));
        let mut bytes = vec![];
        value.to_writer_binary(&mut bytes).unwrap();
        bytes
    }
    #[test]
    fn decodes_collections_nested_archive_and_unknown_classes_without_instantiation() {
        let inner = archive(vec![
            "$null".into(),
            Plist::Dictionary(dictionary([
                ("$class".into(), Plist::Uid(Uid::new(2))),
                ("attribute".into(), 21.into()),
                ("resultData".into(), "fixture".into()),
            ])),
            Plist::Dictionary(dictionary([(
                "$classname".into(),
                "AXPTranslatorResponse".into(),
            )])),
        ]);
        let outer = ns_keyed_archive::encode::encode_to_bytes(Plist::Data(inner)).unwrap();
        let result = decode(&outer).unwrap();
        assert_eq!(result["statistics"]["archives"], 2);
        assert_eq!(
            result["decoded"]["nestedArchive"]["className"],
            "AXPTranslatorResponse"
        );
        assert_eq!(
            result["decoded"]["nestedArchive"]["fields"]["attribute"],
            21
        );
        assert_eq!(result["parsedHierarchy"], false);
        let values = Plist::Dictionary(dictionary([(
            "treeDump".into(),
            Plist::Array(vec![
                true.into(),
                "label".into(),
                Plist::Data(vec![1, 2, 3]),
            ]),
        )]));
        let bytes = ns_keyed_archive::encode::encode_to_bytes(values).unwrap();
        let result = decode(&bytes).unwrap();
        assert_eq!(result["decoded"]["treeDump"][0], true);
        assert_eq!(result["decoded"]["treeDump"][2]["dataBytes"], 3);
    }
    #[test]
    fn rejects_cycles_dangling_references_and_oversized_input() {
        for objects in [
            vec!["$null".into(), Plist::Uid(Uid::new(1))],
            vec!["$null".into(), Plist::Uid(Uid::new(99))],
        ] {
            assert!(decode(&archive(objects)).is_err());
        }
        assert!(
            decode(&vec![0; MAX_BYTES + 1])
                .unwrap_err()
                .contains("limit")
        );
        assert!(decode(b"not a plist").is_err());
        let mut objects = vec!["$null".into()];
        objects.extend((2..100).map(|i| Plist::Uid(Uid::new(i))));
        objects.push("end".into());
        assert!(decode(&archive(objects)).unwrap_err().contains("depth"));
    }
    #[test]
    fn bounds_shared_reference_expansion_and_rejects_mismatched_dictionary() {
        let mut objects = vec!["$null".into()];
        for i in 2..20 {
            objects.push(Plist::Array(vec![Plist::Uid(Uid::new(i)); 2]));
        }
        objects.push("end".into());
        assert!(decode(&archive(objects)).unwrap_err().contains("expansion"));
        let bad = Plist::Dictionary(dictionary([
            ("$class".into(), Plist::Uid(Uid::new(2))),
            ("NS.keys".into(), Plist::Array(vec!["key".into()])),
            ("NS.objects".into(), Plist::Array(vec![])),
        ]));
        let class = Plist::Dictionary(dictionary([("$classname".into(), "NSDictionary".into())]));
        assert!(
            decode(&archive(vec!["$null".into(), bad, class]))
                .unwrap_err()
                .contains("mismatch")
        );
        let large = archive(vec![
            "$null".into(),
            Plist::Array(vec![Plist::Uid(Uid::new(2)); 40]),
            "x".repeat(1024 * 1024).into(),
        ]);
        assert!(decode(&large).unwrap_err().contains("byte limit"));
    }
}
