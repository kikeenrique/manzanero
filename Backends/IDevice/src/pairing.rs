use crate::transport::{WifiRecord, validate_endpoint};
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use serde_json::{Value, json};
use std::{
    fs::{File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};
use tokio::net::TcpStream;

struct PrivateRecord {
    path: PathBuf,
    file: File,
    committed: bool,
}

impl PrivateRecord {
    fn reserve(path: &Path) -> Result<Self, String> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(path).map_err(|e| {
            format!("Create private pairing record (destination must not exist): {e}")
        })?;
        Ok(Self {
            path: path.to_owned(),
            file,
            committed: false,
        })
    }

    fn commit(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.file
            .write_all(bytes)
            .and_then(|_| self.file.sync_all())
            .map_err(|e| format!("Save private pairing record: {e}"))?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for PrivateRecord {
    fn drop(&mut self) {
        if !self.committed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

pub async fn pair(host: &str, port: u16, destination: &Path) -> Result<Value, String> {
    validate_endpoint(host, port)?;
    let mut file = PrivateRecord::reserve(destination)?;
    let result = async {
        let socket = TcpStream::connect((host, port)).await.map_err(|e| format!("Wi-Fi pairing endpoint: {e}"))?;
        let mut client = RemotePairingClient::new(RpPairingSocket::new(socket), "appledevicescmd");
        let mut pairing = RpPairingFile::generate(&format!("appledevicescmd-{}", uuid::Uuid::new_v4()));
        client.connect(&mut pairing, || async {
            eprint!("Enter the PIN displayed by the device, then press Return: ");
            let _ = std::io::stderr().flush();
            tokio::task::spawn_blocking(|| {
                let mut pin = String::new();
                if std::io::stdin().read_line(&mut pin).is_err() { return String::new(); }
                let pin = pin.trim();
                if pin.len() == 6 && pin.bytes().all(|c| c.is_ascii_digit()) { pin.to_string() } else { String::new() }
            }).await.unwrap_or_default()
        }).await.map_err(|_| "Wi-Fi pairing failed; check the device's approval and six-digit PIN".to_string())?;
        let peer = client.paired_peer_device().map_err(|_| "Pairing did not return a device identity")?;
        let record = WifiRecord { udid: peer.remotepairing_udid.clone(), host: host.into(), port, pairing };
        file.commit(&record.encode()?)?;
        Ok(json!({"status": "paired", "udid": record.udid, "pairingFile": destination, "transport": "wifi"}))
    }.await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn path() -> PathBuf {
        let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tmp/pairing-tests");
        std::fs::create_dir_all(&directory).unwrap();
        directory.join(format!("{}.pairing.plist", uuid::Uuid::new_v4()))
    }
    #[test]
    fn failed_or_cancelled_pairing_removes_reserved_record() {
        let path = path();
        {
            let _reserved = PrivateRecord::reserve(&path).unwrap();
            assert!(path.exists());
        }
        assert!(!path.exists());
    }
    #[test]
    fn successful_record_is_private_and_never_overwritten() {
        let path = path();
        {
            let mut file = PrivateRecord::reserve(&path).unwrap();
            file.commit(b"test-private-record").unwrap();
        }
        assert!(PrivateRecord::reserve(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"test-private-record");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        std::fs::remove_file(path).unwrap();
    }
}
