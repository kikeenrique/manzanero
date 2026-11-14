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

/// Opens only Apple's named remote accessibility service, without a RemoteXPC
/// upgrade. Returns an owned FD, or -1. Close FD and owner together below.
int ADCOpenAccessibilitySocket(const char *uuid, const char *version, void **owner,
                               char *error, size_t errorCapacity);
/// Separate explicit RSD path; verifies UniqueDeviceID before opening AX.
int ADCOpenRSDAccessibilitySocket(const char *remoteUUID, const char *expectedUDID, void **owner,
                                  char *error, size_t errorCapacity);
/// Explicit one-shot browser comparison; uses the same hardware/service guards.
int ADCOpenBrowsedRSDAccessibilitySocket(const char *remoteUUID, const char *expectedUDID, void **owner,
                                        char *error, size_t errorCapacity);
typedef struct {
    uint64_t versionFlags;
    uint64_t modeFlags;
    int tlsEnabled;
} ADCRemoteTransportProfile;
/// Reads service transport metadata for an identity-checked Apple RSD device.
/// Directory-control bootstrap settings are a separate contract.
/// Does not read credentials, open a service socket or subscribe to AX.
int ADCReadRSDTransportProfile(const char *remoteUUID, const char *expectedUDID,
                               ADCRemoteTransportProfile *profile, char *error, size_t errorCapacity);
int ADCReadRSDTransportProfileForHardware(const char *expectedUDID, ADCRemoteTransportProfile *profile,
                                          char *error, size_t errorCapacity);
void ADCCloseAccessibilitySocket(int descriptor, void *owner);

/// Validates a borrowed RemoteXPC RSD Handshake and returns only the exact AX
/// service port. No class decoding or service connection. Returns zero on success.
int ADCValidateRSDHandshake(const void *message, const char *expectedUDID, uint16_t *axPort,
                           char *error, size_t errorCapacity);
/// Consumes a connected stream FD on every path. Owns Apple's RemoteXPC
/// connection until explicitly closed. Does not open AX or enable accessibility.
/// The native bootstrap uses Apple's failsafe getter; versionFlags advertises
/// host capabilities in the RSD message and is not a bootstrap override.
int ADCOpenRSDDirectory(int descriptor, const char *expectedUDID, const char *localUUID, uint64_t versionFlags, uint64_t modeFlags,
                        int (^shouldCancel)(void), uint16_t *axPort, void **owner,
                        char *error, size_t errorCapacity);
/// Separate explicit Network-based control bootstrap. Copies a sockaddr_in6;
/// no FD is transferred. Owns/cancels the Network and RemoteXPC connections.
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
int ADCStartVideoSession(void *owner, int64_t displayID, int (^cancelled)(void), char *error, size_t errorCapacity);
/// Returns 1 for one JPEG delivered synchronously to sink, 0 when none is ready,
/// -1 on error. Bytes are borrowed only during sink. Time starts at first JPEG.
int ADCCopyNextVideoFrame(void *owner, int (^cancelled)(void),
                          void (^sink)(const uint8_t *, size_t, uint64_t), char *error, size_t errorCapacity);
/// Consumes owner, gates callbacks, stops local objects and requests only its
/// reply-derived RemoteSSRC with stopAll=false. No stop-all fallback.
int ADCCloseVideoSession(void *owner, ADCVideoCleanup *result, char *error, size_t errorCapacity);

/// Finite complete-state digitizer schedule; reports are count * 58 bytes.
int ADCPerformDigitizerReports(const char *uuid, const char *version,
                              const uint64_t *nanoseconds, const uint8_t *reports, size_t count,
                              uint64_t *surface, char *error, size_t errorCapacity);

typedef int (^ADCInputShouldStop)(void);
typedef void (^ADCDigitizerSink)(const uint8_t *report);
/// Shared scheduler, also exercised with a local sink. Returns 0 completed,
/// 1 stopped (with release attempted), or 2 invalid (no callbacks invoked).
/// Callbacks run synchronously on the calling thread and are never retained.
int ADCRunDigitizerSchedule(const uint64_t *nanoseconds, const uint8_t *reports, size_t count,
                            ADCInputShouldStop shouldStop, ADCDigitizerSink sendReport);
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
#endif
