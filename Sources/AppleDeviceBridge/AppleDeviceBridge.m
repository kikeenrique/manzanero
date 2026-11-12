#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include "AppleDeviceBridge.h"

// Private Apple interfaces stay in this in-process interoperability target.
// Protocol references: docs/AXE-PHYSICAL-REVIEW.md and docs/NATIVE-INPUT.md.
typedef void *ADCRemote;
typedef ADCRemote (*ADCCreate)(int, dispatch_queue_t, uint64_t, uint64_t);
typedef void (*ADCHandler)(ADCRemote, xpc_handler_t);
typedef void (*ADCActivate)(ADCRemote);
typedef void (*ADCSend)(ADCRemote, xpc_object_t);
typedef void (*ADCReply)(ADCRemote, xpc_object_t, dispatch_queue_t, xpc_handler_t);

@interface ADCReplyState : NSObject
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@property(atomic, strong) xpc_object_t reply;
@property(atomic) BOOL failed;
@end
@implementation ADCReplyState
- (instancetype)init { if ((self = [super init])) _semaphore = dispatch_semaphore_create(0); return self; }
@end

static int ADCFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String);
    return 1;
}

static xpc_object_t ADCEnvelope(const char *uuid, const char *version, xpc_object_t input) {
    xpc_object_t message = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", "com.apple.coredevice.action.createservicesocket");
    xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", uuid);
    xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", NSUUID.UUID.UUIDString.UTF8String);
    xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 1);
    xpc_object_t release = xpc_dictionary_create_empty(), components = xpc_array_create_empty();
    for (NSString *part in [[NSString stringWithUTF8String:version] componentsSeparatedByString:@"."]) {
        xpc_array_append_value(components, xpc_uint64_create(part.longLongValue));
    }
    xpc_dictionary_set_value(release, "components", components);
    xpc_dictionary_set_int64(release, "originalComponentsCount", xpc_array_get_count(components));
    xpc_dictionary_set_string(release, "stringValue", version);
    xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", release);
    xpc_dictionary_set_value(message, "CoreDevice.input", input);
    return message;
}

static xpc_object_t ADCButtonEvent(uint64_t usage, uint64_t state, BOOL barrier) {
    xpc_object_t event = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(event, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.button");
    xpc_dictionary_set_string(event, "messageType", "IndigoButtonEvent");
    xpc_dictionary_set_bool(event, "isBarrier", barrier);
    if (!barrier) {
        xpc_object_t payload = xpc_dictionary_create_empty();
        xpc_dictionary_set_uint64(payload, "usagePage", 12);
        xpc_dictionary_set_uint64(payload, "usageCode", usage);
        xpc_dictionary_set_uint64(payload, "state", state);
        xpc_dictionary_set_value(event, "payload", payload);
    }
    return event;
}

static xpc_object_t ADCKeyboardEvent(uint64_t usage, uint64_t state, BOOL barrier) {
    xpc_object_t event = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(event, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.keyboard");
    xpc_dictionary_set_string(event, "messageType", "IndigoKeyboardButtonEvent");
    xpc_dictionary_set_bool(event, "isBarrier", barrier);
    if (!barrier) {
        xpc_object_t payload = xpc_dictionary_create_empty();
        xpc_dictionary_set_uint64(payload, "usageCode", usage);
        xpc_dictionary_set_uint64(payload, "state", state);
        xpc_dictionary_set_value(event, "payload", payload);
    }
    return event;
}

static xpc_object_t ADCTouchEvent(double x, double y, const ADCTouchPoint *second, uint64_t phase, BOOL barrier) {
    xpc_object_t event = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(event, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.digitizer");
    xpc_dictionary_set_string(event, "messageType", "IndigoDigitizerEvent");
    xpc_dictionary_set_bool(event, "isBarrier", barrier);
    if (!barrier) {
        xpc_object_t payload = xpc_dictionary_create_empty(), point = xpc_dictionary_create_empty();
        xpc_dictionary_set_double(point, "x", x);
        xpc_dictionary_set_double(point, "y", y);
        xpc_dictionary_set_value(payload, "pointOne", point);
        if (second) {
            xpc_object_t pointTwo = xpc_dictionary_create_empty();
            xpc_dictionary_set_double(pointTwo, "x", second->x);
            xpc_dictionary_set_double(pointTwo, "y", second->y);
            xpc_dictionary_set_value(payload, "pointTwo", pointTwo);
        }
        xpc_dictionary_set_uint64(payload, "eventType", phase);
        xpc_dictionary_set_uint64(payload, "edge", 0);
        xpc_dictionary_set_uint64(payload, "target", 0);
        xpc_dictionary_set_value(event, "payload", payload);
    }
    return event;
}

static uint64_t ADCNow(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * NSEC_PER_SEC + value.tv_nsec;
}

static int ADCPerformInput(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, BOOL keyboard, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, const ADCKeyboardSample *keys, size_t count, char *error, size_t capacity) {
    @autoreleasepool {
        if (!uuid || !version || ![[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid]]) {
            return ADCFail(error, capacity, @"Invalid direct input identity.");
        }
        const char *feature = samples ? "com.apple.coredevice.feature.remote.hid.digitizer" : "com.apple.coredevice.feature.remote.hid.button";
        // Button and keyboard events share Apple's Indigo HID service. Open its
        // registered button feature rather than inventing a standalone keyboard
        // feature socket; keyboard messages carry their own feature identifier.
        xpc_object_t (*scalarEvent)(uint64_t, uint64_t, BOOL) = keyboard ? ADCKeyboardEvent : ADCButtonEvent;
        static void *framework;
        static dispatch_once_t loadOnce;
        dispatch_once(&loadOnce, ^{
            framework = dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice", RTLD_NOW | RTLD_GLOBAL);
        });
        if (!framework) return ADCFail(error, capacity, @"Cannot load the installed Apple CoreDevice framework.");
        void (*addBundle)(NSBundle *) = dlsym(RTLD_DEFAULT, "_coredevice_xpc_add_bundle");
        void (*initialize)(void) = dlsym(RTLD_DEFAULT, "_coredevice_xpc_init_services");
        ADCCreate create = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
        ADCHandler handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        ADCActivate activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        ADCSend send = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message");
        ADCReply request = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply");
        if (!addBundle || !initialize || !create || !handler || !activate || !cancel || !send || !request)
            return ADCFail(error, capacity, @"Required Apple CoreDevice/RemoteXPC symbols are unavailable.");
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            addBundle([NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"]);
            initialize();
        });
        dispatch_queue_t queue = dispatch_queue_create("appledevices.coredevice.button", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t connection = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", queue);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
        xpc_connection_resume(connection);
        xpc_object_t input = xpc_dictionary_create_empty();
        xpc_dictionary_set_string(input, "featureIdentifier", feature);
        if (samples || keyboard) xpc_dictionary_set_string(input, "serviceName", "com.apple.coredevice.hid.indigo");
        ADCReplyState *socketReply = [ADCReplyState new];
        xpc_connection_send_message_with_reply(connection, ADCEnvelope(uuid, version, input), queue, ^(xpc_object_t reply) {
            socketReply.reply = reply;
            dispatch_semaphore_signal(socketReply.semaphore);
        });
        if (dispatch_semaphore_wait(socketReply.semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
            xpc_connection_cancel(connection);
            return ADCFail(error, capacity, @"Apple CoreDevice service socket request timed out before input.");
        }
        xpc_object_t reply = socketReply.reply;
        xpc_object_t output = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : NULL;
        int fd = output ? xpc_dictionary_dup_fd(output, "fileDescriptor") : -1;
        if (fd < 0) {
            xpc_connection_cancel(connection);
            return ADCFail(error, capacity, @"Apple CoreDevice refused the input service socket before input.");
        }
        ADCRemote remote = create(fd, queue, xpc_dictionary_get_uint64(output, "remoteXPCVersionFlags"), 0);
        if (!remote) {
            close(fd); xpc_connection_cancel(connection);
            return ADCFail(error, capacity, @"Apple RemoteXPC connection creation failed before input.");
        }
        __attribute__((objc_precise_lifetime)) id remoteOwner = CFBridgingRelease(remote);
        (void)remoteOwner;
        ADCReplyState *status = [ADCReplyState new];
        handler(remote, ^(xpc_object_t event) { if (xpc_get_type(event) == XPC_TYPE_ERROR) status.failed = YES; });
        activate(remote);
        if (samples || keyboard) {
            ADCReplyState *ready = [ADCReplyState new];
            xpc_object_t barrier = samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES);
            request(remote, barrier, queue, ^(xpc_object_t response) {
                ready.reply = response;
                dispatch_semaphore_signal(ready.semaphore);
            });
            BOOL timeout = dispatch_semaphore_wait(ready.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
            if (timeout || status.failed || !ready.reply || xpc_get_type(ready.reply) != XPC_TYPE_DICTIONARY ||
                xpc_dictionary_get_value(ready.reply, "CoreDevice.error") || xpc_dictionary_get_value(ready.reply, "error")) {
                cancel(remote); xpc_connection_cancel(connection);
                return ADCFail(error, capacity, @"Apple HID service did not become ready; no input sent.");
            }
        }
        if (samples) {
            uint64_t start = ADCNow();
            size_t attempted = 0;
            for (size_t i = 0; i < count; i++) {
                uint64_t target = start + samples[i].nanoseconds;
                uint64_t now;
                while ((now = ADCNow()) < target && !status.failed) {
                    uint64_t remaining = target - now;
                    struct timespec wait = { (time_t)(remaining / NSEC_PER_SEC), (long)(remaining % NSEC_PER_SEC) };
                    nanosleep(&wait, NULL);
                }
                if (status.failed) break;
                attempted = i;
                send(remote, ADCTouchEvent(samples[i].x, samples[i].y, secondPoints ? &secondPoints[i] : NULL, samples[i].phase, NO));
            }
            // A failed send may already have reached the device; attempt up at
            // the last attempted position without replaying any movement.
            if (samples[attempted].phase != 2)
                send(remote, ADCTouchEvent(samples[attempted].x, samples[attempted].y, secondPoints ? &secondPoints[attempted] : NULL, 2, NO));
        } else if (keys) {
            BOOL pressed[256] = {NO};
            uint64_t start = ADCNow();
            for (size_t i = 0; i < count; i++) {
                uint64_t target = start + keys[i].nanoseconds, now;
                while ((now = ADCNow()) < target && !status.failed) {
                    uint64_t remaining = target - now;
                    struct timespec wait = { (time_t)(remaining / NSEC_PER_SEC), (long)(remaining % NSEC_PER_SEC) };
                    nanosleep(&wait, NULL);
                }
                if (status.failed) break;
                // Mark attempted downs before sending: failure does not prove
                // the device missed the event. Release without replaying text.
                pressed[keys[i].usage] = keys[i].state == 1;
                send(remote, ADCKeyboardEvent(keys[i].usage, keys[i].state, NO));
            }
            // Release ordinary keys before modifiers on an ordinary failure.
            for (size_t code = 0; code < 256; code++)
                if (pressed[code]) send(remote, ADCKeyboardEvent(code, 2, NO));
        } else {
            send(remote, scalarEvent(usage, 1, NO));
            usleep(hold);
            send(remote, scalarEvent(usage, 2, NO));
        }
        xpc_object_t barrier = samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES);
        request(remote, barrier, queue, ^(xpc_object_t response) {
            status.reply = response;
            dispatch_semaphore_signal(status.semaphore);
        });
        BOOL timedOut = dispatch_semaphore_wait(status.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
        xpc_object_t barrierReply = status.reply;
        BOOL failed = status.failed || timedOut || !barrierReply || xpc_get_type(barrierReply) != XPC_TYPE_DICTIONARY;
        if (!failed) failed = xpc_dictionary_get_value(barrierReply, "CoreDevice.error") != NULL ||
            xpc_dictionary_get_value(barrierReply, "error") != NULL;
        cancel(remote);
        xpc_connection_cancel(connection);
        if (failed) return ADCFail(error, capacity, @"Input was attempted, but the Apple service barrier was not confirmed. UI effect and release are unknown; do not replay automatically.");
        return 0;
    }
}

int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, char *error, size_t capacity) {
    if ((usage != 64 && usage != 48 && usage != 233 && usage != 234) || hold > 400000)
        return ADCFail(error, capacity, @"Invalid direct button request.");
    return ADCPerformInput(uuid, version, usage, hold, NO, NULL, NULL, NULL, 0, error, capacity);
}

int ADCPressKeyboardKey(const char *uuid, const char *version, uint64_t usage, char *error, size_t capacity) {
    if (!((usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82)))
        return ADCFail(error, capacity, @"Unsupported direct keyboard usage; no input sent.");
    return ADCPerformInput(uuid, version, usage, 80000, YES, NULL, NULL, NULL, 0, error, capacity);
}

int ADCPerformKeyboard(const char *uuid, const char *version, const ADCKeyboardSample *samples,
                       size_t count, char *error, size_t capacity) {
    if (!samples || count < 2 || count > 4096)
        return ADCFail(error, capacity, @"Invalid keyboard sample count; no input sent.");
    BOOL pressed[256] = {NO};
    for (size_t i = 0; i < count; i++) {
        ADCKeyboardSample key = samples[i];
        BOOL supported = (key.usage >= 4 && key.usage <= 56) || (key.usage >= 79 && key.usage <= 82) || key.usage == 225 || key.usage == 227;
        if (!supported || (key.state != 1 && key.state != 2) ||
            key.nanoseconds > 31ULL * NSEC_PER_SEC ||
            (i == 0 ? key.nanoseconds != 0 : key.nanoseconds <= samples[i - 1].nanoseconds) ||
            pressed[key.usage] == (key.state == 1))
            return ADCFail(error, capacity, @"Invalid or unbalanced keyboard schedule; no input sent.");
        pressed[key.usage] = key.state == 1;
    }
    for (size_t code = 0; code < 256; code++)
        if (pressed[code]) return ADCFail(error, capacity, @"Keyboard schedule must release every key; no input sent.");
    return ADCPerformInput(uuid, version, 0, 0, YES, NULL, NULL, samples, count, error, capacity);
}

static int ADCValidateAndPerformTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    const ADCTouchPoint *secondPoints, size_t count, char *error, size_t capacity) {
    if (!samples || count < 2 || count > 8192) return ADCFail(error, capacity, @"Invalid direct touch sample count.");
    for (size_t i = 0; i < count; i++) {
        ADCTouchSample sample = samples[i];
        uint64_t expectedPhase = i == 0 ? 0 : (i == count - 1 ? 2 : 1);
        if (!isfinite(sample.x) || !isfinite(sample.y) || sample.x < 0 || sample.x > 1 || sample.y < 0 || sample.y > 1 ||
            sample.phase != expectedPhase || sample.nanoseconds > 11ULL * NSEC_PER_SEC ||
            (i == 0 ? sample.nanoseconds != 0 : sample.nanoseconds <= samples[i - 1].nanoseconds))
            return ADCFail(error, capacity, @"Invalid direct touch sequence; no input sent.");
        if (secondPoints) {
            ADCTouchPoint second = secondPoints[i];
            if (!isfinite(second.x) || !isfinite(second.y) || second.x < 0 || second.x > 1 || second.y < 0 || second.y > 1 ||
                (second.x == sample.x && second.y == sample.y))
                return ADCFail(error, capacity, @"Invalid second contact; no input sent.");
        }
    }
    return ADCPerformInput(uuid, version, 0, 0, NO, samples, secondPoints, NULL, count, error, capacity);
}

int ADCPerformTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    size_t count, char *error, size_t capacity) {
    return ADCValidateAndPerformTouch(uuid, version, samples, NULL, count, error, capacity);
}

int ADCPerformTwoContactTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    const ADCTouchPoint *secondPoints, size_t count, char *error, size_t capacity) {
    if (!secondPoints) return ADCFail(error, capacity, @"Missing second contact; no input sent.");
    return ADCValidateAndPerformTouch(uuid, version, samples, secondPoints, count, error, capacity);
}
