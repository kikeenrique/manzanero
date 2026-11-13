#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/socket.h>
#include <string.h>
#include "AppleDeviceBridge.h"

int ADCIsRemotedProcess(int pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return pid > 0 && proc_pidpath(pid, path, sizeof(path)) > 0 && strcmp(path, "/usr/libexec/remoted") == 0;
}

int ADCReadArchiveUID(const void *object, uint64_t *value) {
    CFTypeID (*typeID)(void) = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetTypeID");
    uint32_t (*read)(CFTypeRef) = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetValue");
    if (!object || !value || !typeID || !read) return -1;
    if (CFGetTypeID(object) != typeID()) return 0;
    *value = read(object);
    return 1;
}

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
@property(atomic, copy) NSString *failureText;
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

static NSString *ADCErrorText(xpc_object_t dictionary, const char *key) {
    const char *text = xpc_dictionary_get_string(dictionary, key);
    if (!text) return nil;
    NSString *value = [[NSString alloc] initWithBytes:text length:strnlen(text, 256) encoding:NSUTF8StringEncoding];
    if (!value) return @"<invalid or truncated UTF-8>";
    return [[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}

void ADCDescribeCoreDeviceError(const void *errorDictionary, char *output, size_t capacity) {
    @autoreleasepool {
        xpc_object_t error = errorDictionary ? (__bridge xpc_object_t)errorDictionary : nil;
        NSMutableArray<NSString *> *codes = [NSMutableArray array], *explanations = [NSMutableArray array];
        for (NSUInteger depth = 0; depth < 3 && error && xpc_get_type(error) == XPC_TYPE_DICTIONARY; depth++) {
            NSString *domain = ADCErrorText(error, "domain") ?: @"unknown";
            [codes addObject:[NSString stringWithFormat:@"%@%@ %lld", depth ? @"underlying: " : @"", domain, xpc_dictionary_get_int64(error, "code")]];
            xpc_object_t info = xpc_dictionary_get_dictionary(error, "userInfo");
            // Never enumerate arbitrary error keys or serialize private payloads.
            for (NSString *key in @[@"localizedDescription", @"NSLocalizedDescription", @"NSLocalizedFailureReason", @"NSLocalizedRecoverySuggestion"]) {
                NSString *value = ADCErrorText(error, key.UTF8String);
                if (!value && info) value = ADCErrorText(info, key.UTF8String);
                if (value.length && ![explanations containsObject:value]) [explanations addObject:value];
            }
            xpc_object_t nested = info ? xpc_dictionary_get_dictionary(info, "NSUnderlyingError") : nil;
            if (!nested) nested = xpc_dictionary_get_dictionary(error, "NSUnderlyingError");
            if (!nested) nested = xpc_dictionary_get_dictionary(error, "underlyingError");
            error = nested;
        }
        NSArray<NSString *> *parts = [codes arrayByAddingObjectsFromArray:explanations];
        ADCFail(output, capacity, parts.count ? [parts componentsJoinedByString:@"; "] : @"unknown Apple socket failure");
    }
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

static BOOL ADCValidHardwareUDID(const char *value) {
    if (!value || strnlen(value, 42) > 40) return NO;
    NSString *text = [NSString stringWithUTF8String:value];
    return text.length && [text rangeOfString:@"^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$" options:NSRegularExpressionSearch].length == text.length;
}

int ADCValidateRSDHandshake(const void *message, const char *expectedUDID, uint16_t *axPort,
                            char *error, size_t capacity) {
    @autoreleasepool {
        if (axPort) *axPort = 0;
        xpc_object_t root = message ? (__bridge xpc_object_t)message : nil;
        if (!axPort || !ADCValidHardwareUDID(expectedUDID) || !root || xpc_get_type(root) != XPC_TYPE_DICTIONARY)
            return ADCFail(error, capacity, @"Invalid RSD handshake or expected hardware identity; no AX connection started.");
        const char *type = xpc_dictionary_get_string(root, "MessageType");
        xpc_object_t properties = xpc_dictionary_get_dictionary(root, "Properties");
        const char *hardware = properties ? xpc_dictionary_get_string(properties, "UniqueDeviceID") : NULL;
        if (!type || strcmp(type, "Handshake") || !hardware || !ADCValidHardwareUDID(hardware) || strcasecmp(hardware, expectedUDID))
            return ADCFail(error, capacity, @"RSD handshake did not match the selected hardware identity; no AX connection started.");
        xpc_object_t services = xpc_dictionary_get_dictionary(root, "Services");
        if (!services || xpc_dictionary_get_count(services) > 4096)
            return ADCFail(error, capacity, @"Invalid or oversized RSD service inventory; no AX connection started.");
        xpc_object_t service = xpc_dictionary_get_dictionary(services, "com.apple.accessibility.axAuditDaemon.remoteAXService");
        const char *port = service ? xpc_dictionary_get_string(service, "Port") : NULL;
        xpc_object_t options = service ? xpc_dictionary_get_dictionary(service, "Properties") : NULL;
        xpc_object_t remote = options ? xpc_dictionary_get_value(options, "UsesRemoteXPC") : nil;
        xpc_object_t encrypted = options ? xpc_dictionary_get_value(options, "EncryptSocketData") : nil;
        if (!port || strnlen(port, 6) == 0 || strnlen(port, 6) > 5 ||
            !remote || xpc_get_type(remote) != XPC_TYPE_BOOL || !xpc_bool_get_value(remote) ||
            !encrypted || xpc_get_type(encrypted) != XPC_TYPE_BOOL || xpc_bool_get_value(encrypted))
            return ADCFail(error, capacity, @"AX service lacks a supported advertised port/protocol; no AX connection started.");
        unsigned value = 0;
        for (const char *p = port; *p; p++) {
            if (*p < '0' || *p > '9') return ADCFail(error, capacity, @"Invalid advertised AX service port; no AX connection started.");
            value = value * 10 + (unsigned)(*p - '0');
        }
        if (!value || value > UINT16_MAX) return ADCFail(error, capacity, @"Invalid advertised AX service port; no AX connection started.");
        *axPort = (uint16_t)value;
        return 0;
    }
}

@interface ADCRSDDirectoryOwner : NSObject
@property(nonatomic, strong) id remote;
@property(nonatomic, strong) ADCReplyState *state;
@end
@implementation ADCRSDDirectoryOwner
@end

void ADCCloseRSDDirectory(void *owner) {
    if (!owner) return;
    ADCRSDDirectoryOwner *lifetime = CFBridgingRelease(owner);
    lifetime.state.failed = YES;
    ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
    if (cancel && lifetime.remote) cancel((__bridge ADCRemote)lifetime.remote);
}

int ADCIsRSDDirectoryActive(void *owner) {
    if (!owner) return 0;
    ADCRSDDirectoryOwner *lifetime = (__bridge ADCRSDDirectoryOwner *)owner;
    return lifetime.state && !lifetime.state.failed;
}

int ADCOpenRSDDirectory(int descriptor, const char *expectedUDID, const char *localUUID, uint64_t versionFlags,
                         int (^shouldCancel)(void), uint16_t *axPort, void **owner,
                         char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        if (axPort) *axPort = 0;
        NSUUID *host = localUUID ? [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:localUUID]] : nil;
        int type = 0; socklen_t length = sizeof(type);
        if (!owner || !axPort || !host || !ADCValidHardwareUDID(expectedUDID) || descriptor < 0 ||
            getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) || type != SOCK_STREAM ||
            (shouldCancel && shouldCancel())) {
            if (descriptor >= 0) close(descriptor);
            return ADCFail(error, capacity, @"Invalid or cancelled RSD connection; no handshake started.");
        }
        if (ADCPrepareCoreDevice(error, capacity)) { close(descriptor); return 1; }
        ADCCreate create = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
        ADCHandler handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        ADCActivate activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        ADCSend send = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message");
        if (!create || !handler || !activate || !cancel || !send) {
            close(descriptor);
            return ADCFail(error, capacity, @"Apple RemoteXPC directory interfaces are unavailable.");
        }
        dispatch_queue_t queue = dispatch_queue_create("appledevices.rsd.directory", DISPATCH_QUEUE_SERIAL);
        ADCRemote remote = create(descriptor, queue, versionFlags, 0);
        if (!remote) { close(descriptor); return ADCFail(error, capacity, @"Apple RemoteXPC directory connection creation failed."); }
        ADCRSDDirectoryOwner *lifetime = [ADCRSDDirectoryOwner new];
        lifetime.remote = CFBridgingRelease(remote);
        ADCReplyState *state = [ADCReplyState new];
        lifetime.state = state;
        __block unsigned messages = 0;
        handler(remote, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                const char *description = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
                state.failureText = description ? [[NSString alloc] initWithBytes:description length:strnlen(description, 256) encoding:NSUTF8StringEncoding] : @"RemoteXPC connection error";
                state.failed = YES; dispatch_semaphore_signal(state.semaphore); return;
            }
            if (++messages > 32) {
                state.failureText = @"Unrelated directory message limit exceeded";
                state.failed = YES; dispatch_semaphore_signal(state.semaphore); return;
            }
            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
            const char *kind = xpc_dictionary_get_string(event, "MessageType");
            if (kind && strcmp(kind, "Handshake") == 0 && !state.reply) {
                state.reply = event; dispatch_semaphore_signal(state.semaphore);
            }
        });
        activate(remote);
        xpc_object_t handshake = xpc_dictionary_create_empty(), properties = xpc_dictionary_create_empty();
        uuid_t hostBytes; [host getUUIDBytes:hostBytes];
        xpc_dictionary_set_string(handshake, "MessageType", "Handshake");
        xpc_dictionary_set_uint64(handshake, "MessagingProtocolVersion", 7);
        xpc_dictionary_set_value(handshake, "UUID", xpc_uuid_create(hostBytes));
        xpc_dictionary_set_uint64(properties, "RemoteXPCVersionFlags", versionFlags);
        xpc_dictionary_set_bool(properties, "SensitivePropertiesVisible", YES);
        xpc_dictionary_set_value(handshake, "Properties", properties);
        xpc_dictionary_set_value(handshake, "Services", xpc_dictionary_create_empty());
        send(remote, handshake);
        uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 8ULL * NSEC_PER_SEC;
        BOOL ready = NO;
        while (!(shouldCancel && shouldCancel()) && clock_gettime_nsec_np(CLOCK_MONOTONIC) < deadline) {
            if (!dispatch_semaphore_wait(state.semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC))) { ready = YES; break; }
        }
        if (!ready || state.failed || (shouldCancel && shouldCancel())) {
            cancel(remote);
            return ADCFail(error, capacity, [NSString stringWithFormat:@"RSD directory handshake failed, was cancelled or exceeded its eight-second deadline; no AX connection started. %@", state.failureText ?: @"No native connection error detail."]);
        }
        if (ADCValidateRSDHandshake((__bridge const void *)state.reply, expectedUDID, axPort, error, capacity)) {
            cancel(remote); return 1;
        }
        *owner = (void *)CFBridgingRetain(lifetime);
        return 0;
    }
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
            char details[2048];
            ADCDescribeCoreDeviceError(failure ? (__bridge const void *)failure : NULL, details, sizeof(details));
            xpc_connection_cancel(connection);
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple refused the raw accessibility socket; no accessibility subscription sent. %s", details]);
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

static int ADCOpenRSDAXSocket(const char *remoteUUID, const char *expectedUDID, BOOL browsePresent,
                              void **owner, char *error, size_t capacity) {
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
        id device = nil;
        if (browsePresent) {
            // Installed remotectl browse_present caller: device argument plus
            // nonzero completion flag, delivered on the supplied serial queue.
            void (*browse)(int, dispatch_queue_t, void (^)(id, int)) = dlsym(RTLD_DEFAULT, "remote_device_browse_present");
            void (*copyUUID)(id, unsigned char *) = dlsym(RTLD_DEFAULT, "remote_device_copy_uuid");
            if (!browse || !copyUUID) {
                ADCFail(error, capacity, @"Apple RSD one-shot browser APIs are unavailable.");
                return -1;
            }
            dispatch_queue_t queue = dispatch_queue_create("appledevices.rsd.present", DISPATCH_QUEUE_SERIAL);
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            NSMutableArray *choices = [NSMutableArray new];
            __block BOOL closed = NO;
            browse(expectedType, queue, ^(id candidate, int complete) {
                if (complete) { dispatch_semaphore_signal(finished); return; }
                if (!candidate || deviceType(candidate) != expectedType) return;
                unsigned char bytes[16]; copyUUID(candidate, bytes);
                NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:bytes];
                if ([identifier caseInsensitiveCompare:uuid.UUIDString] != NSOrderedSame) return;
                @synchronized (choices) {
                    if (!closed && choices.count < 2) [choices addObject:candidate];
                }
            });
            BOOL timedOut = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0;
            @synchronized (choices) {
                closed = YES;
                if (!timedOut && choices.count == 1) device = choices.firstObject;
            }
            if (!device) {
                ADCFail(error, capacity, timedOut ? @"Apple RSD one-shot inventory timed out; no service opened." :
                    @"Apple RSD one-shot inventory did not identify exactly one requested UUID; no service opened.");
                return -1;
            }
        } else {
            device = CFBridgingRelease(matching(selection));
        }
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
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple RSD %@ %s inventory (%zu services) did not advertise accessibility to this client; no subscription sent.", browsePresent ? @"one-shot browse" : @"direct lookup", typeName, serviceCount]);
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

int ADCOpenRSDAccessibilitySocket(const char *remoteUUID, const char *expectedUDID, void **owner, char *error, size_t capacity) {
    return ADCOpenRSDAXSocket(remoteUUID, expectedUDID, NO, owner, error, capacity);
}

int ADCOpenBrowsedRSDAccessibilitySocket(const char *remoteUUID, const char *expectedUDID, void **owner, char *error, size_t capacity) {
    return ADCOpenRSDAXSocket(remoteUUID, expectedUDID, YES, owner, error, capacity);
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

static int ADCValidateDigitizerSchedule(const uint64_t *times, const uint8_t *reports,
                                        size_t count, char *error, size_t capacity);
static int ADCValidateTouchSchedule(const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                                    size_t count, char *error, size_t capacity);
static int ADCValidateKeyboardSchedule(const ADCKeyboardSample *samples, size_t count, char *error, size_t capacity);

static BOOL ADCWaitForInput(uint64_t start, uint64_t offset, ADCInputShouldStop shouldStop) {
    uint64_t target = start + offset, now;
    while ((now = ADCNow()) < target) {
        if (shouldStop && shouldStop()) return NO;
        uint64_t remaining = MIN(target - now, 10ULL * NSEC_PER_MSEC);
        struct timespec wait = { 0, (long)remaining };
        nanosleep(&wait, NULL);
    }
    return !shouldStop || !shouldStop();
}

int ADCRunTouchSchedule(const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, size_t count,
                        ADCInputShouldStop shouldStop, ADCTouchSink sendSample) {
    if (!sendSample || ADCValidateTouchSchedule(samples, secondPoints, count, NULL, 0)) return 2;
    uint64_t start = ADCNow();
    size_t last = 0;
    BOOL attempted = NO, stopped = NO;
    for (size_t i = 0; i < count; i++) {
        if (!ADCWaitForInput(start, samples[i].nanoseconds, shouldStop)) { stopped = YES; break; }
        attempted = YES; last = i;
        sendSample(&samples[i], secondPoints ? &secondPoints[i] : NULL);
    }
    if (attempted && samples[last].phase != 2) {
        ADCTouchSample release = samples[last]; release.phase = 2;
        sendSample(&release, secondPoints ? &secondPoints[last] : NULL);
    }
    return stopped || (shouldStop && shouldStop()) ? 1 : 0;
}

int ADCRunKeyboardSchedule(const ADCKeyboardSample *samples, size_t count,
                           ADCInputShouldStop shouldStop, ADCKeySink sendKey) {
    if (!sendKey || ADCValidateKeyboardSchedule(samples, count, NULL, 0)) return 2;
    BOOL pressed[256] = {NO}, stopped = NO;
    uint64_t start = ADCNow();
    for (size_t i = 0; i < count; i++) {
        if (!ADCWaitForInput(start, samples[i].nanoseconds, shouldStop)) { stopped = YES; break; }
        pressed[samples[i].usage] = samples[i].state == 1;
        sendKey(samples[i].usage, samples[i].state);
    }
    // Ordinary keys precede modifiers in this supported usage set. Cancellation
    // and transport failure must not suppress release of an attempted down.
    for (size_t usage = 0; usage < 256; usage++)
        if (pressed[usage]) sendKey(usage, 2);
    return stopped || (shouldStop && shouldStop()) ? 1 : 0;
}

int ADCRunPress(uint64_t usage, unsigned hold, ADCInputShouldStop shouldStop, ADCKeySink sendKey) {
    BOOL supported = usage == 64 || usage == 48 || usage == 233 || usage == 234 ||
        (usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82);
    if (!sendKey || !supported || hold > 400000) return 2;
    if (shouldStop && shouldStop()) return 1;
    sendKey(usage, 1);
    uint64_t start = ADCNow();
    BOOL completed = ADCWaitForInput(start, (uint64_t)hold * 1000, shouldStop);
    sendKey(usage, 2);
    return !completed || (shouldStop && shouldStop()) ? 1 : 0;
}

int ADCRunDigitizerSchedule(const uint64_t *times, const uint8_t *reports, size_t count,
                            ADCInputShouldStop shouldStop, ADCDigitizerSink sendReport) {
    if (!sendReport || ADCValidateDigitizerSchedule(times, reports, count, NULL, 0)) return 2;
    uint64_t start = ADCNow();
    size_t last = 0;
    BOOL attempted = NO, stopped = NO;
    for (size_t i = 0; i < count; i++) {
        if (!ADCWaitForInput(start, times[i], shouldStop)) { stopped = YES; break; }
        attempted = YES; last = i;
        sendReport(reports + i * 58);
    }
    if (attempted) {
        uint8_t release[58]; memcpy(release, reports + last * 58, 58);
        BOOL active = NO;
        for (size_t id = 0; id < release[1]; id++) {
            if (release[3 + id * 5] & 0xc0) active = YES;
            release[3 + id * 5] = (uint8_t)id;
        }
        // Cancellation must never suppress this final best-effort release.
        if (active) sendReport(release);
    }
    return stopped || (shouldStop && shouldStop()) ? 1 : 0;
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
                   const uint64_t *reportTimes, const uint8_t *reports, uint64_t *resolvedSurface, size_t count,
                   ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    @autoreleasepool {
        if (shouldCancel && shouldCancel()) return ADCFail(error, capacity, @"Input cancelled before transport setup; no input sent.");
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
        // Every input mode, including plain consumer buttons, must receive the
        // service's readiness fence before its first down event. Activation
        // alone does not establish that the remote HID service is ready.
        {
            ADCReplyState *ready = [ADCReplyState new];
            xpc_object_t barrier = reports ? ADCUniversalBarrier() : (samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES));
            request(remote, barrier, queue, ^(xpc_object_t response) {
                ready.reply = response;
                dispatch_semaphore_signal(ready.semaphore);
            });
            BOOL timeout = dispatch_semaphore_wait(ready.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
            if (timeout || status.failed || !ADCValidHIDReply(ready.reply)) {
                cancel(remote); xpc_connection_cancel(connection);
                return ADCFail(error, capacity, @"Apple HID service did not become ready; no input sent.");
            }
        }
        BOOL scheduleStopped = NO;
        if (reports) {
            scheduleStopped = ADCRunDigitizerSchedule(reportTimes, reports, count,
                ^int { return status.failed || (shouldCancel && shouldCancel()); },
                ^(const uint8_t *bytes) { send(remote, ADCUniversalReport(bytes, surface)); }) != 0;
        } else if (samples) {
            scheduleStopped = ADCRunTouchSchedule(samples, secondPoints, count,
                ^int { return status.failed || (shouldCancel && shouldCancel()); },
                ^(const ADCTouchSample *sample, const ADCTouchPoint *second) {
                    send(remote, ADCTouchEvent(sample->x, sample->y, second, sample->phase, NO));
                }) != 0;
        } else if (keys) {
            scheduleStopped = ADCRunKeyboardSchedule(keys, count,
                ^int { return status.failed || (shouldCancel && shouldCancel()); },
                ^(uint64_t code, uint64_t state) { send(remote, ADCKeyboardEvent(code, state, NO)); }) != 0;
        } else {
            scheduleStopped = ADCRunPress(usage, hold,
                ^int { return status.failed || (shouldCancel && shouldCancel()); },
                ^(uint64_t code, uint64_t state) { send(remote, scalarEvent(code, state, NO)); }) != 0;
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
        if (scheduleStopped || (shouldCancel && shouldCancel()))
            return ADCFail(error, capacity, @"Input stopped after cancellation or transport failure; release was attempted for active contacts or keys. UI effect and device-side release are unverified; do not replay automatically.");
        if (failed) return ADCFail(error, capacity, @"Input was attempted, but the Apple service barrier was not confirmed. UI effect and release are unknown; do not replay automatically.");
        if (resolvedSurface) *resolvedSurface = surface;
        return 0;
    }
}

int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if ((usage != 64 && usage != 48 && usage != 233 && usage != 234) || hold > 400000)
        return ADCFail(error, capacity, @"Invalid direct button request.");
    return ADCPerformInput(uuid, version, usage, hold, NO, NULL, NULL, NULL, NULL, NULL, NULL, 0, shouldCancel, error, capacity);
}

int ADCPressKeyboardKey(const char *uuid, const char *version, uint64_t usage, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!((usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82)))
        return ADCFail(error, capacity, @"Unsupported direct keyboard usage; no input sent.");
    return ADCPerformInput(uuid, version, usage, 80000, YES, NULL, NULL, NULL, NULL, NULL, NULL, 0, shouldCancel, error, capacity);
}

int ADCPerformKeyboard(const char *uuid, const char *version, const ADCKeyboardSample *samples,
                       size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateKeyboardSchedule(samples, count, error, capacity)) return 1;
    return ADCPerformInput(uuid, version, 0, 0, YES, NULL, NULL, samples, NULL, NULL, NULL, count, shouldCancel, error, capacity);
}

static int ADCValidateKeyboardSchedule(const ADCKeyboardSample *samples, size_t count, char *error, size_t capacity) {
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
    return 0;
}

int ADCPerformDigitizerReports(const char *uuid, const char *version, const uint64_t *times,
                              const uint8_t *reports, size_t count, uint64_t *surface, char *error, size_t capacity) {
    return ADCPerformCancellableDigitizerReports(uuid, version, times, reports, count, nil, surface, error, capacity);
}

int ADCPerformCancellableDigitizerReports(const char *uuid, const char *version, const uint64_t *times,
                              const uint8_t *reports, size_t count, ADCInputShouldStop shouldCancel,
                              uint64_t *surface, char *error, size_t capacity) {
    if (surface) *surface = 0;
    if (ADCValidateDigitizerSchedule(times, reports, count, error, capacity)) return 1;
    return ADCPerformInput(uuid, version, 0, 0, NO, NULL, NULL, NULL, times, reports, surface, count, shouldCancel, error, capacity);
}

static int ADCValidateDigitizerSchedule(const uint64_t *times, const uint8_t *reports,
                                        size_t count, char *error, size_t capacity) {
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
    return 0;
}

static int ADCValidateAndPerformTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    const ADCTouchPoint *secondPoints, size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateTouchSchedule(samples, secondPoints, count, error, capacity)) return 1;
    return ADCPerformInput(uuid, version, 0, 0, NO, samples, secondPoints, NULL, NULL, NULL, NULL, count, shouldCancel, error, capacity);
}

static int ADCValidateTouchSchedule(const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                                    size_t count, char *error, size_t capacity) {
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
    return 0;
}

int ADCPerformTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    return ADCValidateAndPerformTouch(uuid, version, samples, NULL, count, shouldCancel, error, capacity);
}

int ADCPerformTwoContactTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    const ADCTouchPoint *secondPoints, size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!secondPoints) return ADCFail(error, capacity, @"Missing second contact; no input sent.");
    return ADCValidateAndPerformTouch(uuid, version, samples, secondPoints, count, shouldCancel, error, capacity);
}
