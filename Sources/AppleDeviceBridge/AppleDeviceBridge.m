#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include <dlfcn.h>
#include <unistd.h>
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

int ADCPressButton(const char *uuid, const char *version, uint64_t usage,
                   unsigned hold, char *error, size_t capacity) {
    @autoreleasepool {
        if (!uuid || !version || ![[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid]] ||
            ![@[@64, @48, @233, @234] containsObject:@(usage)] || hold > 400000) {
            return ADCFail(error, capacity, @"Invalid direct button request.");
        }
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
        xpc_dictionary_set_string(input, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.button");
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
            return ADCFail(error, capacity, @"Apple CoreDevice refused the button service socket before input.");
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
        send(remote, ADCButtonEvent(usage, 1, NO));
        usleep(hold);
        // Always send up after down, even if a connection error was observed.
        send(remote, ADCButtonEvent(usage, 2, NO));
        request(remote, ADCButtonEvent(usage, 0, YES), queue, ^(xpc_object_t response) {
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
        if (failed) return ADCFail(error, capacity, @"Button down/up was attempted, but the Apple service barrier was not confirmed. UI effect and release are unknown; do not replay automatically.");
        return 0;
    }
}
