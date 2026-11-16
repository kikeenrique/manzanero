#ifndef APPLE_DEVICE_BRIDGE_INTERNAL_H
#define APPLE_DEVICE_BRIDGE_INTERNAL_H
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include "AppleDeviceBridge.h"

// Shared between the physical bridge (AppleDeviceBridge.m) and the simulator
// bridge (AppleSimulatorBridge.m). Both platforms speak the same Indigo HID
// dictionaries and validate the same schedules; only the connection differs.
// Not part of the public header: Swift never calls these.

xpc_object_t ADCButtonEvent(uint64_t usage, uint64_t state, BOOL barrier);
xpc_object_t ADCKeyboardEvent(uint64_t usage, uint64_t state, BOOL barrier);
xpc_object_t ADCTouchEvent(double x, double y, const ADCTouchPoint *second, uint64_t phase, BOOL barrier);
int ADCValidateTouchSchedule(const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                             size_t count, char *error, size_t capacity);
int ADCValidateKeyboardSchedule(const ADCKeyboardSample *samples, size_t count, char *error, size_t capacity);
// Universal HID (three to five contacts and timed sequences): the request
// envelope, the report message and the 58-byte complete-state schedule check.
xpc_object_t ADCUniversalRequest(const char *operation, xpc_object_t arguments);
xpc_object_t ADCUniversalReport(const uint8_t *bytes, uint64_t surface);
int ADCValidateDigitizerSchedule(const uint64_t *times, const uint8_t *reports,
                                 size_t count, char *error, size_t capacity);
#endif
