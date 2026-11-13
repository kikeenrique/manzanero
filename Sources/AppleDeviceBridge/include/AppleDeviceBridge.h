#ifndef APPLE_DEVICE_BRIDGE_H
#define APPLE_DEVICE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

/// Opens only Apple's named remote accessibility service, without a RemoteXPC
/// upgrade. Returns an owned FD, or -1. Close FD and owner together below.
int ADCOpenAccessibilitySocket(const char *uuid, const char *version, void **owner,
                               char *error, size_t errorCapacity);
/// Separate explicit RSD path; verifies UniqueDeviceID before opening AX.
int ADCOpenRSDAccessibilitySocket(const char *remoteUUID, const char *expectedUDID, void **owner,
                                  char *error, size_t errorCapacity);
void ADCCloseAccessibilitySocket(int descriptor, void *owner);

/// Finite complete-state digitizer schedule; reports are count * 58 bytes.
int ADCPerformDigitizerReports(const char *uuid, const char *version,
                              const uint64_t *nanoseconds, const uint8_t *reports, size_t count,
                              uint64_t *surface, char *error, size_t errorCapacity);

/// Returns zero only after sending one down/up pair and a service barrier.
/// This is transport dispatch, never verification of device UI or key release.
int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned holdMicroseconds, char *error, size_t errorCapacity);
int ADCPressKeyboardKey(const char *uuid, const char *version, uint64_t usage,
                       char *error, size_t errorCapacity);
typedef struct {
    uint64_t nanoseconds;
    uint64_t usage;
    uint64_t state; // 1 down, 2 up
} ADCKeyboardSample;
int ADCPerformKeyboard(const char *uuid, const char *version,
                       const ADCKeyboardSample *samples, size_t count,
                       char *error, size_t errorCapacity);

typedef struct {
    uint64_t nanoseconds;
    double x;
    double y;
    uint64_t phase; // 0 down, 1 move, 2 up
} ADCTouchSample;
typedef struct { double x; double y; } ADCTouchPoint;
int ADCPerformTouch(const char *uuid, const char *version,
                    const ADCTouchSample *samples, size_t count,
                    char *error, size_t errorCapacity);
int ADCPerformTwoContactTouch(const char *uuid, const char *version,
                    const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                    size_t count, char *error, size_t errorCapacity);
#endif
