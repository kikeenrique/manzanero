// The device's accessibility daemon reached through the Mac's own remoted,
// as Apple's Accessibility Inspector reaches it: Apple's MobileDevice
// framework asks remoted for the daemon's shim service
// (com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote), which
// remoted serves to the framework's helper. No service directory connection
// of this process is opened, so the device does not reset remoted's
// (docs/transport.md#the-cost-of-this-route). Experimental.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include "AppleDeviceBridge.h"

static int ADCShimFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) strlcpy(error, message.UTF8String ?: "Accessibility shim failure.", capacity);
    return 1;
}

typedef struct {
    void *(*copyRemoteDevice)(const unsigned char *);
    CFTypeRef (*createDevice)(void *, CFErrorRef *);
    int (*connect)(void *);
    int (*startSession)(void *);
    int (*stopSession)(void *);
    int (*disconnect)(void *);
    int (*startService)(void *, CFStringRef, CFDictionaryRef, void **);
    int (*serviceSocket)(void *);
    void *(*secureContext)(void *);
    void (*invalidate)(void *);
} ADCShimFunctions;

static const ADCShimFunctions *ADCLoadShimFunctions(void) {
    static ADCShimFunctions functions;
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The flags and names here are mirrored in doctor's table
        // (AppleInterfaceAvailability.m, "accessibility-shim").
        void *discovery = dlopen("/System/Library/PrivateFrameworks/RemoteServiceDiscovery.framework/RemoteServiceDiscovery", RTLD_NOW);
        void *mobile = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_GLOBAL);
        if (!discovery || !mobile) return;
        functions.copyRemoteDevice = dlsym(discovery, "remote_device_copy_device_with_uuid");
        functions.createDevice = dlsym(mobile, "AMDeviceCreateWithRemoteDeviceWithError");
        functions.connect = dlsym(mobile, "AMDeviceConnect");
        functions.startSession = dlsym(mobile, "AMDeviceStartSession");
        functions.stopSession = dlsym(mobile, "AMDeviceStopSession");
        functions.disconnect = dlsym(mobile, "AMDeviceDisconnect");
        functions.startService = dlsym(mobile, "AMDeviceSecureStartService");
        functions.serviceSocket = dlsym(mobile, "AMDServiceConnectionGetSocket");
        functions.secureContext = dlsym(mobile, "AMDServiceConnectionGetSecureIOContext");
        functions.invalidate = dlsym(mobile, "AMDServiceConnectionInvalidate");
        available = functions.copyRemoteDevice && functions.createDevice && functions.connect && functions.startSession &&
            functions.stopSession && functions.disconnect && functions.startService && functions.serviceSocket &&
            functions.secureContext && functions.invalidate;
    });
    return available ? &functions : NULL;
}

@interface ADCAccessibilityShimOwner : NSObject
@property(nonatomic, strong) id remoteDevice;
@property(nonatomic, strong) id device;
@property(nonatomic) void *service;
@end
@implementation ADCAccessibilityShimOwner
@end

int ADCOpenAccessibilityShim(const char *remoteUUID, int *descriptor, void **owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        if (descriptor) *descriptor = -1;
        uuid_t uuid;
        if (!remoteUUID || !descriptor || !owner || uuid_parse(remoteUUID, uuid) != 0)
            return ADCShimFail(error, capacity, @"The accessibility shim requires the device's identifier in remoted; nothing was contacted.");
        const ADCShimFunctions *f = ADCLoadShimFunctions();
        if (!f) return ADCShimFail(error, capacity, @"Apple's RemoteServiceDiscovery or MobileDevice interfaces for the accessibility shim are unavailable; nothing was contacted.");
        id remote = (__bridge_transfer id)f->copyRemoteDevice(uuid);
        if (!remote) return ADCShimFail(error, capacity, @"remoted does not know the device under that identifier; nothing was contacted.");
        CFErrorRef created = NULL;
        id device = CFBridgingRelease(f->createDevice((__bridge void *)remote, &created));
        if (!device) {
            NSString *reason = created ? CFBridgingRelease(CFErrorCopyDescription(created)) : @"no reason given";
            if (created) CFRelease(created);
            return ADCShimFail(error, capacity, [NSString stringWithFormat:@"Apple's MobileDevice framework did not accept the device (%@); nothing was contacted.", reason]);
        }
        void *handle = (__bridge void *)device;
        int status = f->connect(handle);
        if (status) return ADCShimFail(error, capacity, [NSString stringWithFormat:@"The device refused the connection (0x%x); no accessibility connection was opened.", status]);
        status = f->startSession(handle);
        if (status) {
            f->disconnect(handle);
            return ADCShimFail(error, capacity, [NSString stringWithFormat:@"The device did not start a session (0x%x); no accessibility connection was opened.", status]);
        }
        void *service = NULL;
        status = f->startService(handle, CFSTR("com.apple.accessibility.axAuditDaemon.remoteserver"), NULL, &service);
        // The service connection lives on by itself, as the tunnel's does.
        f->stopSession(handle);
        f->disconnect(handle);
        if (status || !service)
            return ADCShimFail(error, capacity, [NSString stringWithFormat:@"The device did not start its accessibility service (0x%x); no accessibility connection was opened.", status]);
        // The accessibility code reads and writes a stream descriptor. An
        // encrypted service connection could not be handed over that way.
        int socket = f->serviceSocket(service);
        if (f->secureContext(service) || socket < 0) {
            f->invalidate(service);
            return ADCShimFail(error, capacity, @"The accessibility service connection is encrypted or has no socket; it was closed.");
        }
        int copy = dup(socket);
        if (copy < 0) {
            f->invalidate(service);
            return ADCShimFail(error, capacity, @"The accessibility service's socket could not be duplicated; it was closed.");
        }
        ADCAccessibilityShimOwner *lifetime = [ADCAccessibilityShimOwner new];
        lifetime.remoteDevice = remote;
        lifetime.device = device;
        lifetime.service = service;
        *descriptor = copy;
        *owner = (void *)CFBridgingRetain(lifetime);
        return 0;
    }
}

void ADCReleaseAccessibilityShim(void *owner) {
    if (!owner) return;
    ADCAccessibilityShimOwner *lifetime = CFBridgingRelease(owner);
    const ADCShimFunctions *f = ADCLoadShimFunctions();
    if (f && lifetime.service) f->invalidate(lifetime.service);
    lifetime.service = NULL;
}
