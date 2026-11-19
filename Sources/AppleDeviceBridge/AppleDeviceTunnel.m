// A tunnel of the tool's own to a device on its cable or on the network,
// opened with Apple's private MobileDevice framework
// (docs/transport.md#a-tunnel-of-the-tools-own).
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <string.h>
#include "AppleDeviceBridge.h"

static int ADCTunnelFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) strlcpy(error, message.UTF8String ?: "Device tunnel failure.", capacity);
    return 1;
}

/// The MobileDevice functions the tunnel uses, resolved once.
typedef struct {
    CFArrayRef (*createList)(void);
    CFStringRef (*copyIdentifier)(void *);
    int (*interfaceType)(void *);
    unsigned int (*connectionID)(void *);
    CFTypeRef (*createFromProperties)(CFDictionaryRef);
    int (*connect)(void *);
    int (*validatePairing)(void *);
    int (*startSession)(void *);
    int (*stopSession)(void *);
    int (*disconnect)(void *);
    int (*startService)(void *, CFStringRef, CFDictionaryRef, void **);
    long (*send)(void *, const void *, size_t);
    long (*receive)(void *, void *, size_t);
    void (*invalidate)(void *);
} ADCMobileDevice;

static const ADCMobileDevice *ADCLoadMobileDevice(void) {
    static ADCMobileDevice functions;
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The flags and names here are mirrored in doctor's table
        // (AppleInterfaceAvailability.m, "device-tunnel").
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_GLOBAL);
        if (!handle) return;
        functions.createList = dlsym(handle, "AMDCreateDeviceList");
        functions.copyIdentifier = dlsym(handle, "AMDeviceCopyDeviceIdentifier");
        functions.interfaceType = dlsym(handle, "AMDeviceGetInterfaceType");
        functions.connectionID = dlsym(handle, "AMDeviceGetConnectionID");
        functions.createFromProperties = dlsym(handle, "AMDeviceCreateFromProperties");
        functions.connect = dlsym(handle, "AMDeviceConnect");
        functions.validatePairing = dlsym(handle, "AMDeviceValidatePairing");
        functions.startSession = dlsym(handle, "AMDeviceStartSession");
        functions.stopSession = dlsym(handle, "AMDeviceStopSession");
        functions.disconnect = dlsym(handle, "AMDeviceDisconnect");
        functions.startService = dlsym(handle, "AMDeviceSecureStartService");
        functions.send = dlsym(handle, "AMDServiceConnectionSend");
        functions.receive = dlsym(handle, "AMDServiceConnectionReceive");
        functions.invalidate = dlsym(handle, "AMDServiceConnectionInvalidate");
        available = functions.createList && functions.copyIdentifier && functions.interfaceType && functions.connectionID &&
            functions.createFromProperties && functions.connect &&
            functions.validatePairing && functions.startSession && functions.stopSession && functions.disconnect &&
            functions.startService && functions.send && functions.receive && functions.invalidate;
    });
    return available ? &functions : NULL;
}

@interface ADCDeviceTunnelOwner : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic) void *service;
@property(atomic) BOOL closed;
@end
@implementation ADCDeviceTunnelOwner
@end

/// Receives exactly `length` bytes. Returns NO on close or error.
static BOOL ADCTunnelReceiveAll(const ADCMobileDevice *mobile, void *service, uint8_t *buffer, size_t length) {
    size_t done = 0;
    while (done < length) {
        long got = mobile->receive(service, buffer + done, length - done);
        if (got <= 0) return NO;
        done += (size_t)got;
    }
    return YES;
}

int ADCOpenDeviceTunnel(const char *udid, ADCDeviceTunnelInfo *info, void **owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        NSString *requested = udid ? [NSString stringWithUTF8String:udid] : nil;
        if (!info || !owner || !requested ||
            [requested rangeOfString:@"^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$" options:NSRegularExpressionSearch].length != requested.length)
            return ADCTunnelFail(error, capacity, @"A device tunnel requires an explicit hardware UDID; nothing was contacted.");
        const ADCMobileDevice *mobile = ADCLoadMobileDevice();
        if (!mobile) return ADCTunnelFail(error, capacity, @"Apple's MobileDevice framework or one of its tunnel interfaces is unavailable; nothing was contacted.");
        // Interface type 1 is the cable and 2 the network; the cable is
        // preferred when the device has both.
        NSArray *devices = CFBridgingRelease(mobile->createList());
        id cabled = nil, networked = nil;
        for (id candidate in devices) {
            NSString *identifier = CFBridgingRelease(mobile->copyIdentifier((__bridge void *)candidate));
            if (![identifier isEqualToString:requested]) continue;
            int type = mobile->interfaceType((__bridge void *)candidate);
            if (type == 1) { cabled = candidate; break; }
            if (type == 2 && !networked) networked = candidate;
        }
        BOOL overNetwork = !cabled && networked;
        if (overNetwork) {
            // The framework connects to a network device directly, which
            // macOS's Local Network privacy refuses to a process that has
            // not been granted it (connect() fails with EHOSTUNREACH at
            // once, 0xe8000065). It connects to a cabled device through
            // usbmuxd, and usbmuxd relays to a network device as well: a
            // second device object for the same usbmuxd entry, described as
            // cabled, takes that path. The product and location it is given
            // are placeholders the connection does not use.
            unsigned int connection = mobile->connectionID((__bridge void *)networked);
            NSDictionary *entry = @{@"DeviceID": @(connection), @"Properties": @{
                @"DeviceID": @(connection), @"SerialNumber": requested, @"ConnectionType": @"USB",
                @"ProductID": @0x12a8, @"LocationID": @0}};
            cabled = CFBridgingRelease(mobile->createFromProperties((__bridge CFDictionaryRef)entry));
            if (!cabled) return ADCTunnelFail(error, capacity, @"Apple's MobileDevice framework did not accept the device's network entry; nothing was contacted.");
        }
        if (!cabled) return ADCTunnelFail(error, capacity, @"Apple's MobileDevice framework does not list the device; nothing was contacted.");
        void *device = (__bridge void *)cabled;
        int status = mobile->connect(device);
        if (status) return ADCTunnelFail(error, capacity, [NSString stringWithFormat:@"The device refused the connection (0x%x); no tunnel was opened.", status]);
        status = mobile->validatePairing(device);
        if (!status) status = mobile->startSession(device);
        if (status) {
            mobile->disconnect(device);
            return ADCTunnelFail(error, capacity, [NSString stringWithFormat:@"The Mac's trust with the device was not accepted (0x%x); no tunnel was opened. Pairing is not started by this tool.", status]);
        }
        void *service = NULL;
        status = mobile->startService(device, CFSTR("com.apple.internal.devicecompute.CoreDeviceProxy"), NULL, &service);
        if (status || !service) {
            mobile->stopSession(device);
            mobile->disconnect(device);
            return ADCTunnelFail(error, capacity, [NSString stringWithFormat:@"The device did not start its tunnel service (0x%x); a locked device refuses it. No tunnel was opened.", status]);
        }
        // The service's greeting: "CDTunnel", a big-endian length, JSON.
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"type": @"clientHandshakeRequest", @"mtu": @1280} options:0 error:NULL];
        NSMutableData *request = [NSMutableData dataWithBytes:"CDTunnel" length:8];
        uint16_t length = htons((uint16_t)json.length);
        [request appendBytes:&length length:2];
        [request appendData:json];
        uint8_t header[10] = {0};
        NSDictionary *reply = nil;
        if (mobile->send(service, request.bytes, request.length) == (long)request.length &&
            ADCTunnelReceiveAll(mobile, service, header, sizeof(header)) && memcmp(header, "CDTunnel", 8) == 0) {
            size_t size = ((size_t)header[8] << 8) | header[9];
            NSMutableData *body = [NSMutableData dataWithLength:size];
            if (size > 0 && size <= 4096 && ADCTunnelReceiveAll(mobile, service, body.mutableBytes, size)) {
                id parsed = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
                if ([parsed isKindOfClass:NSDictionary.class]) reply = parsed;
            }
        }
        NSDictionary *client = [reply[@"clientParameters"] isKindOfClass:NSDictionary.class] ? reply[@"clientParameters"] : nil;
        NSString *clientAddress = [client[@"address"] isKindOfClass:NSString.class] ? client[@"address"] : nil;
        NSString *serverAddress = [reply[@"serverAddress"] isKindOfClass:NSString.class] ? reply[@"serverAddress"] : nil;
        NSNumber *mtu = [client[@"mtu"] isKindOfClass:NSNumber.class] ? client[@"mtu"] : nil;
        NSNumber *port = [reply[@"serverRSDPort"] isKindOfClass:NSNumber.class] ? reply[@"serverRSDPort"] : nil;
        memset(info, 0, sizeof(*info));
        BOOL valid = [reply[@"type"] isEqual:@"serverHandshakeResponse"] && clientAddress && serverAddress &&
            inet_pton(AF_INET6, clientAddress.UTF8String, info->clientAddress) == 1 &&
            inet_pton(AF_INET6, serverAddress.UTF8String, info->serverAddress) == 1 &&
            mtu.integerValue >= 1280 && mtu.integerValue <= 16000 && port.integerValue > 0 && port.integerValue <= 65535;
        if (!valid) {
            mobile->invalidate(service);
            mobile->stopSession(device);
            mobile->disconnect(device);
            return ADCTunnelFail(error, capacity, @"The device's tunnel service did not answer its greeting with usable parameters; no tunnel was opened.");
        }
        info->mtu = (uint16_t)mtu.integerValue;
        info->serviceDirectoryPort = (uint16_t)port.integerValue;
        info->overNetwork = overNetwork ? 1 : 0;
        // The service connection lives on by itself; the session that
        // started it is given back at once, for Apple's own tools.
        mobile->stopSession(device);
        mobile->disconnect(device);
        ADCDeviceTunnelOwner *lifetime = [ADCDeviceTunnelOwner new];
        lifetime.device = cabled;
        lifetime.service = service;
        *owner = (void *)CFBridgingRetain(lifetime);
        return 0;
    }
}

int ADCDeviceTunnelSend(void *owner, const uint8_t *packet, size_t length) {
    ADCDeviceTunnelOwner *lifetime = (__bridge ADCDeviceTunnelOwner *)owner;
    const ADCMobileDevice *mobile = ADCLoadMobileDevice();
    if (!lifetime || !mobile || lifetime.closed || !packet || length < 40) return 1;
    return mobile->send(lifetime.service, packet, length) == (long)length ? 0 : 1;
}

long ADCDeviceTunnelReceive(void *owner, uint8_t *buffer, size_t capacity) {
    ADCDeviceTunnelOwner *lifetime = (__bridge ADCDeviceTunnelOwner *)owner;
    const ADCMobileDevice *mobile = ADCLoadMobileDevice();
    if (!lifetime || !mobile || !buffer || capacity < 40) return -1;
    if (lifetime.closed) return 0;
    // An IPv6 packet: a fixed header of 40 bytes whose bytes 4 and 5 give
    // the length of what follows.
    if (!ADCTunnelReceiveAll(mobile, lifetime.service, buffer, 40)) return lifetime.closed ? 0 : -1;
    if (buffer[0] >> 4 != 6) return -1;
    size_t payload = ((size_t)buffer[4] << 8) | buffer[5];
    if (40 + payload > capacity) return -1;
    if (payload && !ADCTunnelReceiveAll(mobile, lifetime.service, buffer + 40, payload)) return lifetime.closed ? 0 : -1;
    return (long)(40 + payload);
}

void ADCCloseDeviceTunnel(void *owner) {
    ADCDeviceTunnelOwner *lifetime = (__bridge ADCDeviceTunnelOwner *)owner;
    const ADCMobileDevice *mobile = ADCLoadMobileDevice();
    if (!lifetime || !mobile || lifetime.closed) return;
    lifetime.closed = YES;
    mobile->invalidate(lifetime.service);
}

void ADCReleaseDeviceTunnel(void *owner) {
    if (!owner) return;
    ADCCloseDeviceTunnel(owner);
    CFBridgingRelease(owner);
}

int ADCListDeviceTunnelLinks(__attribute__((noescape)) void (^sink)(const char *udid, int link)) {
    @autoreleasepool {
        const ADCMobileDevice *mobile = ADCLoadMobileDevice();
        if (!mobile || !sink) return 1;
        NSArray *devices = CFBridgingRelease(mobile->createList());
        for (id candidate in devices) {
            NSString *identifier = CFBridgingRelease(mobile->copyIdentifier((__bridge void *)candidate));
            int type = mobile->interfaceType((__bridge void *)candidate);
            if (identifier.length && (type == 1 || type == 2)) sink(identifier.UTF8String, type);
        }
        return 0;
    }
}
