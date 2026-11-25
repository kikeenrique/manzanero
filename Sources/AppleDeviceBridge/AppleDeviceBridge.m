#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <Network/Network.h>
#include <netinet/in.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/socket.h>
#include <string.h>
#include "AppleDeviceBridge.h"
#include "AppleDeviceBridgeInternal.h"
#import "AppleMediaControl.h"

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
// Protocol references: docs/axe-physical-review.md and docs/native-input.md.
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
@property(atomic) BOOL finished;
@end
@implementation ADCReplyState
- (instancetype)init { if ((self = [super init])) _semaphore = dispatch_semaphore_create(0); return self; }
@end

static int ADCFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String);
    return 1;
}

/// The same message for a failure after input was attempted, distinguished by status.
static int ADCFailAfterInput(char *error, size_t capacity, NSString *message) {
    ADCFail(error, capacity, message);
    return ADCInputOutcomeUnknown;
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

static xpc_object_t ADCMercuryMessage(const char *type, xpc_object_t value) {
    xpc_object_t message = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "mangledTypeName", type);
    xpc_dictionary_set_value(message, "value", value);
    return message;
}

static BOOL ADCWaitForReply(ADCReplyState *state, uint64_t deadline, int (^cancelled)(void)) {
    while (!(cancelled && cancelled()) && clock_gettime_nsec_np(CLOCK_MONOTONIC) < deadline) {
        if (!dispatch_semaphore_wait(state.semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC))) return YES;
    }
    return NO;
}

int ADCValidateTunnelAssertionReply(const void *reply, char *address, size_t addressCapacity,
                                    char *error, size_t capacity) {
    if (address && addressCapacity) address[0] = 0;
    xpc_object_t root = reply ? (__bridge xpc_object_t)reply : nil;
    if (!address || !addressCapacity || !root || xpc_get_type(root) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(root, "error"))
        return ADCFail(error, capacity, @"Apple tunnel assertion reply failed or was malformed; acquisition outcome may be unknown.");
    xpc_object_t response = xpc_dictionary_get_dictionary(root, "response");
    xpc_object_t token = response ? xpc_dictionary_get_value(response, "assertionIdentifier") : nil;
    xpc_object_t info = response ? xpc_dictionary_get_dictionary(response, "info") : nil;
    const char *ip = info ? xpc_dictionary_get_string(info, "tunnelIPAddress") : NULL;
    if (!token || xpc_get_type(token) != XPC_TYPE_UUID || !ip || !*ip || strnlen(ip, 128) >= 128 || strlen(ip) >= addressCapacity)
        return ADCFail(error, capacity, @"Apple tunnel assertion omitted its opaque UUID or bounded address; acquisition outcome may be unknown.");
    memcpy(address, ip, strlen(ip) + 1);
    return 0;
}

@interface ADCNativeTunnelOwner : NSObject
@property(nonatomic, strong) xpc_connection_t browse;
@property(nonatomic, strong) xpc_connection_t device;
@property(nonatomic, strong) xpc_object_t assertion;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@implementation ADCNativeTunnelOwner
@end

int ADCCloseNativeTunnelAssertion(void *owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (!owner) return 0;
        ADCNativeTunnelOwner *lifetime = CFBridgingRelease(owner);
        BOOL confirmed = lifetime.assertion == nil;
        if (lifetime.assertion && lifetime.device) {
            xpc_object_t value = xpc_dictionary_create_empty();
            xpc_dictionary_set_value(value, "assertionIdentifier", lifetime.assertion);
            ADCReplyState *state = [ADCReplyState new];
            xpc_connection_send_message_with_reply(lifetime.device, ADCMercuryMessage("RemotePairing.ReleaseAssertionRequest", value), lifetime.queue, ^(xpc_object_t reply) {
                state.reply = reply; dispatch_semaphore_signal(state.semaphore);
            });
            BOOL ready = ADCWaitForReply(state, clock_gettime_nsec_np(CLOCK_MONOTONIC) + 2ULL * NSEC_PER_SEC, nil);
            xpc_object_t reply = state.reply;
            confirmed = ready && reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
                !xpc_dictionary_get_value(reply, "error") && xpc_dictionary_get_value(reply, "response");
        }
        if (lifetime.device) xpc_connection_cancel(lifetime.device);
        if (lifetime.browse) xpc_connection_cancel(lifetime.browse);
        return confirmed ? 0 : ADCFail(error, capacity, @"Apple tunnel assertion release was not acknowledged; owned connections closed, remote cleanup unconfirmed.");
    }
}

int ADCOpenNativeTunnelAssertion(const char *expectedUDID, int (^shouldCancel)(void),
                                 char *address, size_t addressCapacity, void **owner,
                                 char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        if (address && addressCapacity) address[0] = 0;
        if (!owner || !address || addressCapacity < 2 || !ADCValidHardwareUDID(expectedUDID) || (shouldCancel && shouldCancel()))
            return ADCFail(error, capacity, @"Invalid or cancelled tunnel assertion target; no pairing-daemon request sent.");
        NSString *hardware = [NSString stringWithUTF8String:expectedUDID];
        ADCNativeTunnelOwner *lifetime = [ADCNativeTunnelOwner new];
        lifetime.queue = dispatch_queue_create("manzanero.native-tunnel", DISPATCH_QUEUE_SERIAL);
        lifetime.browse = xpc_connection_create_mach_service("com.apple.CoreDevice.remotepairingd", lifetime.queue, 0);
        if (!lifetime.browse) return ADCFail(error, capacity, @"Cannot create Apple pairing-daemon connection; no assertion requested.");
        ADCReplyState *selection = [ADCReplyState new];
        __block unsigned events = 0;
        // Diagnostic only: which of the browse's failure modes occurred.
        __block NSString *reason = nil;
        // A browse connection error before any endpoint was selected. Nothing
        // has been asked of the device yet, so the caller may browse again.
        __block BOOL interrupted = NO;
        xpc_connection_set_event_handler(lifetime.browse, ^(xpc_object_t event) {
            @synchronized(selection) {
                if (selection.finished) return;
                // Once the endpoint is in hand, the browse stream ending is not
                // a failure; it used to race the waiter and discard the endpoint.
                if (xpc_get_type(event) == XPC_TYPE_ERROR && selection.reply && !selection.failed) return;
                if (xpc_get_type(event) == XPC_TYPE_ERROR || ++events > 256) {
                    if (!reason) {
                        interrupted = xpc_get_type(event) == XPC_TYPE_ERROR;
                        reason = interrupted ? @"the browse connection reported an error" : @"more than 256 browse events arrived";
                    }
                    selection.failed = YES; dispatch_semaphore_signal(selection.semaphore); return;
                }
                if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
                xpc_object_t value = xpc_dictionary_get_dictionary(event, "value");
                xpc_object_t found = value ? xpc_dictionary_get_dictionary(value, "deviceFound") : nil;
                xpc_object_t payload = found ? xpc_dictionary_get_dictionary(found, "_0") : nil;
                xpc_object_t info = payload ? xpc_dictionary_get_dictionary(payload, "deviceInfo") : nil;
                const char *udid = info ? xpc_dictionary_get_string(info, "udid") : NULL;
                if (!udid || !ADCValidHardwareUDID(udid) || strcasecmp(udid, hardware.UTF8String)) return;
                xpc_object_t endpoint = xpc_dictionary_get_value(info, "endpoint");
                if (!endpoint || xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT || selection.reply) {
                    if (!reason) reason = selection.reply ? @"the device was announced more than once" : @"the device was announced without a usable endpoint";
                    selection.failed = YES;
                }
                else selection.reply = endpoint;
                dispatch_semaphore_signal(selection.semaphore);
            }
        });
        xpc_connection_resume(lifetime.browse);
        xpc_object_t options = xpc_dictionary_create_empty();
        xpc_dictionary_set_bool(options, "currentDevicesOnly", YES);
        xpc_connection_send_message_with_reply(lifetime.browse, ADCMercuryMessage("RemotePairing.BrowseRequest", options), lifetime.queue, ^(xpc_object_t reply) {
            if (xpc_get_type(reply) == XPC_TYPE_ERROR || (xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_value(reply, "error"))) {
                @synchronized(selection) {
                    if (!selection.finished) {
                        if (!reason) reason = @"the browse request was refused";
                        selection.failed = YES; dispatch_semaphore_signal(selection.semaphore);
                    }
                }
            }
        });
        uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 12ULL * NSEC_PER_SEC;
        BOOL selected = ADCWaitForReply(selection, deadline, shouldCancel);
        xpc_object_t endpoint;
        NSString *cause;
        BOOL retryable;
        @synchronized(selection) {
            selection.finished = YES;
            endpoint = selected && !selection.failed ? selection.reply : nil;
            cause = reason ?: (selected ? @"no endpoint was selected" : @"the device was not announced in time");
            retryable = interrupted;
        }
        if (!endpoint || (shouldCancel && shouldCancel())) {
            xpc_connection_cancel(lifetime.browse);
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple pairing daemon did not select the exact hardware endpoint within the bounded browse (%@); no assertion or pairing requested.", cause]);
            return retryable && !(shouldCancel && shouldCancel()) ? ADCTunnelBrowseInterrupted : 1;
        }
        lifetime.device = xpc_connection_create_from_endpoint(endpoint);
        if (!lifetime.device) {
            xpc_connection_cancel(lifetime.browse);
            return ADCFail(error, capacity, @"Cannot create selected pairing-daemon endpoint connection; no assertion requested.");
        }
        xpc_connection_set_target_queue(lifetime.device, lifetime.queue);
        xpc_connection_set_event_handler(lifetime.device, ^(xpc_object_t event) {});
        xpc_connection_resume(lifetime.device);
        xpc_object_t flags = xpc_dictionary_create_empty();
        xpc_dictionary_set_int64(flags, "flags", 0);
        ADCReplyState *assertion = [ADCReplyState new];
        xpc_connection_send_message_with_reply(lifetime.device, ADCMercuryMessage("RemotePairing.CreateAssertionCommand", flags), lifetime.queue, ^(xpc_object_t reply) {
            assertion.reply = reply; dispatch_semaphore_signal(assertion.semaphore);
        });
        BOOL received = ADCWaitForReply(assertion, deadline, shouldCancel);
        xpc_object_t reply = assertion.reply;
        xpc_object_t response = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "response") : nil;
        xpc_object_t token = response ? xpc_dictionary_get_value(response, "assertionIdentifier") : nil;
        if (token && xpc_get_type(token) == XPC_TYPE_UUID) lifetime.assertion = token;
        if (!received || ADCValidateTunnelAssertionReply((__bridge const void *)reply, address, addressCapacity, error, capacity) || (shouldCancel && shouldCancel())) {
            if (!received) ADCFail(error, capacity, @"Apple assertion acquisition cancelled or timed out; its remote outcome may be unknown. Owned connections will close.");
            else if (shouldCancel && shouldCancel()) ADCFail(error, capacity, @"Apple assertion acquisition cancelled after reply; release attempted.");
            char cleanup[512] = {0};
            if (ADCCloseNativeTunnelAssertion((void *)CFBridgingRetain(lifetime), cleanup, sizeof(cleanup))) {
                NSString *original = error && capacity ? [NSString stringWithUTF8String:error] : @"Assertion acquisition failed";
                ADCFail(error, capacity, [NSString stringWithFormat:@"%@ %s", original, cleanup]);
            }
            if (addressCapacity) address[0] = 0;
            return 1;
        }
        *owner = (void *)CFBridgingRetain(lifetime);
        return 0;
    }
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
@property(nonatomic, strong) nw_connection_t network;
@end
@implementation ADCRSDDirectoryOwner
@end

void ADCCloseRSDDirectory(void *owner) {
    if (!owner) return;
    ADCRSDDirectoryOwner *lifetime = CFBridgingRelease(owner);
    lifetime.state.failed = YES;
    ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
    if (cancel && lifetime.remote) cancel((__bridge ADCRemote)lifetime.remote);
    if (lifetime.network) nw_connection_cancel(lifetime.network);
}

int ADCIsRSDDirectoryActive(void *owner) {
    if (!owner) return 0;
    ADCRSDDirectoryOwner *lifetime = (__bridge ADCRSDDirectoryOwner *)owner;
    return lifetime.state && !lifetime.state.failed;
}

int ADCCopyRSDShimServicePort(void *owner, const char *serviceName, uint16_t *port, char *error, size_t capacity) {
    @autoreleasepool {
        if (port) *port = 0;
        ADCRSDDirectoryOwner *lifetime = owner ? (__bridge ADCRSDDirectoryOwner *)owner : nil;
        xpc_object_t root = lifetime.state && !lifetime.state.failed ? lifetime.state.reply : nil;
        size_t length = serviceName ? strnlen(serviceName, 257) : 0;
        static const char suffix[] = ".shim.remote";
        if (!port || !root || xpc_get_type(root) != XPC_TYPE_DICTIONARY || length <= sizeof(suffix) - 1 || length > 256 ||
            strcmp(serviceName + length - (sizeof(suffix) - 1), suffix))
            return ADCFail(error, capacity, @"Invalid RSD directory or shim service name; no service connection started.");
        xpc_object_t services = xpc_dictionary_get_dictionary(root, "Services");
        xpc_object_t service = services ? xpc_dictionary_get_dictionary(services, serviceName) : NULL;
        const char *text = service ? xpc_dictionary_get_string(service, "Port") : NULL;
        xpc_object_t options = service ? xpc_dictionary_get_dictionary(service, "Properties") : NULL;
        xpc_object_t remote = options ? xpc_dictionary_get_value(options, "UsesRemoteXPC") : nil;
        xpc_object_t encrypted = options ? xpc_dictionary_get_value(options, "EncryptSocketData") : nil;
        // A shim is the opposite of the AX service: not RemoteXPC, and its
        // socket carries the lockdown-style plist protocol unencrypted.
        if (!text || strnlen(text, 6) == 0 || strnlen(text, 6) > 5 ||
            !remote || xpc_get_type(remote) != XPC_TYPE_BOOL || xpc_bool_get_value(remote) ||
            !encrypted || xpc_get_type(encrypted) != XPC_TYPE_BOOL || xpc_bool_get_value(encrypted))
            return ADCFail(error, capacity, @"The shim service is not advertised with a port as a plain, unencrypted service; no service connection started.");
        unsigned value = 0;
        for (const char *p = text; *p; p++) {
            if (*p < '0' || *p > '9') return ADCFail(error, capacity, @"Invalid advertised shim service port; no service connection started.");
            value = value * 10 + (unsigned)(*p - '0');
        }
        if (!value || value > UINT16_MAX) return ADCFail(error, capacity, @"Invalid advertised shim service port; no service connection started.");
        *port = (uint16_t)value;
        return 0;
    }
}

static int ADCCompleteRSDDirectory(ADCRSDDirectoryOwner *lifetime, const char *expectedUDID, NSUUID *host, uint64_t versionFlags,
                         int (^shouldCancel)(void), uint16_t *axPort, void **owner,
                         char *error, size_t capacity) {
    @autoreleasepool {
        ADCRemote remote = (__bridge ADCRemote)lifetime.remote;
        ADCHandler handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        ADCActivate activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        ADCSend send = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message");
        if (!handler || !activate || !send) {
            ADCCloseRSDDirectory((void *)CFBridgingRetain(lifetime));
            return ADCFail(error, capacity, @"Apple RemoteXPC directory interfaces are unavailable.");
        }
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
            ADCCloseRSDDirectory((void *)CFBridgingRetain(lifetime));
            return ADCFail(error, capacity, [NSString stringWithFormat:@"RSD directory handshake failed, was cancelled or exceeded its eight-second deadline; no AX connection started. %@", state.failureText ?: @"No native connection error detail."]);
        }
        if (ADCValidateRSDHandshake((__bridge const void *)state.reply, expectedUDID, axPort, error, capacity)) {
            ADCCloseRSDDirectory((void *)CFBridgingRetain(lifetime)); return 1;
        }
        *owner = (void *)CFBridgingRetain(lifetime);
        return 0;
    }
}

int ADCOpenRSDDirectoryNetwork(const void *address, size_t addressLength, const char *expectedUDID,
                               const char *localUUID, uint64_t advertisedVersionFlags,
                               int (^shouldCancel)(void), uint16_t *axPort, void **owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        if (axPort) *axPort = 0;
        NSUUID *host = localUUID ? [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:localUUID]] : nil;
        const struct sockaddr_in6 *target = address;
        if (!owner || !axPort || !host || !ADCValidHardwareUDID(expectedUDID) || !target || addressLength != sizeof(*target) ||
            target->sin6_len != sizeof(*target) || target->sin6_family != AF_INET6 || target->sin6_port == 0 || (shouldCancel && shouldCancel()))
            return ADCFail(error, capacity, @"Invalid or cancelled Network RSD target; no connection created.");
        if (ADCPrepareCoreDevice(error, capacity)) return 1;
        ADCRemote (*create)(nw_connection_t, dispatch_queue_t, uint64_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_nw_connection");
        void (*configure)(nw_parameters_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_remote_connection_setup_nw_parameters");
        uint64_t (*failsafe)(void) = dlsym(RTLD_DEFAULT, "xpc_remote_connection_get_failsafe_version_flags");
        ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        if (!create || !configure || !failsafe || !cancel) return ADCFail(error, capacity, @"Apple Network RSD bootstrap APIs are unavailable.");
        nw_endpoint_t endpoint = nw_endpoint_create_address((const struct sockaddr *)target);
        // Match Apple's lower TCP construction. No certificate check is
        // overridden; a separately required RemoteXPC TLS setup remains distinct.
        nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        if (!endpoint || !parameters) return ADCFail(error, capacity, @"Cannot create Apple Network endpoint/parameters.");
        nw_parameters_set_local_only(parameters, false);
        configure(parameters, 2);
        nw_connection_t network = nw_connection_create(endpoint, parameters);
        if (!network) return ADCFail(error, capacity, @"Cannot create Apple Network directory connection.");
        dispatch_queue_t queue = dispatch_queue_create("manzanero.rsd.network", DISPATCH_QUEUE_SERIAL);
        ADCRemote remote = create(network, queue, failsafe(), 2);
        if (!remote) { nw_connection_cancel(network); return ADCFail(error, capacity, @"Cannot create Apple Network RemoteXPC directory connection."); }
        ADCRSDDirectoryOwner *lifetime = [ADCRSDDirectoryOwner new];
        lifetime.remote = CFBridgingRelease(remote);
        lifetime.network = network;
        return ADCCompleteRSDDirectory(lifetime, expectedUDID, host, advertisedVersionFlags, shouldCancel, axPort, owner, error, capacity);
    }
}

void ADCCloseAccessibilitySocket(int descriptor) {
    if (descriptor >= 0) close(descriptor);
}

xpc_object_t ADCButtonEvent(uint64_t usage, uint64_t state, BOOL barrier) {
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

/// A watch button's page and usage packed into one code, so the shared press
/// (ADCRunPress) and barrier carry it: the page in the upper 32 bits.
#define ADCWatchSideButton ((12ULL << 32) | 0x95)
#define ADCWatchActionButton ((0xFF01ULL << 32) | 0x200)

/// ADCButtonEvent with the page taken from a packed code; a plain usage stays
/// on the consumer page.
static xpc_object_t ADCPagedButtonEvent(uint64_t code, uint64_t state, BOOL barrier) {
    xpc_object_t event = ADCButtonEvent(code & 0xFFFFFFFF, state, barrier);
    if (!barrier && code >> 32)
        xpc_dictionary_set_uint64(xpc_dictionary_get_value(event, "payload"), "usagePage", code >> 32);
    return event;
}

/// A Digital Crown step on the scroll service, as on a watchOS simulator
/// (AppleSimulatorBridge.m): point {0, delta, 0}, phase 0, momentum 0,
/// target 0 (the crown). A barrier carries no payload.
static xpc_object_t ADCCrownEvent(double delta, BOOL barrier) {
    xpc_object_t event = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(event, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.scroll");
    xpc_dictionary_set_string(event, "messageType", "IndigoScrollEvent");
    xpc_dictionary_set_bool(event, "isBarrier", barrier);
    if (!barrier) {
        xpc_object_t payload = xpc_dictionary_create_empty(), point = xpc_dictionary_create_empty();
        xpc_dictionary_set_double(point, "x", 0);
        xpc_dictionary_set_double(point, "y", delta);
        xpc_dictionary_set_double(point, "z", 0);
        xpc_dictionary_set_value(payload, "point", point);
        xpc_dictionary_set_uint64(payload, "phase", 0);
        xpc_dictionary_set_uint64(payload, "momentum", 0);
        xpc_dictionary_set_uint64(payload, "target", 0);
        xpc_dictionary_set_value(event, "payload", payload);
    }
    return event;
}

xpc_object_t ADCKeyboardEvent(uint64_t usage, uint64_t state, BOOL barrier) {
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

xpc_object_t ADCTouchEvent(double x, double y, const ADCTouchPoint *second, uint64_t phase, BOOL barrier) {
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

int ADCValidateDigitizerSchedule(const uint64_t *times, const uint8_t *reports,
                                        size_t count, char *error, size_t capacity);

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
        usage == ADCWatchSideButton || usage == ADCWatchActionButton ||
        (usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82);
    if (!sendKey || !supported || hold > 400000) return 2;
    if (shouldStop && shouldStop()) return 1;
    sendKey(usage, 1);
    uint64_t start = ADCNow();
    BOOL completed = ADCWaitForInput(start, (uint64_t)hold * 1000, shouldStop);
    sendKey(usage, 2);
    return !completed || (shouldStop && shouldStop()) ? 1 : 0;
}

/// Releases every active contact of the last report sent, once: each
/// contact keeps its position and loses its touch and range flags.
/// Cancellation must never suppress this final best-effort release.
static void ADCReleaseDigitizerContacts(const uint8_t *last, ADCDigitizerSink sendReport) {
    uint8_t release[58]; memcpy(release, last, 58);
    BOOL active = NO;
    for (size_t id = 0; id < release[1]; id++) {
        if (release[3 + id * 5] & 0xc0) active = YES;
        release[3 + id * 5] = (uint8_t)id;
    }
    if (active) sendReport(release);
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
    if (attempted) ADCReleaseDigitizerContacts(reports + last * 58, sendReport);
    return stopped || (shouldStop && shouldStop()) ? 1 : 0;
}

int ADCRunLiveDigitizer(ADCDigitizerProvider next, ADCInputShouldStop shouldStop, ADCDigitizerSink sendReport) {
    if (!next || !sendReport) return 2;
    uint8_t last[58] = {0};
    BOOL attempted = NO, stopped = NO, invalid = NO;
    uint64_t start = ADCNow();
    for (;;) {
        if ((shouldStop && shouldStop()) || ADCNow() - start > ADCLiveDigitizerMaximumNanoseconds) { stopped = YES; break; }
        uint8_t report[58] = {0};
        uint64_t delay = 0;
        int kind = next(report, &delay);
        if (kind == ADCLiveDigitizerEnd) break;
        if ((kind != ADCLiveDigitizerSend && kind != ADCLiveDigitizerIdle) || delay > ADCLiveDigitizerMaximumDelayNanoseconds) {
            invalid = YES; break;
        }
        if (!ADCWaitForInput(ADCNow(), delay, shouldStop)) { stopped = YES; break; }
        if (kind == ADCLiveDigitizerIdle) continue;
        if (ADCValidateDigitizerReport(report, attempted ? last : NULL, NULL, 0) ||
            (!attempted && !ADCDigitizerReportActive(report))) { invalid = YES; break; }
        sendReport(report);
        memcpy(last, report, 58);
        attempted = YES;
    }
    if (attempted) ADCReleaseDigitizerContacts(last, sendReport);
    if (invalid) return attempted ? 3 : 2;
    return stopped || (shouldStop && shouldStop()) ? 1 : 0;
}

xpc_object_t ADCUniversalRequest(const char *operation, xpc_object_t arguments) {
    xpc_object_t message = xpc_dictionary_create_empty(), payload = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "messageType", "Request");
    xpc_dictionary_set_string(message, "featureIdentifier", "com.apple.coredevice.feature.remote.universalhidservice");
    xpc_dictionary_set_value(payload, operation, arguments);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

xpc_object_t ADCUniversalReport(const uint8_t *bytes, uint64_t surface) {
    xpc_object_t arguments = xpc_dictionary_create_empty();
    xpc_dictionary_set_data(arguments, "_0", bytes, 58);
    xpc_dictionary_set_uint64(arguments, "_1", surface);
    return ADCUniversalRequest("send", arguments);
}

xpc_object_t ADCRemoteTouchCreateRequest(void) {
    // A HID service description, in the shape connectedServices lists
    // them. The daemon refuses one without a primary usage.
    xpc_object_t description = xpc_dictionary_create_empty(), pairs = xpc_array_create_empty(), pair = xpc_dictionary_create_empty();
    xpc_dictionary_set_int64(pair, "DeviceUsagePage", 13);
    xpc_dictionary_set_int64(pair, "DeviceUsage", 5);
    xpc_array_append_value(pairs, pair);
    xpc_dictionary_set_uint64(description, "_ServiceID", ADCRemoteTouchServiceID);
    xpc_dictionary_set_uint64(description, "PrimaryUsagePage", 13);
    xpc_dictionary_set_uint64(description, "PrimaryUsage", 5);
    xpc_dictionary_set_string(description, "Product", "Manzanero remote touch surface");
    xpc_dictionary_set_value(description, "DeviceUsagePairs", pairs);
    xpc_object_t arguments = xpc_dictionary_create_empty();
    xpc_dictionary_set_value(arguments, "_0", description);
    return ADCUniversalRequest("createService", arguments);
}

BOOL ADCRemoteTouchCreated(xpc_object_t reply) {
    return reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
        !xpc_dictionary_get_value(reply, "error") && !xpc_dictionary_get_value(reply, "errorContainer") &&
        !xpc_dictionary_get_value(reply, "CoreDevice.error") &&
        xpc_dictionary_get_uint64(reply, "serviceID") == ADCRemoteTouchServiceID;
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

static BOOL ADCMediaUInt(xpc_object_t value, uint64_t *number) {
    if (!value) return NO;
    if (xpc_get_type(value) == XPC_TYPE_UINT64) { *number = xpc_uint64_get_value(value); return YES; }
    if (xpc_get_type(value) == XPC_TYPE_INT64 && xpc_int64_get_value(value) >= 0) { *number = (uint64_t)xpc_int64_get_value(value); return YES; }
    return NO;
}

int ADCValidateMediaInspection(const void *supportReply, const void *statusReply,
                               ADCMediaInspection *result, char *error, size_t capacity) {
    if (result) memset(result, 0, sizeof(*result));
    xpc_object_t support = supportReply ? (__bridge xpc_object_t)supportReply : nil;
    xpc_object_t status = statusReply ? (__bridge xpc_object_t)statusReply : nil;
    if (!result || !ADCValidHIDReply(support) || !ADCValidHIDReply(status))
        return ADCFail(error, capacity, @"Media inspection reply failed or is not a successful dictionary.");
    xpc_object_t capabilities = xpc_dictionary_get_dictionary(support, "CoreDevice.output");
    xpc_object_t state = xpc_dictionary_get_dictionary(status, "CoreDevice.output");
    xpc_object_t features = capabilities ? xpc_dictionary_get_value(capabilities, "supportedFeatures") : nil;
    const char *version = capabilities ? xpc_dictionary_get_string(capabilities, "avcFrameworkVersion") : NULL;
    xpc_object_t running = state ? xpc_dictionary_get_value(state, "running") : nil;
    xpc_object_t sessions = state ? xpc_dictionary_get_array(state, "sessions") : nil;
    xpc_object_t duration = state ? xpc_dictionary_get_value(state, "runDurationSeconds") : nil;
    uint64_t flags = 0, integerDuration = 0;
    double seconds = -1;
    if (duration && xpc_get_type(duration) == XPC_TYPE_DOUBLE) seconds = xpc_double_get_value(duration);
    else if (ADCMediaUInt(duration, &integerDuration)) seconds = (double)integerDuration;
    if (!ADCMediaUInt(features, &flags) || !version || !*version || strnlen(version, sizeof(result->avcVersion)) >= sizeof(result->avcVersion) ||
        !running || xpc_get_type(running) != XPC_TYPE_BOOL || !sessions || xpc_array_get_count(sessions) > 128 || !isfinite(seconds) || seconds < 0)
        return ADCFail(error, capacity, @"Media inspection fields have unsupported types, sizes or duration.");
    BOOL digit = NO;
    for (const char *p = version; *p; p++) {
        if (*p >= '0' && *p <= '9') digit = YES;
        else if (*p == '.' && digit) digit = NO;
        else return ADCFail(error, capacity, @"Unsupported AVConference version shape.");
    }
    if (!digit) return ADCFail(error, capacity, @"Unsupported AVConference version shape.");
    result->supportedFeatures = flags;
    result->sessionCount = xpc_array_get_count(sessions);
    result->runDurationSeconds = seconds;
    result->running = xpc_bool_get_value(running);
    snprintf(result->avcVersion, sizeof(result->avcVersion), "%s", version);
    return 0;
}

@interface ADCMediaControl ()
@property(nonatomic, strong) xpc_connection_t connection;
@property(nonatomic, strong) id remote;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *uuid;
@property(nonatomic, copy) NSString *version;
@end

@implementation ADCMediaControl
+ (instancetype)openUUID:(const char *)uuid version:(const char *)version streaming:(BOOL)streaming
               cancelled:(int (^)(void))cancelled error:(char *)error capacity:(size_t)capacity {
    NSString *identity = uuid ? [NSString stringWithUTF8String:uuid] : nil;
    NSString *release = version && strnlen(version, 64) < 64 ? [NSString stringWithUTF8String:version] : nil;
    if (!identity || ![[NSUUID alloc] initWithUUIDString:identity] || !release ||
        [release rangeOfString:@"^[0-9]+(\\.[0-9]+){0,3}$" options:NSRegularExpressionSearch].location == NSNotFound ||
        (cancelled && cancelled())) {
        ADCFail(error, capacity, @"Invalid or cancelled media control identity; no connection started."); return nil;
    }
    if (ADCPrepareCoreDevice(error, capacity)) return nil;
    ADCCreate create = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
    ADCHandler handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
    ADCActivate activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
    ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
    if (!create || !handler || !activate || !cancel || !dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply")) {
        ADCFail(error, capacity, @"Apple native media control APIs are unavailable."); return nil;
    }
    ADCMediaControl *owner = [self new];
    owner.uuid = identity; owner.version = release;
    owner.queue = dispatch_queue_create("manzanero.media.control", DISPATCH_QUEUE_SERIAL);
    owner.connection = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", owner.queue);
    if (!owner.connection) { ADCFail(error, capacity, @"Cannot create Apple media control connection."); return nil; }
    xpc_connection_set_event_handler(owner.connection, ^(xpc_object_t event) {});
    xpc_connection_resume(owner.connection);
    int descriptor = -1;
    BOOL success = NO;
    @try {
        xpc_object_t input = xpc_dictionary_create_empty();
        xpc_dictionary_set_string(input, "featureIdentifier", streaming ? "com.apple.coredevice.feature.startmediastream" : "com.apple.coredevice.feature.getmediasupportinfo");
        ADCReplyState *replyState = [ADCReplyState new];
        xpc_connection_send_message_with_reply(owner.connection, ADCEnvelope(uuid, version, input), owner.queue, ^(xpc_object_t reply) {
            replyState.reply = reply; dispatch_semaphore_signal(replyState.semaphore);
        });
        if (!ADCWaitForReply(replyState, clock_gettime_nsec_np(CLOCK_MONOTONIC) + 15ULL * NSEC_PER_SEC, cancelled)) {
            ADCFail(error, capacity, @"Media service socket request was cancelled or exceeded its deadline."); return nil;
        }
        xpc_object_t reply = replyState.reply;
        xpc_object_t output = ADCValidHIDReply(reply) ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : nil;
        uint64_t flags = 0;
        if (!output || !ADCMediaUInt(xpc_dictionary_get_value(output, "remoteXPCVersionFlags"), &flags)) {
            char detail[512] = {0};
            xpc_object_t failure = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.error") : nil;
            ADCDescribeCoreDeviceError(failure ? (__bridge const void *)failure : NULL, detail, sizeof(detail));
            ADCFail(error, capacity, [NSString stringWithFormat:@"Apple media socket output unsupported. %s", detail]); return nil;
        }
        descriptor = xpc_dictionary_dup_fd(output, "fileDescriptor");
        int type = 0, descriptorFlags = descriptor < 0 ? -1 : fcntl(descriptor, F_GETFD);
        socklen_t typeSize = sizeof(type);
        if (descriptorFlags < 0 || getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &typeSize) || type != SOCK_STREAM ||
            fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC)) {
            ADCFail(error, capacity, @"Apple media service did not return a configurable owned stream socket."); return nil;
        }
        if (cancelled && cancelled()) { ADCFail(error, capacity, @"Media control cancelled before RemoteXPC setup."); return nil; }
        ADCRemote remote = create(descriptor, owner.queue, flags, 0);
        if (!remote) { ADCFail(error, capacity, @"Cannot create native media RemoteXPC connection."); return nil; }
        descriptor = -1;
        owner.remote = CFBridgingRelease(remote);
        handler(remote, ^(xpc_object_t event) {});
        activate(remote);
        success = YES;
        return owner;
    } @finally {
        if (descriptor >= 0) close(descriptor);
        if (!success) [owner close];
    }
}
- (xpc_object_t)requestAction:(const char *)action input:(xpc_object_t)input deadline:(uint64_t)deadline
                   cancelled:(int (^)(void))cancelled error:(char *)error capacity:(size_t)capacity {
    if (!self.remote || !action || !input || (cancelled && cancelled()) || clock_gettime_nsec_np(CLOCK_MONOTONIC) >= deadline) {
        ADCFail(error, capacity, @"Media control is closed, cancelled or expired before request."); return nil;
    }
    ADCReply request = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply");
    if (!request) { ADCFail(error, capacity, @"Apple media request API unavailable."); return nil; }
    xpc_object_t message = ADCEnvelope(self.uuid.UTF8String, self.version.UTF8String, input);
    xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", action);
    ADCReplyState *state = [ADCReplyState new];
    request((__bridge ADCRemote)self.remote, message, self.queue, ^(xpc_object_t reply) {
        state.reply = reply; dispatch_semaphore_signal(state.semaphore);
    });
    if (!ADCWaitForReply(state, MIN(deadline, clock_gettime_nsec_np(CLOCK_MONOTONIC) + 8ULL * NSEC_PER_SEC), cancelled)) {
        ADCFail(error, capacity, @"Media request was cancelled or exceeded its deadline; a mutation may have an unknown outcome."); return nil;
    }
    xpc_object_t reply = state.reply;
    if (!ADCValidHIDReply(reply)) {
        char detail[768] = {0};
        xpc_object_t failure = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.error") : nil;
        ADCDescribeCoreDeviceError(failure ? (__bridge const void *)failure : NULL, detail, sizeof(detail));
        ADCFail(error, capacity, [NSString stringWithFormat:@"Media action %s failed: %s", action, detail]); return nil;
    }
    return reply;
}
- (void)close {
    id remote = self.remote; self.remote = nil;
    if (remote) {
        ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        if (cancel) cancel((__bridge ADCRemote)remote);
    }
    xpc_connection_t connection = self.connection; self.connection = nil;
    if (connection) xpc_connection_cancel(connection);
}
- (void)dealloc { [self close]; }
@end

int ADCInspectMedia(const char *uuid, const char *version, int (^shouldCancel)(void),
                    ADCMediaInspection *result, char *error, size_t capacity) {
    @autoreleasepool {
        if (!result) return ADCFail(error, capacity, @"Media inspection requires an output.");
        memset(result, 0, sizeof(*result));
        uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 20ULL * NSEC_PER_SEC;
        ADCMediaControl *owner = [ADCMediaControl openUUID:uuid version:version streaming:NO cancelled:shouldCancel error:error capacity:capacity];
        if (!owner) return 1;
        @try {
            xpc_object_t support = [owner requestAction:"com.apple.coredevice.action.mediastreamgetsupportinfo" input:xpc_dictionary_create_empty()
                deadline:deadline cancelled:shouldCancel error:error capacity:capacity];
            if (!support) return 1;
            xpc_object_t status = [owner requestAction:"com.apple.coredevice.action.mediastreamstatus" input:xpc_dictionary_create_empty()
                deadline:deadline cancelled:shouldCancel error:error capacity:capacity];
            if (!status) return 1;
            if (shouldCancel && shouldCancel()) return ADCFail(error, capacity, @"Media inspection cancelled after its read-only replies.");
            return ADCValidateMediaInspection((__bridge const void *)support, (__bridge const void *)status, result, error, capacity);
        } @finally { [owner close]; }
    }
}

/// How long an input connection stays open after its completion barrier.
/// Measured on an iPhone 13 mini with 80 ms taps and short holds: 50 ms lost
/// 30 of 80 actions; 100 ms, 200 ms and 400 ms lost none. 200 ms leaves a margin.
static const uint64_t ADCInputDrainNanoseconds = 200 * NSEC_PER_MSEC;

static int ADCPerformInputOnTouchscreen(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, BOOL keyboard, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, const ADCKeyboardSample *keys,
                   const uint64_t *reportTimes, const uint8_t *reports, uint64_t *resolvedSurface, size_t count,
                   ADCDigitizerProvider provider, const double *crown, const char *touchscreen,
                   ADCInputShouldStop shouldCancel, char *error, size_t capacity);

/// Every input but a digitizer schedule for a named display's touchscreen.
static int ADCPerformInput(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, BOOL keyboard, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, const ADCKeyboardSample *keys,
                   const uint64_t *reportTimes, const uint8_t *reports, uint64_t *resolvedSurface, size_t count,
                   ADCDigitizerProvider provider, const double *crown, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    return ADCPerformInputOnTouchscreen(uuid, version, usage, hold, keyboard, samples, secondPoints, keys, reportTimes, reports,
                                        resolvedSurface, count, provider, crown, NULL, shouldCancel, error, capacity);
}

/// `touchscreen`, for a Universal HID schedule or stream only: the unique ID
/// of the display whose touchscreen takes the reports, matched against the
/// service's product name `CoreDevice touchscreen(<unique ID>)`. A device
/// with one display lists one touchscreen and needs none; an iPhone Duo has
/// one per display. NULL keeps the rule of exactly one touchscreen.
static int ADCPerformInputOnTouchscreen(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, BOOL keyboard, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints, const ADCKeyboardSample *keys,
                   const uint64_t *reportTimes, const uint8_t *reports, uint64_t *resolvedSurface, size_t count,
                   ADCDigitizerProvider provider, const double *crown, const char *touchscreen,
                   ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    @autoreleasepool {
        // A finite schedule and a live stream both go to the Universal HID
        // touchscreen; they differ only in where the reports come from.
        BOOL universal = reports || provider;
        if (shouldCancel && shouldCancel()) return ADCFail(error, capacity, @"Input cancelled before transport setup; no input sent.");
        if (!uuid || !version || ![[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid]]) {
            return ADCFail(error, capacity, @"Invalid direct input identity.");
        }
        const char *feature = universal ? "com.apple.coredevice.feature.remote.universalhidservice" :
            crown ? "com.apple.coredevice.feature.remote.hid.scroll" :
            (samples ? "com.apple.coredevice.feature.remote.hid.digitizer" : "com.apple.coredevice.feature.remote.hid.button");
        // Button and keyboard events share Apple's Indigo HID service. Open its
        // registered button feature rather than inventing a standalone keyboard
        // feature socket; keyboard messages carry their own feature identifier.
        xpc_object_t (*scalarEvent)(uint64_t, uint64_t, BOOL) = keyboard ? ADCKeyboardEvent : ADCPagedButtonEvent;
        if (ADCPrepareCoreDevice(error, capacity)) return 1;
        ADCCreate create = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
        ADCHandler handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        ADCActivate activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        ADCActivate cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        ADCSend send = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message");
        ADCReply request = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply");
        if (!create || !handler || !activate || !cancel || !send || !request)
            return ADCFail(error, capacity, @"Required Apple CoreDevice/RemoteXPC symbols are unavailable.");
        dispatch_queue_t queue = dispatch_queue_create("manzanero.coredevice.button", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t connection = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", queue);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
        xpc_connection_resume(connection);
        xpc_object_t input = xpc_dictionary_create_empty();
        xpc_dictionary_set_string(input, "featureIdentifier", feature);
        if (samples || keyboard || crown) xpc_dictionary_set_string(input, "serviceName", "com.apple.coredevice.hid.indigo");
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
        xpc_object_t output = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : NULL;
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
        if (universal && usage == ADCRemoteTouchServiceID) {
            // The remote's touch pad: no service of the device's own is
            // one, so one is created for the call, as on a simulator.
            ADCReplyState *creation = [ADCReplyState new];
            request(remote, ADCRemoteTouchCreateRequest(), queue, ^(xpc_object_t response) {
                creation.reply = response;
                dispatch_semaphore_signal(creation.semaphore);
            });
            BOOL timeout = dispatch_semaphore_wait(creation.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
            if (timeout || status.failed || !ADCRemoteTouchCreated(creation.reply)) {
                char *text = creation.reply ? xpc_copy_description(creation.reply) : NULL;
                NSString *detail = text ? [[NSString stringWithUTF8String:text] substringToIndex:MIN((size_t)500, strlen(text))] : @"no reply";
                free(text);
                cancel(remote); xpc_connection_cancel(connection);
                return ADCFail(error, capacity, [@"Apple Universal HID did not create a touch-pad service for the remote; no report sent. " stringByAppendingString:detail]);
            }
            surface = ADCRemoteTouchServiceID;
        } else if (universal) {
            ADCReplyState *discovery = [ADCReplyState new];
            request(remote, ADCUniversalRequest("connectedServices", xpc_dictionary_create_empty()), queue, ^(xpc_object_t response) {
                discovery.reply = response;
                dispatch_semaphore_signal(discovery.semaphore);
            });
            BOOL timeout = dispatch_semaphore_wait(discovery.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
            xpc_object_t services = ADCValidHIDReply(discovery.reply) ? xpc_dictionary_get_array(discovery.reply, "connectedServices") : NULL;
            size_t matches = 0, touchscreens = 0;
            NSString *wanted = touchscreen ? [NSString stringWithFormat:@"CoreDevice touchscreen(%s)", touchscreen] : nil;
            if (!timeout && !status.failed && services && xpc_array_get_count(services) <= 128) {
                for (size_t i = 0; i < xpc_array_get_count(services); i++) {
                    xpc_object_t descriptor = xpc_array_get_value(services, i);
                    if (xpc_get_type(descriptor) != XPC_TYPE_DICTIONARY) continue;
                    const char *product = xpc_dictionary_get_string(descriptor, "Product");
                    xpc_object_t identifier = xpc_dictionary_get_value(descriptor, "_ServiceID");
                    uint64_t value = identifier && xpc_get_type(identifier) == XPC_TYPE_UINT64 ? xpc_uint64_get_value(identifier) : 0;
                    if (!product || strncmp(product, "CoreDevice touchscreen(", 23) != 0 || !value) continue;
                    touchscreens++;
                    if (!wanted || strcmp(product, wanted.UTF8String) == 0) { surface = value; matches++; }
                }
            }
            if (matches != 1) {
                cancel(remote); xpc_connection_cancel(connection);
                NSString *detail = wanted
                    ? [NSString stringWithFormat:@"Apple Universal HID listed %zu touchscreens and %zu named %@; no report sent.", touchscreens, matches, wanted]
                    : [NSString stringWithFormat:@"Apple Universal HID did not identify exactly one touchscreen (it listed %zu); no report sent.", touchscreens];
                return ADCFail(error, capacity, detail);
            }
        }
        // Every input mode, including plain consumer buttons, must receive the
        // service's readiness fence before its first down event. Activation
        // alone does not establish that the remote HID service is ready.
        {
            ADCReplyState *ready = [ADCReplyState new];
            xpc_object_t barrier = universal ? ADCUniversalBarrier() : crown ? ADCCrownEvent(0, YES) :
                (samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES));
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
        BOOL scheduleStopped = NO, invalidBeforeInput = NO;
        if (provider) {
            int live = ADCRunLiveDigitizer(provider,
                ^int { return status.failed || (shouldCancel && shouldCancel()); },
                ^(const uint8_t *bytes) { send(remote, ADCUniversalReport(bytes, surface)); });
            invalidBeforeInput = live == 2;
            scheduleStopped = live == 1 || live == 3;
        } else if (crown) {
            // One step every `hold` microseconds, the first at once.
            uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            for (size_t i = 0; i < count && !scheduleStopped; i++) {
                uint64_t due = start + (uint64_t)i * (uint64_t)hold * NSEC_PER_USEC;
                while (clock_gettime_nsec_np(CLOCK_MONOTONIC) < due) {
                    if (status.failed || (shouldCancel && shouldCancel())) { scheduleStopped = YES; break; }
                    struct timespec slice = { 0, 10 * NSEC_PER_MSEC };
                    nanosleep(&slice, NULL);
                }
                if (scheduleStopped) break;
                send(remote, ADCCrownEvent(crown[i], NO));
            }
        } else if (reports) {
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
        xpc_object_t barrier = universal ? ADCUniversalBarrier() : crown ? ADCCrownEvent(0, YES) :
            (samples ? ADCTouchEvent(0, 0, NULL, 0, YES) : scalarEvent(usage, 0, YES));
        request(remote, barrier, queue, ^(xpc_object_t response) {
            status.reply = response;
            dispatch_semaphore_signal(status.semaphore);
        });
        BOOL timedOut = dispatch_semaphore_wait(status.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
        xpc_object_t barrierReply = status.reply;
        BOOL failed = status.failed || timedOut || !barrierReply || xpc_get_type(barrierReply) != XPC_TYPE_DICTIONARY;
        if (!failed) failed = xpc_dictionary_get_value(barrierReply, "CoreDevice.error") != NULL ||
            xpc_dictionary_get_value(barrierReply, "error") != NULL;
        // The barrier reply does not mean the device has finished injecting the
        // events. Cancelling at once lost whole short gestures on an iPhone
        // (taps and holds under about 0.2 s), while longer ones always arrived.
        // Keep the connection open briefly before cancelling it.
        struct timespec drain = { 0, (long)ADCInputDrainNanoseconds };
        nanosleep(&drain, NULL);
        cancel(remote);
        xpc_connection_cancel(connection);
        if (invalidBeforeInput) return ADCFail(error, capacity, @"The live digitizer stream's first report was invalid; no input sent.");
        if (scheduleStopped || (shouldCancel && shouldCancel()))
            return ADCFailAfterInput(error, capacity, @"Input stopped after cancellation or transport failure; release was attempted for active contacts or keys. UI effect and device-side release are unverified; do not replay automatically.");
        if (failed) return ADCFailAfterInput(error, capacity, @"Input was attempted, but the Apple service barrier was not confirmed. UI effect and release are unknown; do not replay automatically.");
        if (resolvedSurface) *resolvedSurface = surface;
        return 0;
    }
}

int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    // The remote's Menu (0x46) and Play/Pause (0xCD) are left out on purpose:
    // an Apple TV 4K closed the connection on each (docs/other-families.md).
    // No long hold either: a Home held 1.5 s on that Apple TV ended with the
    // connection failing during the hold, and neither Control Centre nor the
    // Home Screen appeared (docs/other-families.md).
    if ((usage != 64 && usage != 48 && usage != 233 && usage != 234) || hold > 400000)
        return ADCFail(error, capacity, @"Invalid direct button request.");
    return ADCPerformInput(uuid, version, usage, hold, NO, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL, shouldCancel, error, capacity);
}

int ADCPressWatchButton(const char *uuid, const char *version, uint64_t page, uint64_t usage,
                        ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    uint64_t code = (page << 32) | usage;
    if (page > 0xFFFF || usage > 0xFFFF || (code != ADCWatchSideButton && code != ADCWatchActionButton))
        return ADCFail(error, capacity, @"Invalid watch button request; no input sent.");
    return ADCPerformInput(uuid, version, code, 80000, NO, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL, shouldCancel, error, capacity);
}

int ADCRotateCrown(const char *uuid, const char *version, const double *deltas, size_t count, uint64_t intervalNanoseconds,
                   ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!deltas || count < 1 || count > 1000 || intervalNanoseconds < NSEC_PER_MSEC || intervalNanoseconds > 1000 * NSEC_PER_MSEC)
        return ADCFail(error, capacity, @"Invalid Digital Crown schedule; no input sent.");
    for (size_t i = 0; i < count; i++)
        if (!isfinite(deltas[i]) || deltas[i] != floor(deltas[i]) || deltas[i] == 0 || fabs(deltas[i]) > 1000)
            return ADCFail(error, capacity, @"Invalid Digital Crown step; no input sent.");
    return ADCPerformInput(uuid, version, 0, (unsigned)(intervalNanoseconds / NSEC_PER_USEC), NO, NULL, NULL, NULL, NULL, NULL, NULL, count, NULL,
                           deltas, shouldCancel, error, capacity);
}

int ADCPressKeyboardKey(const char *uuid, const char *version, uint64_t usage, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!((usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82)))
        return ADCFail(error, capacity, @"Unsupported direct keyboard usage; no input sent.");
    return ADCPerformInput(uuid, version, usage, 80000, YES, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL, shouldCancel, error, capacity);
}

int ADCPerformKeyboard(const char *uuid, const char *version, const ADCKeyboardSample *samples,
                       size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateKeyboardSchedule(samples, count, error, capacity)) return 1;
    return ADCPerformInput(uuid, version, 0, 0, YES, NULL, NULL, samples, NULL, NULL, NULL, count, NULL, NULL, shouldCancel, error, capacity);
}

int ADCValidateKeyboardSchedule(const ADCKeyboardSample *samples, size_t count, char *error, size_t capacity) {
    if (!samples || count < 2 || count > 4096)
        return ADCFail(error, capacity, @"Invalid keyboard sample count; no input sent.");
    BOOL pressed[256] = {NO};
    for (size_t i = 0; i < count; i++) {
        ADCKeyboardSample key = samples[i];
        // Keyboard/Keypad main block, arrows, Non-US backslash (100), Left
        // Shift, Left Option (layout characters) and Left Command (paste).
        BOOL supported = (key.usage >= 4 && key.usage <= 56) || (key.usage >= 79 && key.usage <= 82) || key.usage == 100 ||
            key.usage == 225 || key.usage == 226 || key.usage == 227;
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

static BOOL ADCValidTouchscreenName(const char *touchscreen, char *error, size_t capacity) {
    if (!touchscreen) return YES;
    size_t length = strnlen(touchscreen, 129);
    if (length == 0 || length > 128 || strchr(touchscreen, ')')) {
        ADCFail(error, capacity, @"Invalid touchscreen display identifier; no input sent.");
        return NO;
    }
    return YES;
}

int ADCPerformCancellableDigitizerReports(const char *uuid, const char *version, const char *touchscreen, const uint64_t *times,
                              const uint8_t *reports, size_t count, ADCInputShouldStop shouldCancel,
                              uint64_t *surface, char *error, size_t capacity) {
    if (surface) *surface = 0;
    if (!ADCValidTouchscreenName(touchscreen, error, capacity)) return 1;
    if (ADCValidateDigitizerSchedule(times, reports, count, error, capacity)) return 1;
    return ADCPerformInputOnTouchscreen(uuid, version, 0, 0, NO, NULL, NULL, NULL, times, reports, surface, count, NULL, NULL,
                                        touchscreen, shouldCancel, error, capacity);
}

int ADCPerformLiveDigitizerReports(const char *uuid, const char *version, const char *touchscreen, ADCDigitizerProvider next,
                                   ADCInputShouldStop shouldCancel, uint64_t *surface, char *error, size_t capacity) {
    if (surface) *surface = 0;
    if (!ADCValidTouchscreenName(touchscreen, error, capacity)) return 1;
    if (!next) return ADCFail(error, capacity, @"A live digitizer stream needs a report provider; no input sent.");
    return ADCPerformInputOnTouchscreen(uuid, version, 0, 0, NO, NULL, NULL, NULL, NULL, NULL, surface, 0, next, NULL,
                                        touchscreen, shouldCancel, error, capacity);
}

int ADCPerformCancellableRemoteTouch(const char *uuid, const char *version, const uint64_t *times,
                                     const uint8_t *reports, size_t count, ADCInputShouldStop shouldCancel,
                                     char *error, size_t capacity) {
    if (ADCValidateDigitizerSchedule(times, reports, count, error, capacity)) return 1;
    // The usage names the touch-pad service to create for the call.
    return ADCPerformInput(uuid, version, ADCRemoteTouchServiceID, 0, NO, NULL, NULL, NULL, times, reports, NULL, count, NULL, NULL, shouldCancel, error, capacity);
}

BOOL ADCDigitizerReportActive(const uint8_t *bytes) {
    for (size_t id = 0; id < bytes[1] && id < 5; id++)
        if (bytes[3 + id * 5] & 0xc0) return YES;
    return NO;
}

int ADCValidateDigitizerReport(const uint8_t *bytes, const uint8_t *previous, char *error, size_t capacity) {
    size_t contacts = bytes[1];
    if (bytes[0] != 9 || contacts < 1 || contacts > 5 || (previous && contacts != previous[1]) || bytes[2] != 5)
        return ADCFail(error, capacity, @"Invalid digitizer report identity or time; no input sent.");
    for (size_t id = 0; id < contacts; id++) {
        size_t offset = 3 + id * 5;
        if (bytes[offset] != id && bytes[offset] != (0xc0 | id))
            return ADCFail(error, capacity, @"Invalid digitizer contact flags; no input sent.");
        if (!(bytes[offset] & 0xc0) && previous && memcmp(bytes + offset + 1, previous + offset + 1, 4))
            return ADCFail(error, capacity, @"Inactive digitizer contact moved; no input sent.");
    }
    for (size_t byte = 3 + contacts * 5; byte < 58; byte++)
        if (bytes[byte] != (byte == 40 ? 2 : 0))
            return ADCFail(error, capacity, @"Unsupported digitizer report fields; no input sent.");
    return 0;
}

int ADCValidateDigitizerSchedule(const uint64_t *times, const uint8_t *reports,
                                        size_t count, char *error, size_t capacity) {
    if (!times || !reports || count < 2 || count > 512)
        return ADCFail(error, capacity, @"Invalid digitizer report schedule count; no input sent.");
    for (size_t frame = 0; frame < count; frame++) {
        const uint8_t *bytes = reports + frame * 58;
        if (times[frame] > 10ULL * NSEC_PER_SEC + NSEC_PER_MSEC || (frame == 0 ? times[frame] != 0 : times[frame] <= times[frame - 1]))
            return ADCFail(error, capacity, @"Invalid digitizer report identity or time; no input sent.");
        if (ADCValidateDigitizerReport(bytes, frame ? reports + (frame - 1) * 58 : NULL, error, capacity)) return 1;
        BOOL active = ADCDigitizerReportActive(bytes);
        if ((frame == 0 && !active) || (frame == count - 1 && active))
            return ADCFail(error, capacity, @"Digitizer schedule must start active and end released; no input sent.");
    }
    return 0;
}

static int ADCValidateAndPerformTouch(const char *uuid, const char *version, const ADCTouchSample *samples,
                    const ADCTouchPoint *secondPoints, size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateTouchSchedule(samples, secondPoints, count, error, capacity)) return 1;
    return ADCPerformInput(uuid, version, 0, 0, NO, samples, secondPoints, NULL, NULL, NULL, NULL, count, NULL, NULL, shouldCancel, error, capacity);
}

int ADCValidateTouchSchedule(const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
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
