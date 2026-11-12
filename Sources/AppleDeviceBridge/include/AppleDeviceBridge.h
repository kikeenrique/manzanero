#ifndef APPLE_DEVICE_BRIDGE_H
#define APPLE_DEVICE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

/// Returns zero only after sending one down/up pair and a service barrier.
/// This is transport dispatch, never verification of device UI or key release.
int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned holdMicroseconds, char *error, size_t errorCapacity);

typedef struct {
    uint64_t nanoseconds;
    double x;
    double y;
    uint64_t phase; // 0 down, 1 move, 2 up
} ADCTouchSample;
int ADCPerformTouch(const char *uuid, const char *version,
                    const ADCTouchSample *samples, size_t count,
                    char *error, size_t errorCapacity);
#endif
