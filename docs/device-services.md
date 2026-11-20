# The services a device offers

Every device publishes a list of the services it offers, its service directory. This page says where to read that list, what is in it, and which entries this tool uses. Read on 2026-11-20 from an iPhone 13 mini (iOS 27.2.1) and an Apple TV 4K (tvOS 27.2); another OS version lists other names.

## Where the list is

The Mac's `remoted` keeps a copy of the directory of each device it is connected to. This prints all of them and contacts no device:

```sh
/usr/libexec/remotectl dumpstate
```

Each `Found coredevice-…` block is one connection to one device, with its state, its properties (the product type, the OS version, the hardware UDID as `UniqueDeviceID`) and then one entry a service. The iPhone listed 87 and the Apple TV 83.

There is a second, shorter list that is not this one: what `devicectl` calls a device's capabilities, such as `com.apple.coredevice.feature.remote.hid.button`. Those are names CoreDevice gives to things it can do for a client, and it carries each out through one or more services of the directory. `manzanero details --device <UDID>` prints them.

## The kinds of name

| Pattern | What it is | Who may connect through `remoted` |
| --- | --- | --- |
| `com.apple.coredevice.…` | Services of Apple's newer device system: apps, files, input, display, screen capture | A client with the entitlement the entry names; CoreDevice's own service has them |
| `….shim.remote` | An older service, of the kind `usbmuxd` and a cable pairing reach, offered again on the newer connection | A client with `com.apple.mobile.lockdown.remote.trusted`, which Apple's MobileDevice framework has |
| `com.apple.internal.…`, `com.apple.dt.…`, and a few others | Tunnels, debugging, test and instruments services | Varies; several name `AppleInternal`, which is granted only on Apple's own macOS |

The device does not check who connects; `remoted` on the Mac does. That is why a tool that reads the directory itself, over a tunnel, can reach a service `remoted` would refuse it ([transport](transport.md#the-cost-of-this-route)).

## The entries this tool uses

| Service | Used for | How it is reached |
| --- | --- | --- |
| `com.apple.accessibility.axAuditDaemon.remoteAXService` | `tree`, `wait`, `press`, `scroll`, `set-value` on a device | The directory, read by the tool on its own tunnel or on Apple's |
| `com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote` | `press` on a physical Apple TV, tried first: the same daemon as Apple's Accessibility Inspector reaches it, by its cursor | `remoted`, through the MobileDevice framework |
| `com.apple.internal.devicecompute.CoreDeviceProxy` | The tool's own tunnel | `usbmuxd`, through the MobileDevice framework |
| The pairing services a device advertises on the network, `_remotepairing._tcp` (port 49152) and, while an Apple TV shows its pairing screen, `_remotepairing-manual-pairing._tcp`. They are not directory entries | `pair`, and the tool's own tunnel to an Apple TV: a listener asked of the first, after a pairing made at the second | A TCP connection to the device's address in Apple's tunnel, found with the Mac's DNS Service Discovery ([transport](transport.md#a-pairing-of-the-tools-own)) |
| `com.apple.os_trace_relay.shim.remote` | An opt-in check of the phone's log relay; no command yet | The directory, on Apple's tunnel |
| `com.apple.coredevice.hid.indigo` | Touch, buttons, keys and the remote | CoreDevice, asked by the capability names `com.apple.coredevice.feature.remote.hid.*`. The tool names the capability, and CoreDevice chooses the service; this is the one the tool's code names |
| `com.apple.coredevice.hid.universalhidservice` | Three to five contacts on a phone, and the Apple TV remote's swipes, for which a touch-pad service is created for the call | CoreDevice, asked by the capability name `com.apple.coredevice.feature.remote.universalhidservice` |
| The screen capture and display services (`com.apple.coredevice.screencaptureservice` was seen fetched for Apple's Device Hub) | `screenshot`, `record` (the picture, and with `--audio` the device's system audio as a second stream), `frames` | CoreDevice, asked by its media and display capabilities. Which directory entry carries each is CoreDevice's business and was not traced |
| The app, file, diagnostics and device information services | Apps, files, reports, details, `console` | Apple's `devicectl`, which the tool runs. Not traced to entries either |

## The whole list

The iPhone's 87 entries. The Apple TV's are the same less four: `com.apple.carkit.remote-iap.service`, `com.apple.coredevice.pasteboardservice`, `com.apple.fusion.remote.service` and `com.apple.internal.ptdremoted`.

```text
com.apple.accessibility.axAuditDaemon.remoteAXService
com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote
com.apple.afc.shim.remote
com.apple.amfi.lockdown.shim.remote
com.apple.atc.shim.remote
com.apple.atc2.shim.remote
com.apple.backgroundassets.lockdownservice.shim.remote
com.apple.bluetooth.BTPacketLogger.shim.remote
com.apple.carkit.remote-iap.service
com.apple.carkit.service.shim.remote
com.apple.commcenter.mobile-helper-cbupdateservice.shim.remote
com.apple.companion_proxy.shim.remote
com.apple.corecaptured.remoteservice
com.apple.coredevice.appservice
com.apple.coredevice.configuration
com.apple.coredevice.debugserverproxy
com.apple.coredevice.devicecontrol
com.apple.coredevice.deviceinfo
com.apple.coredevice.diagnosticsservice
com.apple.coredevice.displayservice
com.apple.coredevice.fileservice.control
com.apple.coredevice.fileservice.data
com.apple.coredevice.hid.indigo
com.apple.coredevice.hid.universalhid
com.apple.coredevice.hid.universalhidservice
com.apple.coredevice.iconservice
com.apple.coredevice.locationservice
com.apple.coredevice.openstdiosocket
com.apple.coredevice.pasteboardservice
com.apple.coredevice.screencaptureservice
com.apple.crashreportcopymobile.shim.remote
com.apple.crashreportmover.shim.remote
com.apple.dt.remoteFetchSymbols
com.apple.dt.remotepairingdeviced.lockdown.shim.remote
com.apple.dt.testmanagerd.remote
com.apple.dt.testmanagerd.remote.automation
com.apple.fusion.remote.service
com.apple.GPUTools.MobileService.shim.remote
com.apple.gputools.remote.agent
com.apple.idamd.shim.remote
com.apple.instruments.dtservicehub
com.apple.internal.devicecompute.CoreDeviceProxy
com.apple.internal.devicecompute.CoreDeviceProxy.shim.remote
com.apple.internal.dt.coredevice.untrusted.tunnelservice
com.apple.internal.dt.remote.debugproxy
com.apple.internal.ptdremoted
com.apple.iosdiagnostics.relay.shim.remote
com.apple.misagent.shim.remote
com.apple.mobile.assertion_agent.shim.remote
com.apple.mobile.diagnostics_relay.shim.remote
com.apple.mobile.file_relay.shim.remote
com.apple.mobile.heartbeat.shim.remote
com.apple.mobile.house_arrest.shim.remote
com.apple.mobile.insecure_notification_proxy.remote
com.apple.mobile.insecure_notification_proxy.shim.remote
com.apple.mobile.installation_proxy.shim.remote
com.apple.mobile.lockdown.remote.trusted
com.apple.mobile.lockdown.remote.untrusted
com.apple.mobile.MCInstall.shim.remote
com.apple.mobile.mobile_image_mounter.shim.remote
com.apple.mobile.notification_proxy.remote
com.apple.mobile.notification_proxy.shim.remote
com.apple.mobile.storage_mounter_proxy.bridge
com.apple.mobileactivationd.shim.remote
com.apple.mobilebackup2.shim.remote
com.apple.mobilesync.shim.remote
com.apple.modelmanager.remote
com.apple.os_trace_relay.shim.remote
com.apple.osanalytics.logRelay
com.apple.osanalytics.logTransfer
com.apple.osanalytics.logTransfer
com.apple.pcapd.shim.remote
com.apple.preboardservice_v2.shim.remote
com.apple.preboardservice.shim.remote
com.apple.private.siriappintentsd.orchestrator
com.apple.PurpleReverseProxy.Conn.shim.remote
com.apple.PurpleReverseProxy.Ctrl.shim.remote
com.apple.remote.installcoordination_proxy
com.apple.RestoreRemoteServices.restoreserviced
com.apple.security.cryptexd.remote
com.apple.springboardservices.shim.remote
com.apple.streaming_zip_conduit.shim.remote
com.apple.sysdiagnose.remote
com.apple.sysdiagnose.remote.trusted
com.apple.syslog_relay.shim.remote
com.apple.timed.remote
com.apple.webinspector.shim.remote
```
