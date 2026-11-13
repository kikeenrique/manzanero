#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include <fcntl.h>
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

@interface ADCAccessibilitySocketOwner : NSObject
@property(nonatomic, strong) xpc_connection_t connection;
@property(nonatomic, strong) id device;
@property(nonatomic, strong) id service;
@end
@implementation ADCAccessibilitySocketOwner
@end

static int ADCFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String);
    return 1;
}

static int ADCPrepareCoreDevice(char *error, size_t capacity) {
    static void *framework;
    static dispatch_once_t loadOnce;
    dispatch_once(&loadOnce, ^{
        framework = dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice", RTLD_NOW | RTLD_GLOBAL);
    });
    if (!framework) return ADCFail(error, capacity, @"Cannot load the installed Apple CoreDevice framework.");
    void (*addBundle)(NSBundle *) = dlsym(RTLD_DEFAULT, "_coredevice_xpc_add_bundle");
    void (*initialize)(void) = dlsym(RTLD_DEFAULT, "_coredevice_xpc_init_services");
    if (!addBundle || !initialize) return ADCFail(error, capacity, @"Required Apple CoreDevice initialization symbols are unavailable.");
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        addBundle([NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"]);
        initialize();
    });
    return 0;
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

int ADCOpenAccessibilitySocket(const char *uuid, const char *version, void **owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        NSString *identifier = uuid ? [NSString stringWithUTF8String:uuid] : nil;
        NSString *release = version ? [NSString stringWithUTF8String:version] : nil;
        if (!owner || !identifier || ![[NSUUID alloc] initWithUUIDString:identifier] || !release ||
            [release rangeOfString:@"^[0-9]+(?:\\.[0-9]+){0,3}$" options:NSRegularExpressionSearch].length != release.length || release.length == 0) {
            ADCFail(error, capacity, @"Invalid direct accessibility socket identity or owner.");
            return -1;
        }
        if (ADCPrepareCoreDevice(error, capacity)) return -1;
        dispatch_queue_t queue = dispatch_queue_create("appledevices.coredevice.accessibility-socket", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t connection = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", queue);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
        xpc_connection_resume(connection);
        xpc_object_t input = xpc_dictionary_create_empty();
        // Installed CoreDevice Input(serviceName:featureIdentifier:) permits
        // selection by name alone. AX carries raw DTX, not HID RemoteXPC.
        xpc_dictionary_set_string(input, "serviceName", "com.apple.accessibility.axAuditDaemon.remoteAXService");
        ADCReplyState *state = [ADCReplyState new];
        xpc_connection_send_message_with_reply(connection, ADCEnvelope(uuid, version, input), queue, ^(xpc_object_t reply) {
            state.reply = reply;
            dispatch_semaphore_signal(state.semaphore);
        });
        if (dispatch_semaphore_wait(state.semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
            xpc_connection_cancel(connection);
            ADCFail(error, capacity, @"Apple accessibility socket request timed out; no accessibility subscription sent.");
            return -1;
        }
        xpc_object_t response = state.reply;
        xpc_object_t output = response && xpc_get_type(response) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(response, "CoreDevice.output") : NULL;
        int descriptor = output ? xpc_dictionary_dup_fd(output, "fileDescriptor") : -1;
        if (descriptor < 0) {
            xpc_object_t failure = response && xpc_get_type(response) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(response, "CoreDevice.error") : NULL;
            const char *domain = failure ? xpc_dictionary_get_string(failure, "domain") : NULL;
            long long code = failure ? xpc_dictionary_get_int64(failure, "code") : 0;
            xpc_connection_cancel(connection);
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple refused the raw accessibility socket (%s %lld); no accessibility subscription sent.", domain ?: "unknown", code]);
            return -1;
        }
        if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1) {
            close(descriptor); xpc_connection_cancel(connection);
            ADCFail(error, capacity, @"Cannot protect accessibility socket ownership; no subscription sent.");
            return -1;
        }
        ADCAccessibilitySocketOwner *lifetime = [ADCAccessibilitySocketOwner new];
        lifetime.connection = connection;
        *owner = (void *)CFBridgingRetain(lifetime);
        return descriptor;
    }
}

int ADCOpenRSDAccessibilitySocket(const char *remoteUUID, const char *expectedUDID, void **owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        NSString *identifier = remoteUUID ? [NSString stringWithUTF8String:remoteUUID] : nil;
        NSString *hardware = expectedUDID ? [NSString stringWithUTF8String:expectedUDID] : nil;
        if (!owner || !identifier || ![[NSUUID alloc] initWithUUIDString:identifier] || !hardware ||
            [hardware rangeOfString:@"^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$" options:NSRegularExpressionSearch].length != hardware.length || hardware.length == 0) {
            ADCFail(error, capacity, @"Invalid RSD accessibility identity or owner.");
            return -1;
        }
        static void *framework;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            framework = dlopen("/System/Library/PrivateFrameworks/RemoteServiceDiscovery.framework/RemoteServiceDiscovery", RTLD_NOW | RTLD_GLOBAL);
        });
        // Signatures/selection keys follow the installed Apple remotectl caller.
        void *(*matching)(xpc_object_t) = dlsym(RTLD_DEFAULT, "remote_device_copy_device_matching");
        void *(*property)(id, const char *) = dlsym(RTLD_DEFAULT, "remote_device_copy_property");
        void *(*service)(id, const char *) = dlsym(RTLD_DEFAULT, "remote_device_copy_service");
        void *(*serviceNames)(id) = dlsym(RTLD_DEFAULT, "remote_device_copy_service_names");
        int (*parseType)(const char *) = dlsym(RTLD_DEFAULT, "remote_device_type_parse");
        const char *(*describeType)(int) = dlsym(RTLD_DEFAULT, "remote_device_type_get_description");
        int (*deviceType)(id) = dlsym(RTLD_DEFAULT, "remote_device_get_type");
        int (*state)(id) = dlsym(RTLD_DEFAULT, "remote_device_get_state");
        bool (*encrypted)(id) = dlsym(RTLD_DEFAULT, "remote_service_should_encrypt_socket_data");
        int (*connect)(id) = dlsym(RTLD_DEFAULT, "remote_service_create_connected_socket");
        if (!framework || !matching || !property || !service || !serviceNames || !parseType || !describeType || !deviceType || !state || !encrypted || !connect) {
            ADCFail(error, capacity, @"Installed Apple raw-service APIs are unavailable.");
            return -1;
        }
        int expectedType = parseType("coredevice-device");
        const char *typeName = expectedType ? describeType(expectedType) : NULL;
        if (!typeName) {
            ADCFail(error, capacity, @"Apple RSD does not recognize the required device type; no socket opened.");
            return -1;
        }
        xpc_object_t selection = xpc_dictionary_create_empty();
        xpc_dictionary_set_string(selection, "DeviceType", typeName);
        xpc_dictionary_set_string(selection, "DeviceUUID", remoteUUID);
        id device = CFBridgingRelease(matching(selection));
        if (!device || state(device) != 2) {
            ADCFail(error, capacity, [NSString stringWithFormat:@"Selected Apple RSD device %@; no subscription sent.", device ? [NSString stringWithFormat:@"is not connected (state %d)", state(device)] : @"was not found"]);
            return -1;
        }
        if (deviceType(device) != expectedType) {
            ADCFail(error, capacity, @"Apple RSD resolved a different device type; no socket opened.");
            return -1;
        }
        xpc_object_t udid = CFBridgingRelease(property(device, "UniqueDeviceID"));
        const char *actual = udid && xpc_get_type(udid) == XPC_TYPE_STRING ? xpc_string_get_string_ptr(udid) : NULL;
        NSString *actualIdentifier = actual ? [NSString stringWithUTF8String:actual] : nil;
        if (!actualIdentifier || [hardware caseInsensitiveCompare:actualIdentifier] != NSOrderedSame) {
            ADCFail(error, capacity, @"Apple RSD hardware identity mismatch; no socket opened.");
            return -1;
        }
        // Match Apple's show caller: read the device's service-name inventory
        // before asking for an endpoint. Keep missing inventory distinct from
        // an advertised service whose endpoint lookup fails.
        xpc_object_t names = CFBridgingRelease(serviceNames(device));
        __block BOOL advertised = NO;
        size_t serviceCount = names && xpc_get_type(names) == XPC_TYPE_ARRAY ? xpc_array_get_count(names) : 0;
        if (serviceCount > 4096) {
            ADCFail(error, capacity, @"Apple RSD service inventory exceeded its bound; no socket opened.");
            return -1;
        }
        if (serviceCount) xpc_array_apply(names, ^bool(size_t index, xpc_object_t item) {
            const char *name = xpc_get_type(item) == XPC_TYPE_STRING ? xpc_string_get_string_ptr(item) : NULL;
            if (name && strcmp(name, "com.apple.accessibility.axAuditDaemon.remoteAXService") == 0) advertised = YES;
            return true;
        });
        if (!advertised) {
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple RSD %s inventory (%zu services) did not advertise accessibility to this client; no subscription sent.", typeName, serviceCount]);
            return -1;
        }
        id endpoint = CFBridgingRelease(service(device, "com.apple.accessibility.axAuditDaemon.remoteAXService"));
        if (!endpoint || encrypted(endpoint)) {
            ADCFail(error, capacity, endpoint ? @"Raw Apple accessibility service requires encryption; no subscription sent." : @"Apple RSD advertised accessibility, but endpoint lookup returned none; no subscription sent.");
            return -1;
        }
        int descriptor = connect(endpoint);
        if (descriptor < 0) {
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple raw accessibility socket failed (errno %d); no subscription sent.", errno]);
            return -1;
        }
        if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1) {
            close(descriptor);
            ADCFail(error, capacity, @"Cannot protect raw accessibility socket ownership; no subscription sent.");
            return -1;
        }
        ADCAccessibilitySocketOwner *lifetime = [ADCAccessibilitySocketOwner new];
        lifetime.device = device;
        lifetime.service = endpoint;
        *owner = (void *)CFBridgingRetain(lifetime);
        return descriptor;
    }
}

void ADCCloseAccessibilitySocket(int descriptor, void *owner) {
    if (descriptor >= 0) close(descriptor);
    if (owner) {
        ADCAccessibilitySocketOwner *lifetime = CFBridgingRelease(owner);
        if (lifetime.connection) xpc_connection_cancel(lifetime.connection);
    }
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

static xpc_object_t ADCUniversalRequest(const char *operation, xpc_object_t arguments) {
    xpc_object_t message = xpc_dictionary_create_empty(), payload = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "messageType", "Request");
    xpc_dictionary_set_string(message, "featureIdentifier", "com.apple.coredevice.feature.remote.universalhidservice");
    xpc_dictionary_set_value(payload, operation, arguments);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

static xpc_object_t ADCUniversalReport(const uint8_t *bytes, uint64_t surface) {
    xpc_object_t arguments = xpc_dictionary_create_empty();
    xpc_dictionary_set_data(arguments, "_0", bytes, 58);
    xpc_dictionary_set_uint64(arguments, "_1", surface);
    return ADCUniversalRequest("send", arguments);
}

static xpc_object_t ADCUniversalBarrier(void) {
    xpc_object_t barrier = xpc_dictionary_create_empty();
    xpc_dictionary_set_bool(barrier, "isBarrier", true);
    return barrier;
}

static BOOL ADCValidHIDReply(xpc_object_t reply) {
    return reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
        !xpc_dictionary_get_value(reply, "CoreDevice.error") && !xpc_dictionary_get_value(reply, "error");
}

static int ADCPerformInput(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, BOOL keyboard, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, const ADCKeyboardSample *keys,
                   const uint64_t *reportTimes, const uint8_t *reports, uint64_t *resolvedSurface, size_t count, char *error, size_t capacity) {
    @autoreleasepool {
        if (!uuid || !version || ![[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid]]) {
            return ADCFail(error, capacity, @"Invalid direct input identity.");
        }
        const char *feature = reports ? "com.apple.coredevice.feature.remote.universalhidservice" :
            (samples ? "com.apple.coredevice.feature.remote.hid.digitizer" : "com.apple.coredevice.feature.remote.hid.button");
        // Button and keyboard events share Apple's Indigo HID service. Open its
        // registered button feature rather than inventing a standalone keyboard
        // feature socket; keyboard messages carry their own feature identifier.
        xpc_object_t (*scalarEvent)(uint64_t, uint64_t, BOOL) = keyboard ? ADCKeyboardEvent : ADCButtonEvent;
        if (ADCPrepareCoreDevice(error, capacity)) return 1;
        ADCCreate create = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
        ADCHandler handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        ADCActivate activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        ADCSend send = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message");
        ADCReply request = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply");
        if (!create || !handler || !activate || !cancel || !send || !request)
            return ADCFail(error, capacity, @"Required Apple CoreDevice/RemoteXPC symbols are unavailable.");
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
        uint64_t surface = 0;
        if (reports) {
            ADCReplyState *discovery = [ADCReplyState new];
            request(remote, ADCUniversalRequest("connectedServices", xpc_dictionary_create_empty()), queue, ^(xpc_object_t response) {
                discovery.reply = response;
                dispatch_semaphore_signal(discovery.semaphore);
            });
            BOOL timeout = dispatch_semaphore_wait(discovery.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
            xpc_object_t services = ADCValidHIDReply(discovery.reply) ? xpc_dictionary_get_array(discovery.reply, "connectedServices") : NULL;
            size_t matches = 0;
            if (!timeout && !status.failed && services && xpc_array_get_count(services) <= 128) {
                for (size_t i = 0; i < xpc_array_get_count(services); i++) {
                    xpc_object_t descriptor = xpc_array_get_value(services, i);
                    if (xpc_get_type(descriptor) != XPC_TYPE_DICTIONARY) continue;
                    const char *product = xpc_dictionary_get_string(descriptor, "Product");
                    xpc_object_t identifier = xpc_dictionary_get_value(descriptor, "_ServiceID");
                    uint64_t value = identifier && xpc_get_type(identifier) == XPC_TYPE_UINT64 ? xpc_uint64_get_value(identifier) : 0;
                    if (product && strncmp(product, "CoreDevice touchscreen(", 23) == 0 && value) { surface = value; matches++; }
                }
            }
            if (matches != 1) {
                cancel(remote); xpc_connection_cancel(connection);
                return ADCFail(error, capacity, @"Apple Universal HID did not identify exactly one touchscreen; no report sent.");
            }
        }
        if (samples || keyboard || reports) {
            ADCReplyState *ready = [ADCReplyState new];
            xpc_object_t barrier = reports ? ADCUniversalBarrier() : (samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES));
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
        if (reports) {
            uint64_t start = ADCNow();
            size_t last = 0;
            BOOL attempted = NO;
            for (size_t i = 0; i < count; i++) {
                uint64_t target = start + reportTimes[i], now;
                while ((now = ADCNow()) < target && !status.failed) {
                    uint64_t remaining = target - now;
                    struct timespec wait = { (time_t)(remaining / NSEC_PER_SEC), (long)(remaining % NSEC_PER_SEC) };
                    nanosleep(&wait, NULL);
                }
                if (status.failed) break;
                attempted = YES; last = i;
                send(remote, ADCUniversalReport(reports + i * 58, surface));
            }
            if (attempted) {
                uint8_t release[58]; memcpy(release, reports + last * 58, 58);
                BOOL active = NO;
                for (size_t id = 0; id < release[1]; id++) {
                    if (release[3 + id * 5] & 0xc0) active = YES;
                    release[3 + id * 5] = (uint8_t)id;
                }
                if (active) send(remote, ADCUniversalReport(release, surface));
            }
        } else if (samples) {
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
        xpc_object_t barrier = reports ? ADCUniversalBarrier() : (samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES));
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
        if (resolvedSurface) *resolvedSurface = surface;
        return 0;
    }
}

int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, char *error, size_t capacity) {
    if ((usage != 64 && usage != 48 && usage != 233 && usage != 234) || hold > 400000)
        return ADCFail(error, capacity, @"Invalid direct button request.");
    return ADCPerformInput(uuid, version, usage, hold, NO, NULL, NULL, NULL, NULL, NULL, NULL, 0, error, capacity);
}

int ADCPressKeyboardKey(const char *uuid, const char *version, uint64_t usage, char *error, size_t capacity) {
    if (!((usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82)))
        return ADCFail(error, capacity, @"Unsupported direct keyboard usage; no input sent.");
    return ADCPerformInput(uuid, version, usage, 80000, YES, NULL, NULL, NULL, NULL, NULL, NULL, 0, error, capacity);
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
    return ADCPerformInput(uuid, version, 0, 0, YES, NULL, NULL, samples, NULL, NULL, NULL, count, error, capacity);
}

int ADCPerformDigitizerReports(const char *uuid, const char *version, const uint64_t *times,
                              const uint8_t *reports, size_t count, uint64_t *surface, char *error, size_t capacity) {
    if (surface) *surface = 0;
    if (!times || !reports || count < 2 || count > 512)
        return ADCFail(error, capacity, @"Invalid digitizer report schedule count; no input sent.");
    for (size_t frame = 0; frame < count; frame++) {
        const uint8_t *bytes = reports + frame * 58;
        size_t contacts = bytes[1];
        if (bytes[0] != 9 || contacts < 1 || contacts > 5 || contacts != reports[1] || bytes[2] != 5 ||
            times[frame] > 10ULL * NSEC_PER_SEC + NSEC_PER_MSEC || (frame == 0 ? times[frame] != 0 : times[frame] <= times[frame - 1]))
            return ADCFail(error, capacity, @"Invalid digitizer report identity or time; no input sent.");
        BOOL active = NO;
        for (size_t id = 0; id < contacts; id++) {
            size_t offset = 3 + id * 5;
            if (bytes[offset] != id && bytes[offset] != (0xc0 | id))
                return ADCFail(error, capacity, @"Invalid digitizer contact flags; no input sent.");
            if (bytes[offset] & 0xc0) active = YES;
            else if (frame && memcmp(bytes + offset + 1, reports + (frame - 1) * 58 + offset + 1, 4))
                return ADCFail(error, capacity, @"Inactive digitizer contact moved; no input sent.");
        }
        if ((frame == 0 && !active) || (frame == count - 1 && active))
            return ADCFail(error, capacity, @"Digitizer schedule must start active and end released; no input sent.");
        for (size_t byte = 3 + contacts * 5; byte < 58; byte++)
            if (bytes[byte] != (byte == 40 ? 2 : 0))
                return ADCFail(error, capacity, @"Unsupported digitizer report fields; no input sent.");
    }
    return ADCPerformInput(uuid, version, 0, 0, NO, NULL, NULL, NULL, times, reports, surface, count, error, capacity);
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
    return ADCPerformInput(uuid, version, 0, 0, NO, samples, secondPoints, NULL, NULL, NULL, NULL, count, error, capacity);
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
