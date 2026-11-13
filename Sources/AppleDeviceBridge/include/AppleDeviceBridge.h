#ifndef APPLE_DEVICE_BRIDGE_H
#define APPLE_DEVICE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

/// Reads Foundation's property-list UID scalar without unarchiving a class.
/// Returns 1 for a UID, 0 for another plist value, -1 if Apple symbols are absent.
int ADCReadArchiveUID(const void *object, uint64_t *value);

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
void ADCCloseAccessibilitySocket(int descriptor, void *owner);

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
