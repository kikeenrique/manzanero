#ifndef APPLE_DEVICE_BRIDGE_H
#define APPLE_DEVICE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

/// Reads Foundation's property-list UID scalar without unarchiving a class.
/// Returns 1 for a UID, 0 for another plist value, -1 if Apple symbols are absent.
int ADCReadArchiveUID(const void *object, uint64_t *value);

/// Checks a live socket-inventory PID against Apple's exact remoted path.
int ADCIsRemotedProcess(int pid);

/// Bounded domain/code and whitelisted standard explanations from a borrowed
/// XPC error dictionary. Does not dump arbitrary userInfo or instantiate errors.
void ADCDescribeCoreDeviceError(const void *errorDictionary, char *output, size_t capacity);

/// Closes the AX service socket opened to the RSD-advertised port.
void ADCCloseAccessibilitySocket(int descriptor);

/// Validates a borrowed RemoteXPC RSD Handshake and returns only the exact AX
/// service port. No class decoding or service connection. Returns zero on success.
int ADCValidateRSDHandshake(const void *message, const char *expectedUDID, uint16_t *axPort,
                           char *error, size_t errorCapacity);
/// Network-based control bootstrap. Copies a sockaddr_in6; no FD is
/// transferred. Owns/cancels the Network and RemoteXPC connections. Uses
/// Apple's failsafe version flags for the bootstrap; advertisedVersionFlags is
/// the host capability advertisement in the RSD message, not an override.
int ADCOpenRSDDirectoryNetwork(const void *address, size_t addressLength, const char *expectedUDID,
                               const char *localUUID, uint64_t advertisedVersionFlags,
                               int (^shouldCancel)(void), uint16_t *axPort, void **owner,
                               char *error, size_t errorCapacity);
void ADCCloseRSDDirectory(void *owner);
int ADCIsRSDDirectoryActive(void *owner);

/// Exact-UDID pairing-daemon assertion, without initiating pairing. Open owns
/// browse/device connections and an opaque assertion UUID; close consumes owner
/// and separately reports whether release was acknowledged. No device input.
int ADCValidateTunnelAssertionReply(const void *reply, char *address, size_t addressCapacity,
                                    char *error, size_t errorCapacity);
/// Status of ADCOpenNativeTunnelAssertion when the pairing daemon's browse
/// connection reported an error before any endpoint was selected. No assertion
/// was requested and nothing was sent to the device, so opening again is safe.
#define ADCTunnelBrowseInterrupted 3
int ADCOpenNativeTunnelAssertion(const char *expectedUDID, int (^shouldCancel)(void),
                                 char *address, size_t addressCapacity, void **owner,
                                 char *error, size_t errorCapacity);
int ADCCloseNativeTunnelAssertion(void *owner, char *error, size_t errorCapacity);

typedef struct {
    uint64_t supportedFeatures;
    uint64_t sessionCount;
    double runDurationSeconds;
    int running;
    char avcVersion[128];
} ADCMediaInspection;
/// Read-only media control inspection. No offer, stream start, stop or UDP media
/// socket. Exposes counts/capabilities only, never session identities or keys.
int ADCValidateMediaInspection(const void *supportReply, const void *statusReply,
                               ADCMediaInspection *result, char *error, size_t errorCapacity);
int ADCInspectMedia(const char *uuid, const char *version, int (^shouldCancel)(void),
                    ADCMediaInspection *result, char *error, size_t errorCapacity);

typedef struct {
    int startAttempted;
    int stopAcknowledged;
    int ownedStreamAbsent;
    int localDecoderStopRequested;
    int localOutputReleaseRequested;
    uint64_t decodedFrames;
    uint64_t droppedFrames;
} ADCVideoCleanup;
/// Validates negotiated IPv6 endpoints against the selected tunnel and bound
/// receiver. Returns only the sender port; never exports stream keys or IDs.
int ADCValidateVideoEndpoints(const void *reply, const char *hostAddress, const char *deviceAddress,
                              uint16_t receiverPort, uint16_t *senderPort, char *error, size_t errorCapacity);
/// Main-thread, single-owner capture. Create prepares only local resources and
/// a control channel. Start requests one media stream. No global hooks/state.
int ADCCreateVideoSession(const char *uuid, const char *version, const char *interface,
                          const char *hostAddress, const char *deviceAddress, int (^cancelled)(void),
                          void **owner, char *error, size_t errorCapacity);
/// Experimental standard-RTP receiver. Uses Apple's negotiator, not
/// AVCStreamOutput. Start rejects encrypted/non-RTP replies. Same close owner.
int ADCCreateVideoPacketSession(const char *uuid, const char *version, const char *interface,
                                const char *hostAddress, const char *deviceAddress, int (^cancelled)(void),
                                void **owner, char *error, size_t errorCapacity);
/// Synchronously borrows one datagram (max 65535 bytes); 1 delivered, 0 pending,
/// -1 failure. This is transport data, not a decoded video frame.
int ADCCopyNextVideoPacket(void *owner, int (^cancelled)(void),
                           void (^sink)(const uint8_t *, size_t), char *error, size_t errorCapacity);
typedef struct {
    uint64_t negotiatorMode;
    uint64_t width;
    uint64_t height;
    uint64_t frameRate;
    uint64_t payloadType;
} ADCVideoPacketProfile;
int ADCValidateVideoPacketProfile(const void *reply, ADCVideoPacketProfile *profile, char *error, size_t errorCapacity);
/// Whitelisted negotiated video metadata only; no identities/keys or packets.
int ADCReadVideoPacketProfile(void *owner, ADCVideoPacketProfile *profile);
typedef struct {
    uint32_t senderSSRC;
    uint32_t receiverSSRC;
    double reportIntervalSeconds;
    uint8_t feedbackKnown;
    uint8_t feedbackEnabled;
} ADCVideoRTCPProfile;
/// In-memory transport identity only. Never serialize this profile in receipts.
int ADCValidateVideoRTCPProfile(const void *reply, uint32_t offeredReceiver, uint16_t receiverPort,
                                ADCVideoRTCPProfile *profile, char *error, size_t errorCapacity);
int ADCReadVideoRTCPProfile(void *owner, ADCVideoRTCPProfile *profile);
int ADCValidateVideoReceiverReport(const uint8_t *packet, size_t length, uint32_t sender, uint32_t receiver,
                                   char *error, size_t errorCapacity);
/// Sends one bounded compound receiver report to the owned connected peer.
/// Returns 1 sent, 0 transient drop, -1 failure; does not retry or change peers.
int ADCSendVideoReceiverReport(void *owner, const uint8_t *packet, size_t length,
                               int (^cancelled)(void), char *error, size_t errorCapacity);
/// Read-only owned-session status: 1 present, 0 absent, -1 unknown/error.
int ADCVideoSessionActive(void *owner, int (^cancelled)(void), char *error, size_t errorCapacity);
int ADCValidateOwnedVideoStatus(const void *reply, uint32_t identifier, char *error, size_t errorCapacity);
int ADCStartVideoSession(void *owner, int64_t displayID, int (^cancelled)(void), char *error, size_t errorCapacity);
/// Returns 1 for one JPEG delivered synchronously to sink, 0 when none is ready,
/// -1 on error. Bytes are borrowed only during sink. Time starts at first JPEG.
int ADCCopyNextVideoFrame(void *owner, int (^cancelled)(void),
                          void (^sink)(const uint8_t *, size_t, uint64_t), char *error, size_t errorCapacity);
/// Consumes owner, gates callbacks, stops local objects and requests only its
/// reply-derived RemoteSSRC with stopAll=false. No stop-all fallback.
int ADCCloseVideoSession(void *owner, ADCVideoCleanup *result, char *error, size_t errorCapacity);

typedef int (^ADCInputShouldStop)(void);
/// Non-zero status of the input functions below (digitizer reports, button,
/// key, keyboard and touch) once input was attempted: its effect and release
/// are unknown. Any other non-zero status means no input was sent.
#define ADCInputOutcomeUnknown 2
typedef void (^ADCDigitizerSink)(const uint8_t *report);
/// Shared scheduler, also exercised with a local sink. Returns 0 completed,
/// 1 stopped (with release attempted), or 2 invalid (no callbacks invoked).
/// Callbacks run synchronously on the calling thread and are never retained.
int ADCRunDigitizerSchedule(const uint64_t *nanoseconds, const uint8_t *reports, size_t count,
                            ADCInputShouldStop shouldStop, ADCDigitizerSink sendReport);
/// Finite complete-state digitizer schedule; reports are count * 58 bytes.
int ADCPerformCancellableDigitizerReports(const char *uuid, const char *version,
                              const uint64_t *nanoseconds, const uint8_t *reports, size_t count,
                              ADCInputShouldStop shouldCancel, uint64_t *surface,
                              char *error, size_t errorCapacity);

/// Returns zero only after sending one down/up pair and a service barrier.
/// This is transport dispatch, never verification of device UI or key release.
int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned holdMicroseconds, ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);
int ADCPressKeyboardKey(const char *uuid, const char *version, uint64_t usage,
                       ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);
typedef struct {
    uint64_t nanoseconds;
    uint64_t usage;
    uint64_t state; // 1 down, 2 up
} ADCKeyboardSample;
int ADCPerformKeyboard(const char *uuid, const char *version,
                       const ADCKeyboardSample *samples, size_t count,
                       ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);

typedef struct {
    uint64_t nanoseconds;
    double x;
    double y;
    uint64_t phase; // 0 down, 1 move, 2 up
} ADCTouchSample;
typedef struct { double x; double y; } ADCTouchPoint;
int ADCPerformTouch(const char *uuid, const char *version,
                    const ADCTouchSample *samples, size_t count,
                    ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);
int ADCPerformTwoContactTouch(const char *uuid, const char *version,
                    const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                    size_t count, ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);

/// Production Indigo schedulers with synchronous local-sink test boundaries.
/// Return 0 completed, 1 interrupted with release attempted if needed,
/// 2 invalid before callbacks. Sinks run synchronously; sample pointers are
/// borrowed only for the duration of the sink call and must not be retained.
typedef void (^ADCTouchSink)(const ADCTouchSample *, const ADCTouchPoint *);
typedef void (^ADCKeySink)(uint64_t usage, uint64_t state);
int ADCRunTouchSchedule(const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, size_t count,
                        ADCInputShouldStop shouldStop, ADCTouchSink sendSample);
int ADCRunKeyboardSchedule(const ADCKeyboardSample *samples, size_t count,
                           ADCInputShouldStop shouldStop, ADCKeySink sendKey);
int ADCRunPress(uint64_t usage, unsigned holdMicroseconds, ADCInputShouldStop shouldStop, ADCKeySink sendKey);

/// Simulator bridge (AppleSimulatorBridge.m). CoreSimulator addresses one
/// SimDevice of the default device set by UUID. Nothing here starts, boots or
/// shuts down a simulator.
typedef struct {
    double widthPoints;   // portrait main-screen size in points
    double heightPoints;
    double scale;         // pixels per point
    int booted;           // stateString is exactly "Booted"
    char state[32];       // CoreSimulator's stateString, truncated
    char name[128];       // device name, truncated
} ADCSimulatorInfo;
/// Status of ADCOpenSimulatorDevice when no simulator has the UUID.
#define ADCSimulatorNotFound 3
/// Loads CoreSimulator (RTLD_NOW | RTLD_GLOBAL) and, when accessibility is
/// non-zero, AccessibilityPlatformTranslation (RTLD_NOW | RTLD_LOCAL), then
/// checks the classes and selectors the simulator paths call. Returns zero.
int ADCPrepareCoreSimulator(int accessibility, char *error, size_t errorCapacity);
/// Looks up the UUID in the default device set of developerDir. Returns 0 with
/// an owner (whatever the state; check info->booted), ADCSimulatorNotFound, or
/// 1. Reads properties only; sends nothing to the simulator.
int ADCOpenSimulatorDevice(const char *developerDir, const char *uuid, ADCSimulatorInfo *info,
                           void **owner, char *error, size_t errorCapacity);
/// Re-reads state and geometry of an open device. Returns zero.
int ADCReadSimulatorDevice(void *owner, ADCSimulatorInfo *info, char *error, size_t errorCapacity);
void ADCCloseSimulatorDevice(void *owner);
/// Status of ADCSimulatorAXExchange once the request was handed to
/// CoreSimulator but no usable reply arrived (timeout, cancellation, nil or an
/// unarchivable response). Any other non-zero status means nothing was sent.
#define ADCSimulatorAXSent 2
/// One AX request: unarchives the project's AXPTranslatorRequest archive into
/// the framework's own class (secure coding, allow-listed classes; the
/// archived client type is kept), sends it with
/// -[SimDevice sendAccessibilityRequestAsync:...] and archives the
/// AXPTranslatorResponse for the data-only Swift decoder. The response bytes
/// are borrowed only during sink. Waits at most timeoutSeconds, polling
/// shouldCancel every 10 ms.
int ADCSimulatorAXExchange(void *owner, const uint8_t *request, size_t length, double timeoutSeconds,
                           ADCInputShouldStop shouldCancel, void (^sink)(const uint8_t *, size_t),
                           char *error, size_t errorCapacity);
/// Simulator Indigo HID over host XPC to the simulator's dtuhidd daemon. The
/// messages, schedules, validation, release-on-stop and the status contract
/// (zero; ADCInputOutcomeUnknown once input was attempted; another non-zero
/// value when nothing was sent) are those of ADCPerformTouch,
/// ADCPerformKeyboard and ADCPressButton. The device must still be Booted.
int ADCSimulatorPerformTouch(void *owner, const ADCTouchSample *samples, size_t count,
                             ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);
/// Two contacts in one Indigo digitizer schedule (pointOne and pointTwo), as
/// ADCPerformTwoContactTouch sends them to a physical device.
int ADCSimulatorPerformTwoContactTouch(void *owner, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                                       size_t count, ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);
int ADCSimulatorPerformKeyboard(void *owner, const ADCKeyboardSample *samples, size_t count,
                                ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);
int ADCSimulatorPressKeyboardKey(void *owner, uint64_t usage, ADCInputShouldStop shouldCancel,
                                 char *error, size_t errorCapacity);
/// Complete-state Universal HID reports (58 bytes each), validated and
/// scheduled as by ADCPerformCancellableDigitizerReports, sent to the touchscreen
/// that the simulator's universalhidservice lists for displayUUID (the primary
/// display's uniqueId from ADCSimulatorDisplayInfo); exactly one must match.
int ADCSimulatorPerformDigitizerReports(void *owner, const char *displayUUID, const uint64_t *nanoseconds,
                                        const uint8_t *reports, size_t count, ADCInputShouldStop shouldCancel,
                                        uint64_t *surface, char *error, size_t errorCapacity);
/// One read-only CoreDevice display-information request to the simulator's
/// dtdeviceinfod. The sink receives JSON in devicectl's shape,
/// {"info":{"outcome":"success"},"result":{displays, orientation, …}}, borrowed
/// for the call. Returns zero. Sends no input.
int ADCSimulatorDisplayInfo(void *owner, void (^sink)(const uint8_t *, size_t), char *error, size_t errorCapacity);
/// Home (64), lock/side (48), volume up (233) and volume down (234).
int ADCSimulatorPressButton(void *owner, uint64_t usage, unsigned holdMicroseconds,
                            ADCInputShouldStop shouldCancel, char *error, size_t errorCapacity);

/// Host-only availability of the dynamically resolved Apple interfaces, grouped
/// by capability. Loads the listed frameworks with the operations' own flags and
/// looks up symbols, classes and selectors; never calls a resolved function,
/// messages a checked class, opens a connection or contacts a device.
enum {
    ADCInterfaceFramework = 0,      // name is the framework binary path
    ADCInterfaceSymbol = 1,         // C symbol resolved with RTLD_DEFAULT
    ADCInterfaceClass = 2,          // Objective-C class name
    ADCInterfaceInstanceMethod = 3, // owner is the class, name the selector
    ADCInterfaceClassMethod = 4,
    ADCInterfaceFile = 5            // name is a path; existence only, never opened
};
typedef struct {
    int kind;
    const char *name;
    const char *owner;  // NULL unless kind is a method
    int required;       // 0: missing degrades the capability without disabling it
    int available;
} ADCInterfaceRequirement;
typedef struct {
    const char *identifier;
    const char *summary;
    int minimumMacOSMajor;  // 0 when the executable's floor suffices
    int usedByCommands;     // 0 for bridge paths no CLI/MCP command reaches
    const ADCInterfaceRequirement *requirements;
    size_t requirementCount;
} ADCCapabilityCheck;
/// Calls sink synchronously once per capability. Every pointer, including the
/// static strings, is borrowed only for the duration of the call.
void ADCCheckCapabilities(__attribute__((noescape)) void (^sink)(const ADCCapabilityCheck *capability));
#endif
