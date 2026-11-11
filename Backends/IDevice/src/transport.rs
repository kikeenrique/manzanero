use idevice::{
    IdeviceService,
    core_device_proxy::CoreDeviceProxy,
    remote_pairing::{
        RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
    usbmuxd::UsbmuxdAddr,
};
use std::path::Path;
use tokio::net::TcpStream;

pub struct Connection {
    pub adapter: AdapterHandle,
    pub rsd: RsdHandshake,
    pub name: &'static str,
    // The pairing control connection owns the Wi-Fi listener's lifetime.
    _pairing: Option<RemotePairingClient<RpPairingSocket<TcpStream>>>,
}

pub struct WifiRecord {
    pub udid: String,
    pub host: String,
    pub port: u16,
    pub pairing: RpPairingFile,
}

impl WifiRecord {
    pub fn decode(bytes: &[u8], expected_udid: &str) -> Result<Self, String> {
        let value: plist::Value =
            plist::from_bytes(bytes).map_err(|_| "Invalid Wi-Fi pairing record")?;
        let dict = value
            .as_dictionary()
            .ok_or("Invalid Wi-Fi pairing record")?;
        let string = |key| {
            dict.get(key)
                .and_then(plist::Value::as_string)
                .map(str::to_owned)
                .ok_or_else(|| format!("Missing {key} in Wi-Fi pairing record"))
        };
        let udid = string("DeviceUDID")?;
        if udid != expected_udid {
            return Err("Pairing record belongs to a different UDID".into());
        }
        let host = string("EndpointHost")?;
        let port = dict
            .get("EndpointPort")
            .and_then(plist::Value::as_unsigned_integer)
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p != 0)
            .ok_or("Invalid endpoint port")?;
        validate_endpoint(&host, port)?;
        let pairing =
            RpPairingFile::from_bytes(bytes).map_err(|_| "Invalid pairing key material")?;
        Ok(Self {
            udid,
            host,
            port,
            pairing,
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let value: plist::Value = plist::from_bytes(&self.pairing.to_bytes())
            .map_err(|_| "Invalid pairing key material")?;
        let mut dict = value
            .into_dictionary()
            .ok_or("Invalid pairing key material")?;
        dict.insert("DeviceUDID".into(), self.udid.clone().into());
        dict.insert("EndpointHost".into(), self.host.clone().into());
        dict.insert("EndpointPort".into(), u64::from(self.port).into());
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &dict).map_err(|_| "Failed to encode pairing record")?;
        Ok(bytes)
    }
}

pub fn validate_endpoint(host: &str, port: u16) -> Result<(), String> {
    if host.is_empty()
        || host.starts_with('-')
        || host.chars().any(char::is_whitespace)
        || port == 0
    {
        return Err(
            "Wi-Fi endpoint requires a hostname or IP address and a port from 1 to 65535".into(),
        );
    }
    Ok(())
}

pub async fn connect(udid: &str, record_path: Option<&Path>) -> Result<Connection, String> {
    let (mut adapter, port, name, pairing) = if let Some(path) = record_path {
        let bytes = tokio::fs::read(path)
            .await
            .map_err(|e| format!("Read pairing record: {e}"))?;
        let mut record = WifiRecord::decode(&bytes, udid)?;
        let socket = TcpStream::connect((record.host.as_str(), record.port))
            .await
            .map_err(|e| format!("Wi-Fi endpoint: {e}"))?;
        let mut client = RemotePairingClient::new(RpPairingSocket::new(socket), "appledevicescmd");
        // Verification only: device operations never initiate trust pairing.
        client
            .attempt_pair_verify()
            .await
            .map_err(|e| format!("Pair verification handshake: {e}"))?;
        client
            .validate_pairing(&mut record.pairing)
            .await
            .map_err(|_| "Wi-Fi pair verification failed; explicitly pair again".to_string())?;
        let port = client
            .create_tcp_listener()
            .await
            .map_err(|e| format!("Create Wi-Fi tunnel listener: {e}"))?;
        let socket = TcpStream::connect((record.host.as_str(), port))
            .await
            .map_err(|e| format!("Wi-Fi tunnel: {e}"))?;
        let tunnel = connect_tls_psk_tunnel_native(socket, client.encryption_key())
            .await
            .map_err(|e| format!("Wi-Fi tunnel handshake: {e}"))?;
        let client_ip = tunnel
            .info
            .client_address
            .parse()
            .map_err(|_| "Invalid tunnel client address")?;
        let server_ip = tunnel
            .info
            .server_address
            .parse()
            .map_err(|_| "Invalid tunnel server address")?;
        let rsd_port = tunnel.info.server_rsd_port;
        (
            Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip).to_async_handle(),
            rsd_port,
            "wifi",
            Some(client),
        )
    } else {
        let addr = UsbmuxdAddr::from_env_var().map_err(|e| e.to_string())?;
        let mut mux = addr.connect(0).await.map_err(|e| format!("usbmuxd: {e}"))?;
        let device = mux.get_device(udid).await.map_err(|e| format!("Device not available through usbmuxd: {e}; use --pairing-file for a separately paired Wi-Fi connection"))?;
        let provider = device.to_provider(addr, "appledevicescmd");
        let proxy = CoreDeviceProxy::connect(&provider)
            .await
            .map_err(|e| format!("CoreDevice proxy: {e}"))?;
        let port = proxy.tunnel_info().server_rsd_port;
        (
            proxy
                .create_software_tunnel()
                .map_err(|e| e.to_string())?
                .to_async_handle(),
            port,
            "usbmuxd",
            None,
        )
    };
    let socket = adapter
        .connect(port)
        .await
        .map_err(|e| format!("Tunnel RSD connect: {e}"))?;
    let rsd = RsdHandshake::new(socket)
        .await
        .map_err(|e| format!("RSD: {e}"))?;
    if let Some(reported) = rsd
        .properties
        .get("UniqueDeviceID")
        .and_then(plist::Value::as_string)
    {
        if reported != udid {
            return Err("RSD device identity does not match requested UDID".into());
        }
    }
    Ok(Connection {
        adapter,
        rsd,
        name,
        _pairing: pairing,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trip_record_and_reject_wrong_device() {
        let record = WifiRecord {
            udid: "test-udid".into(),
            host: "phone.local".into(),
            port: 12345,
            pairing: RpPairingFile::generate("test"),
        };
        let bytes = record.encode().unwrap();
        let decoded = WifiRecord::decode(&bytes, "test-udid").unwrap();
        assert_eq!(decoded.host, "phone.local");
        assert_eq!(
            decoded.pairing.private_key_bytes(),
            record.pairing.private_key_bytes()
        );
        assert!(WifiRecord::decode(&bytes, "another-device").is_err());
    }
    #[test]
    fn malformed_record_and_endpoint_rejected() {
        assert!(WifiRecord::decode(b"bad", "test").is_err());
        for host in ["", "--help", "phone\nlocal"] {
            assert!(validate_endpoint(host, 1).is_err());
        }
        assert!(validate_endpoint("phone.local", 0).is_err());
    }
}
