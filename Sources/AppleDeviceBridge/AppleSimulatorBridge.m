#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#include <time.h>
#include <mach/mach.h>
#include <IOKit/IOCFSerialize.h>
#include "AppleDeviceBridge.h"
#include "AppleDeviceBridgeInternal.h"

// Simulator counterpart of the physical bridge. Private interfaces:
// CoreSimulator's SimServiceContext/SimDeviceSet/SimDevice/SimDeviceType.
// Every class and selector is resolved at run time and checked before use; the
// same names are listed in AppleInterfaceAvailability.m for doctor.
// Research and evidence: docs/simulator-input-research.md, docs/simulator-input.md.

static NSString *const ADCCoreSimulatorPath = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
static NSString *const ADCAccessibilityTranslationPath =
    @"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation";

static int ADCSimulatorFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String);
    return 1;
}

static BOOL ADCResponds(id target, NSString *selector) {
    return target && [target respondsToSelector:NSSelectorFromString(selector)];
}

static BOOL ADCClassResponds(const char *name, NSArray<NSString *> *instance, NSArray<NSString *> *classSelectors) {
    Class type = objc_lookUpClass(name);
    if (!type) return NO;
    for (NSString *selector in instance)
        if (!class_getInstanceMethod(type, NSSelectorFromString(selector))) return NO;
    for (NSString *selector in classSelectors)
        if (!class_getClassMethod(type, NSSelectorFromString(selector))) return NO;
    return YES;
}

int ADCPrepareCoreSimulator(int accessibility, char *error, size_t capacity) {
    static void *coreSimulator, *translation;
    static dispatch_once_t simulatorOnce, translationOnce;
    dispatch_once(&simulatorOnce, ^{
        coreSimulator = dlopen(ADCCoreSimulatorPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    });
    if (!coreSimulator) return ADCSimulatorFail(error, capacity, @"Cannot load the installed Apple CoreSimulator framework; nothing was sent to the simulator.");
    if (!ADCClassResponds("SimServiceContext", @[@"defaultDeviceSetWithError:"], @[@"sharedServiceContextForDeveloperDir:error:"]) ||
        !ADCClassResponds("SimDeviceSet", @[@"devicesByUDID"], @[]) ||
        !ADCClassResponds("SimDevice", @[@"stateString", @"deviceType", @"lookup:error:"], @[]) ||
        !ADCClassResponds("SimDeviceType", @[@"mainScreenSize", @"mainScreenScale"], @[]))
        return ADCSimulatorFail(error, capacity, @"Required Apple CoreSimulator classes or selectors are unavailable; nothing was sent to the simulator.");
    if (!accessibility) return 0;
    if (!ADCClassResponds("SimDevice", @[@"sendAccessibilityRequestAsync:completionQueue:completionHandler:"], @[]))
        return ADCSimulatorFail(error, capacity, @"CoreSimulator lacks -[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]; no accessibility request sent.");
    dispatch_once(&translationOnce, ^{
        translation = dlopen(ADCAccessibilityTranslationPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    });
    if (!translation) return ADCSimulatorFail(error, capacity, @"Cannot load Apple's AccessibilityPlatformTranslation framework; no accessibility request sent.");
    if (!ADCClassResponds("AXPTranslatorRequest", @[], @[@"supportsSecureCoding"]) ||
        !ADCClassResponds("AXPTranslatorResponse", @[], @[@"supportsSecureCoding"]) ||
        !ADCClassResponds("AXPTranslationObject", @[], @[@"supportsSecureCoding"]))
        return ADCSimulatorFail(error, capacity, @"Required AccessibilityPlatformTranslation classes are unavailable; no accessibility request sent.");
    return 0;
}

@interface ADCSimulatorOwner : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@implementation ADCSimulatorOwner
@end

static void ADCCopyText(char *destination, size_t capacity, id value) {
    if (!destination || !capacity) return;
    destination[0] = 0;
    if (![value isKindOfClass:NSString.class]) return;
    snprintf(destination, capacity, "%s", [(NSString *)value UTF8String] ?: "");
}

static int ADCReadDevice(id device, ADCSimulatorInfo *info, char *error, size_t capacity) {
    memset(info, 0, sizeof(*info));
    id state = ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"stateString"));
    ADCCopyText(info->state, sizeof(info->state), state);
    info->booted = [state isKindOfClass:NSString.class] && [state isEqualToString:@"Booted"];
    if (ADCResponds(device, @"name")) ADCCopyText(info->name, sizeof(info->name), ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"name")));
    id type = ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"deviceType"));
    if (!ADCResponds(type, @"mainScreenSize") || !ADCResponds(type, @"mainScreenScale"))
        return ADCSimulatorFail(error, capacity, @"CoreSimulator did not report the simulator's device type or screen geometry.");
    if (ADCResponds(type, @"productFamily"))
        ADCCopyText(info->family, sizeof(info->family), ((id (*)(id, SEL))objc_msgSend)(type, NSSelectorFromString(@"productFamily")));
    CGSize pixels = ((CGSize (*)(id, SEL))objc_msgSend)(type, NSSelectorFromString(@"mainScreenSize"));
    float scale = ((float (*)(id, SEL))objc_msgSend)(type, NSSelectorFromString(@"mainScreenScale"));
    if (!(scale > 0 && scale <= 10) || !(pixels.width > 0 && pixels.height > 0) || pixels.width > 32768 || pixels.height > 32768)
        return ADCSimulatorFail(error, capacity, @"CoreSimulator reported invalid screen geometry for the simulator.");
    info->scale = scale;
    info->widthPoints = pixels.width / scale;
    info->heightPoints = pixels.height / scale;
    return 0;
}

int ADCOpenSimulatorDevice(const char *developerDir, const char *uuid, ADCSimulatorInfo *info,
                           void **owner, char *error, size_t capacity) {
    @autoreleasepool {
        if (owner) *owner = NULL;
        if (info) memset(info, 0, sizeof(*info));
        NSUUID *identifier = uuid ? [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid]] : nil;
        if (!owner || !info || !identifier || !developerDir || !*developerDir)
            return ADCSimulatorFail(error, capacity, @"Invalid simulator UUID or developer directory; nothing was sent to the simulator.");
        if (ADCPrepareCoreSimulator(0, error, capacity)) return 1;
        NSError *failure = nil;
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(objc_lookUpClass("SimServiceContext"),
            NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), [NSString stringWithUTF8String:developerDir], &failure);
        if (!context) return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"CoreSimulator service context is unavailable: %@", failure.localizedDescription ?: @"no detail"]);
        id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &failure);
        if (!set) return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"CoreSimulator default device set is unavailable: %@", failure.localizedDescription ?: @"no detail"]);
        id devices = ((id (*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"devicesByUDID"));
        id device = [devices isKindOfClass:NSDictionary.class] ? [(NSDictionary *)devices objectForKey:identifier] : nil;
        if (!device) {
            ADCSimulatorFail(error, capacity, @"No simulator with this UUID exists in the default device set.");
            return ADCSimulatorNotFound;
        }
        if (ADCReadDevice(device, info, error, capacity)) return 1;
        ADCSimulatorOwner *lifetime = [ADCSimulatorOwner new];
        lifetime.device = device;
        lifetime.queue = dispatch_queue_create("manzanero.simulator", DISPATCH_QUEUE_SERIAL);
        *owner = (void *)CFBridgingRetain(lifetime);
        return 0;
    }
}

int ADCReadSimulatorDevice(void *owner, ADCSimulatorInfo *info, char *error, size_t capacity) {
    @autoreleasepool {
        if (!owner || !info) return ADCSimulatorFail(error, capacity, @"Simulator device is not open.");
        ADCSimulatorOwner *lifetime = (__bridge ADCSimulatorOwner *)owner;
        return ADCReadDevice(lifetime.device, info, error, capacity);
    }
}

void ADCCloseSimulatorDevice(void *owner) {
    if (owner) CFBridgingRelease(owner);
}

// MARK: - Accessibility

@interface ADCSimulatorReply : NSObject
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@property(atomic, strong) id value;
@property(atomic) BOOL arrived;
@end
@implementation ADCSimulatorReply
- (instancetype)init { if ((self = [super init])) _semaphore = dispatch_semaphore_create(0); return self; }
@end

static BOOL ADCSimulatorWait(ADCSimulatorReply *reply, double seconds, ADCInputShouldStop shouldCancel) {
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + (uint64_t)(seconds * NSEC_PER_SEC);
    while (!(shouldCancel && shouldCancel()) && clock_gettime_nsec_np(CLOCK_MONOTONIC) < deadline) {
        if (!dispatch_semaphore_wait(reply.semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC))) return YES;
    }
    return NO;
}

int ADCSimulatorAXExchange(void *owner, const uint8_t *request, size_t length, double timeoutSeconds,
                           ADCInputShouldStop shouldCancel, void (^sink)(const uint8_t *, size_t),
                           char *error, size_t capacity) {
    @autoreleasepool {
        if (!owner || !request || !length || length > 16 * 1024 * 1024 || !sink || !(timeoutSeconds > 0 && timeoutSeconds <= 60))
            return ADCSimulatorFail(error, capacity, @"Invalid simulator accessibility request; nothing was sent.");
        if (shouldCancel && shouldCancel()) return ADCSimulatorFail(error, capacity, @"Simulator accessibility request cancelled before sending.");
        if (ADCPrepareCoreSimulator(1, error, capacity)) return 1;
        ADCSimulatorOwner *lifetime = (__bridge ADCSimulatorOwner *)owner;
        Class requestClass = objc_lookUpClass("AXPTranslatorRequest"), objectClass = objc_lookUpClass("AXPTranslationObject");
        NSSet *allowed = [NSSet setWithObjects:requestClass, objectClass, NSDictionary.class, NSArray.class,
                          NSNumber.class, NSString.class, NSValue.class, NSData.class, NSNull.class, nil];
        NSError *failure = nil;
        NSKeyedUnarchiver *decoder = [[NSKeyedUnarchiver alloc] initForReadingFromData:[NSData dataWithBytes:request length:length] error:&failure];
        decoder.requiresSecureCoding = YES;
        id object = nil;
        @try { object = [decoder decodeTopLevelObjectOfClasses:allowed forKey:NSKeyedArchiveRootObjectKey error:&failure]; }
        @catch (NSException *exception) { object = nil; }
        [decoder finishDecoding];
        if (![object isKindOfClass:requestClass])
            return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The accessibility request did not unarchive as AXPTranslatorRequest (%@); nothing was sent.", failure.localizedDescription ?: @"unexpected class"]);
        // The request keeps the client type the Swift side archived: 2 for the
        // container hit that selects the foreground process (a point over an
        // empty area returns its container instead of failing), 0 for element
        // hits, where type 2 can answer with an outer container instead of the
        // element (observed on iPhone Duo and Apple TV; docs/simulator-input.md).
        if (shouldCancel && shouldCancel()) return ADCSimulatorFail(error, capacity, @"Simulator accessibility request cancelled before sending.");
        ADCSimulatorReply *reply = [ADCSimulatorReply new];
        void (^completion)(id) = ^(id response) {
            reply.value = response;
            reply.arrived = YES;
            dispatch_semaphore_signal(reply.semaphore);
        };
        ((void (*)(id, SEL, id, dispatch_queue_t, id))objc_msgSend)(lifetime.device,
            NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:"), object, lifetime.queue, completion);
        if (!ADCSimulatorWait(reply, timeoutSeconds, shouldCancel)) {
            ADCSimulatorFail(error, capacity, shouldCancel && shouldCancel()
                ? @"Simulator accessibility request cancelled after sending; its effect is unknown."
                : [NSString stringWithFormat:@"Simulator accessibility request got no reply within %.1f seconds; its effect is unknown.", timeoutSeconds]);
            return ADCSimulatorAXSent;
        }
        id response = reply.value;
        if (!response || ![response isKindOfClass:objc_lookUpClass("AXPTranslatorResponse")]) {
            ADCSimulatorFail(error, capacity, @"CoreSimulator returned no AXPTranslatorResponse for the accessibility request.");
            return ADCSimulatorAXSent;
        }
        NSData *archive = nil;
        @try { archive = [NSKeyedArchiver archivedDataWithRootObject:response requiringSecureCoding:NO error:&failure]; }
        @catch (NSException *exception) { archive = nil; }
        if (!archive.length || archive.length > 16 * 1024 * 1024) {
            ADCSimulatorFail(error, capacity, @"Cannot archive the simulator's AXPTranslatorResponse within 16 MiB.");
            return ADCSimulatorAXSent;
        }
        sink(archive.bytes, archive.length);
        return 0;
    }
}

// MARK: - Indigo HID through dtuhidd

typedef xpc_object_t (*ADCEndpointFromPort)(mach_port_t, uint64_t, uint64_t);
typedef xpc_connection_t (*ADCConnectionFromEndpoint)(xpc_object_t);
typedef void (*ADCEnableSimulatorToHost)(xpc_connection_t);

/// After the completion barrier the connection stays open this long before
/// it is cancelled. The guest barrier confirms that dtuhidd dequeued the
/// events, not that the guest delivered them; IDB's DTUHID transport (MIT,
/// Meta Platforms, as vendored by AXe) measured 380 ms for a tap to arrive
/// before disconnect. See docs/simulator-input.md for this project's check.
static const uint64_t ADCSimulatorDrainNanoseconds = 380 * NSEC_PER_MSEC;

static int ADCSimulatorFailAfterInput(char *error, size_t capacity, NSString *message) {
    ADCSimulatorFail(error, capacity, message);
    return ADCInputOutcomeUnknown;
}

static xpc_object_t ADCSimulatorBarrier(void) {
    xpc_object_t barrier = xpc_dictionary_create_empty();
    xpc_dictionary_set_bool(barrier, "isBarrier", true);
    return barrier;
}

/// Sends one guest barrier and waits up to three seconds for its reply.
static BOOL ADCSimulatorBarrierAcknowledged(xpc_connection_t connection, dispatch_queue_t queue, ADCSimulatorReply *status) {
    ADCSimulatorReply *reply = [ADCSimulatorReply new];
    xpc_connection_send_message_with_reply(connection, ADCSimulatorBarrier(), queue, ^(xpc_object_t response) {
        reply.value = response;
        dispatch_semaphore_signal(reply.semaphore);
    });
    BOOL timedOut = dispatch_semaphore_wait(reply.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0;
    xpc_object_t response = reply.value;
    return !timedOut && !status.arrived && response && xpc_get_type(response) == XPC_TYPE_DICTIONARY &&
        !xpc_dictionary_get_value(response, "error") && !xpc_dictionary_get_value(response, "CoreDevice.error");
}

/// Opens a host XPC connection to one Mach service inside the simulator
/// (lookup:error:, the _4sim endpoint, sim2host) on the owner's queue and
/// resumes it. A connection error sets status.arrived. Returns NULL with the
/// error written ("…; no input sent.") when the service cannot be reached.
static xpc_connection_t ADCSimulatorConnectWithEvents(ADCSimulatorOwner *lifetime, NSString *service, ADCSimulatorReply *status,
                                                      NSString *hint, void (^events)(xpc_object_t), char *error, size_t capacity);

static xpc_connection_t ADCSimulatorConnect(ADCSimulatorOwner *lifetime, NSString *service, ADCSimulatorReply *status,
                                            NSString *hint, char *error, size_t capacity) {
    return ADCSimulatorConnectWithEvents(lifetime, service, status, hint, NULL, error, capacity);
}

/// As ADCSimulatorConnect; `events`, when given, also receives every
/// non-error connection event (CoreDevice side-channel pushes).
static xpc_connection_t ADCSimulatorConnectWithEvents(ADCSimulatorOwner *lifetime, NSString *service, ADCSimulatorReply *status,
                                                      NSString *hint, void (^events)(xpc_object_t), char *error, size_t capacity) {
    ADCEndpointFromPort endpointFromPort = (ADCEndpointFromPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    ADCConnectionFromEndpoint fromEndpoint = (ADCConnectionFromEndpoint)dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
    ADCEnableSimulatorToHost enable = (ADCEnableSimulatorToHost)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!endpointFromPort || !fromEndpoint || !enable) {
        ADCSimulatorFail(error, capacity, @"Required libxpc simulator endpoint symbols are unavailable; no input sent.");
        return NULL;
    }
    NSError *failure = nil;
    mach_port_t port = ((mach_port_t (*)(id, SEL, id, NSError **))objc_msgSend)(lifetime.device,
        NSSelectorFromString(@"lookup:error:"), service, &failure);
    if (port == MACH_PORT_NULL) {
        ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The simulator does not offer %@ (%@): %@; no input sent.", service, hint, failure.localizedDescription ?: @"no detail"]);
        return NULL;
    }
    xpc_object_t endpoint = endpointFromPort(port, 0, 0);
    xpc_connection_t connection = endpoint ? fromEndpoint(endpoint) : NULL;
    if (!connection) {
        ADCSimulatorFail(error, capacity, @"Cannot create the simulator HID connection; no input sent.");
        return NULL;
    }
    // Without this the daemon sees the peer but never a payload, and the
    // first barrier fails with "Connection interrupted".
    enable(connection);
    xpc_connection_set_target_queue(connection, lifetime.queue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) status.arrived = YES;
        else if (events) events(event);
    });
    xpc_connection_resume(connection);
    return connection;
}

/// One request with reply, waiting at most three seconds.
static xpc_object_t ADCSimulatorRequest(xpc_connection_t connection, dispatch_queue_t queue, xpc_object_t message) {
    ADCSimulatorReply *reply = [ADCSimulatorReply new];
    xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t response) {
        reply.value = response;
        dispatch_semaphore_signal(reply.semaphore);
    });
    if (dispatch_semaphore_wait(reply.semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) return nil;
    return reply.value;
}

/// The shared simulator input path. `prepare`, when given, runs after the
/// readiness barrier and before any input (service discovery); non-zero means
/// nothing was sent and it has written the error. `schedule` runs one of the
/// bridge's schedulers with a sink that sends on the connection; it returns
/// non-zero when it stopped early. status.arrived doubles as "connection failed".
static int ADCSimulatorPerformInput(void *owner, NSString *service, ADCInputShouldStop shouldCancel,
                                    int (^prepare)(xpc_connection_t connection, dispatch_queue_t queue, ADCSimulatorReply *status),
                                    int (^schedule)(xpc_connection_t connection, ADCInputShouldStop stop),
                                    char *error, size_t capacity) {
    @autoreleasepool {
        if (shouldCancel && shouldCancel()) return ADCSimulatorFail(error, capacity, @"Input cancelled before transport setup; no input sent.");
        if (!owner) return ADCSimulatorFail(error, capacity, @"Simulator device is not open; no input sent.");
        if (ADCPrepareCoreSimulator(0, error, capacity)) return 1;
        ADCSimulatorOwner *lifetime = (__bridge ADCSimulatorOwner *)owner;
        ADCSimulatorInfo info;
        if (ADCReadDevice(lifetime.device, &info, error, capacity)) return 1;
        if (!info.booted) return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The simulator is %s, not Booted; no input sent.", info.state]);
        ADCSimulatorReply *status = [ADCSimulatorReply new];
        xpc_connection_t connection = ADCSimulatorConnect(lifetime, service, status, @"no dtuhidd in this runtime?", error, capacity);
        if (!connection) return 1;
        // Every mode waits for the daemon's readiness fence before its first down.
        if (!ADCSimulatorBarrierAcknowledged(connection, lifetime.queue, status)) {
            xpc_connection_cancel(connection);
            return ADCSimulatorFail(error, capacity, @"The simulator HID service did not become ready; no input sent.");
        }
        if (prepare && prepare(connection, lifetime.queue, status)) {
            xpc_connection_cancel(connection);
            return 1;
        }
        BOOL stopped = schedule(connection, ^int { return status.arrived || (shouldCancel && shouldCancel()); }) != 0;
        BOOL confirmed = ADCSimulatorBarrierAcknowledged(connection, lifetime.queue, status);
        struct timespec drain = { 0, (long)ADCSimulatorDrainNanoseconds };
        nanosleep(&drain, NULL);
        xpc_connection_cancel(connection);
        if (stopped || (shouldCancel && shouldCancel()))
            return ADCSimulatorFailAfterInput(error, capacity, @"Input stopped after cancellation or transport failure; release was attempted for active contacts or keys. UI effect and simulator-side release are unverified; do not replay automatically.");
        if (!confirmed) return ADCSimulatorFailAfterInput(error, capacity, @"Input was attempted, but the simulator HID barrier was not confirmed. UI effect and release are unknown; do not replay automatically.");
        return 0;
    }
}

int ADCSimulatorPerformTouch(void *owner, const ADCTouchSample *samples, size_t count,
                             ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateTouchSchedule(samples, NULL, count, error, capacity)) return 1;
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.digitizer", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunTouchSchedule(samples, NULL, count, stop, ^(const ADCTouchSample *sample, const ADCTouchPoint *second) {
                xpc_connection_send_message(connection, ADCTouchEvent(sample->x, sample->y, second, sample->phase, NO));
            });
        }, error, capacity);
}

int ADCSimulatorPerformTwoContactTouch(void *owner, const ADCTouchSample *samples, const ADCTouchPoint *secondPoints,
                                       size_t count, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!secondPoints) return ADCSimulatorFail(error, capacity, @"Missing second contact; no input sent.");
    if (ADCValidateTouchSchedule(samples, secondPoints, count, error, capacity)) return 1;
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.digitizer", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunTouchSchedule(samples, secondPoints, count, stop, ^(const ADCTouchSample *sample, const ADCTouchPoint *second) {
                xpc_connection_send_message(connection, ADCTouchEvent(sample->x, sample->y, second, sample->phase, NO));
            });
        }, error, capacity);
}

int ADCSimulatorPerformKeyboard(void *owner, const ADCKeyboardSample *samples, size_t count,
                                ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateKeyboardSchedule(samples, count, error, capacity)) return 1;
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.keyboard", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunKeyboardSchedule(samples, count, stop, ^(uint64_t usage, uint64_t state) {
                xpc_connection_send_message(connection, ADCKeyboardEvent(usage, state, NO));
            });
        }, error, capacity);
}

int ADCSimulatorPressKeyboardKey(void *owner, uint64_t usage, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!((usage >= 40 && usage <= 44) || (usage >= 79 && usage <= 82)))
        return ADCSimulatorFail(error, capacity, @"Unsupported direct keyboard usage; no input sent.");
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.keyboard", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunPress(usage, 80000, stop, ^(uint64_t code, uint64_t state) {
                xpc_connection_send_message(connection, ADCKeyboardEvent(code, state, NO));
            });
        }, error, capacity);
}

int ADCSimulatorPressButton(void *owner, uint64_t usage, unsigned hold, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if ((usage != 64 && usage != 48 && usage != 233 && usage != 234) || hold > 400000)
        return ADCSimulatorFail(error, capacity, @"Invalid simulator button request; no input sent.");
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.button", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunPress(usage, hold, stop, ^(uint64_t code, uint64_t state) {
                xpc_connection_send_message(connection, ADCButtonEvent(code, state, NO));
            });
        }, error, capacity);
}

/// Waits until `offset` nanoseconds after `start`, polling `stop` every 5 ms.
static BOOL ADCSimulatorWaitUntil(uint64_t start, uint64_t offset, ADCInputShouldStop stop) {
    for (;;) {
        if (stop && stop()) return NO;
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (now >= start + offset) return YES;
        uint64_t left = start + offset - now;
        struct timespec pause = { 0, (long)MIN(left, 5 * NSEC_PER_MSEC) };
        nanosleep(&pause, NULL);
    }
}

/// A button event on a given usage page (ADCButtonEvent's is the consumer page).
static xpc_object_t ADCButtonEventOnPage(uint64_t page, uint64_t usage, uint64_t state) {
    xpc_object_t event = ADCButtonEvent(usage, state, NO);
    xpc_dictionary_set_uint64(xpc_dictionary_get_value(event, "payload"), "usagePage", page);
    return event;
}

int ADCSimulatorPressRemoteButton(void *owner, uint64_t page, uint64_t usage, unsigned hold, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    // Consumer page: Menu (0x40, the TV/Home button), Menu Escape (0x46,
    // Back/Menu), Play/Pause (0xCD) and the watch's side button (0x95, as
    // DeviceKit's watch chrome names it). Page 0xFF01, usage 0x200: the
    // Apple Watch Ultra's Action button (the watch6 chrome's
    // left-side-button); docs/other-families.md.
    BOOL consumer = page == 12 && (usage == 0x40 || usage == 0x46 || usage == 0xCD || usage == 0x95);
    BOOL action = page == 0xFF01 && usage == 0x200;
    // Up to three seconds: a long press on the remote (remote --hold).
    if ((!consumer && !action) || hold == 0 || hold > 3000000)
        return ADCSimulatorFail(error, capacity, @"Invalid simulator remote button request; no input sent.");
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.button", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            if (stop && stop()) return 1;
            xpc_connection_send_message(connection, ADCButtonEventOnPage(page, usage, 1));
            BOOL held = ADCSimulatorWaitUntil(clock_gettime_nsec_np(CLOCK_MONOTONIC), (uint64_t)hold * 1000, stop);
            // Release is sent even when stopped, as the shared press does.
            xpc_connection_send_message(connection, ADCButtonEventOnPage(page, usage, 2));
            return held ? 0 : 1;
        }, error, capacity);
}

static xpc_object_t ADCScrollEvent(double delta) {
    xpc_object_t event = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(event, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.scroll");
    xpc_dictionary_set_string(event, "messageType", "IndigoScrollEvent");
    xpc_dictionary_set_bool(event, "isBarrier", false);
    xpc_object_t payload = xpc_dictionary_create_empty(), point = xpc_dictionary_create_empty();
    xpc_dictionary_set_double(point, "x", 0);
    xpc_dictionary_set_double(point, "y", delta);
    xpc_dictionary_set_double(point, "z", 0);
    xpc_dictionary_set_value(payload, "point", point);
    // Phase and momentum 0: each event is one discrete rotation. Target 0 is
    // the Digital Crown (1 is refused: "No dial service found").
    xpc_dictionary_set_uint64(payload, "phase", 0);
    xpc_dictionary_set_uint64(payload, "momentum", 0);
    xpc_dictionary_set_uint64(payload, "target", 0);
    xpc_dictionary_set_value(event, "payload", payload);
    return event;
}

int ADCSimulatorRotateCrown(void *owner, const double *deltas, size_t count, uint64_t intervalNanoseconds,
                            ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!deltas || count < 1 || count > 1000 || intervalNanoseconds < NSEC_PER_MSEC || intervalNanoseconds > 1000 * NSEC_PER_MSEC)
        return ADCSimulatorFail(error, capacity, @"Invalid Digital Crown schedule; no input sent.");
    for (size_t i = 0; i < count; i++)
        if (!isfinite(deltas[i]) || deltas[i] != floor(deltas[i]) || deltas[i] == 0 || fabs(deltas[i]) > 1000)
            return ADCSimulatorFail(error, capacity, @"Invalid Digital Crown step; no input sent.");
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.scroll", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            for (size_t i = 0; i < count; i++) {
                if (!ADCSimulatorWaitUntil(start, (uint64_t)i * intervalNanoseconds, stop)) return 1;
                xpc_connection_send_message(connection, ADCScrollEvent(deltas[i]));
            }
            return 0;
        }, error, capacity);
}

// MARK: - Hinge (iPhone Duo)

/// The event Device Hub's hinge control sends (docs/duo-fold-research.md):
/// vendor-defined usage page 0xFF61, usage 0x5B, version 0, and a binary
/// IOCFSerialize of {source: "hinge-slider-control", type: "range", value}.
static xpc_object_t ADCHingeEvent(double degrees) {
    NSDictionary *body = @{@"source": @"hinge-slider-control", @"type": @"range", @"value": @(degrees)};
    CFDataRef data = IOCFSerialize((__bridge CFTypeRef)body, kIOCFSerializeToBinary);
    if (!data) return NULL;
    xpc_object_t payload = xpc_dictionary_create_empty();
    xpc_dictionary_set_uint64(payload, "usagePage", 0xFF61);
    xpc_dictionary_set_uint64(payload, "usage", 0x5B);
    xpc_dictionary_set_uint64(payload, "version", 0);
    xpc_dictionary_set_data(payload, "data", CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
    CFRelease(data);
    xpc_object_t event = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(event, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.vendordefined");
    xpc_dictionary_set_string(event, "messageType", "IndigoVendorDefinedEvent");
    xpc_dictionary_set_bool(event, "isBarrier", false);
    xpc_dictionary_set_value(event, "payload", payload);
    return event;
}

int ADCSimulatorSetHingeAngle(void *owner, double degrees, ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (!isfinite(degrees) || degrees < 0 || degrees > 180)
        return ADCSimulatorFail(error, capacity, @"Invalid hinge angle; it must be 0...180 degrees. No input sent.");
    xpc_object_t event = ADCHingeEvent(degrees);
    if (!event) return ADCSimulatorFail(error, capacity, @"Cannot serialize the hinge event; no input sent.");
    // The service does not reply to events (a reply request ends in
    // "Connection interrupted" although the event applies), so it is sent
    // fire-and-forget between the shared barriers. The shared drain keeps the
    // connection open afterwards: cancelling at once lost the event in the
    // research, 50 ms or more always applied it.
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.hid.vendordefined", shouldCancel, NULL,
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            if (stop && stop()) return 1;
            xpc_connection_send_message(connection, event);
            return 0;
        }, error, capacity);
}

// MARK: - Universal HID (three to five contacts, timed sequences)

int ADCSimulatorPerformDigitizerReports(void *owner, const char *displayUUID, const uint64_t *times, const uint8_t *reports,
                                        size_t count, ADCInputShouldStop shouldCancel, uint64_t *surface,
                                        char *error, size_t capacity) {
    if (surface) *surface = 0;
    if (!displayUUID || ![[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:displayUUID]])
        return ADCSimulatorFail(error, capacity, @"Invalid simulator display identifier; no input sent.");
    if (ADCValidateDigitizerSchedule(times, reports, count, error, capacity)) return 1;
    // The simulator offers one touchscreen per display (observed: the primary
    // display and a "Resizable" one; an iPhone Duo also lists LCD-1's). Only
    // the touchscreen of the display the interface is on receives reports
    // that reach the app, so match that display's unique identifier exactly.
    NSString *product = [NSString stringWithFormat:@"CoreDevice touchscreen(%s)", displayUUID];
    __block uint64_t selected = 0;
    int status = ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.universalhidservice", shouldCancel,
        ^int(xpc_connection_t connection, dispatch_queue_t queue, ADCSimulatorReply *state) {
            xpc_object_t reply = ADCSimulatorRequest(connection, queue, ADCUniversalRequest("connectedServices", xpc_dictionary_create_empty()));
            xpc_object_t services = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY && !xpc_dictionary_get_value(reply, "error") &&
                !xpc_dictionary_get_value(reply, "CoreDevice.error") ? xpc_dictionary_get_array(reply, "connectedServices") : NULL;
            size_t matches = 0;
            if (!state.arrived && services && xpc_array_get_count(services) <= 128) {
                for (size_t i = 0; i < xpc_array_get_count(services); i++) {
                    xpc_object_t descriptor = xpc_array_get_value(services, i);
                    if (xpc_get_type(descriptor) != XPC_TYPE_DICTIONARY) continue;
                    const char *name = xpc_dictionary_get_string(descriptor, "Product");
                    xpc_object_t identifier = xpc_dictionary_get_value(descriptor, "_ServiceID");
                    uint64_t value = identifier && xpc_get_type(identifier) == XPC_TYPE_UINT64 ? xpc_uint64_get_value(identifier) : 0;
                    if (name && strcmp(name, product.UTF8String) == 0 && value) { selected = value; matches++; }
                }
            }
            if (matches == 1) return 0;
            ADCSimulatorFail(error, capacity, @"The simulator's Universal HID service did not list exactly one touchscreen for the display; no report sent.");
            return 1;
        },
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunDigitizerSchedule(times, reports, count, stop, ^(const uint8_t *bytes) {
                xpc_connection_send_message(connection, ADCUniversalReport(bytes, selected));
            });
        }, error, capacity);
    if (status == 0 && surface) *surface = selected;
    return status;
}

int ADCSimulatorPerformRemoteTouch(void *owner, const uint64_t *times, const uint8_t *reports, size_t count,
                                   ADCInputShouldStop shouldCancel, char *error, size_t capacity) {
    if (ADCValidateDigitizerSchedule(times, reports, count, error, capacity)) return 1;
    return ADCSimulatorPerformInput(owner, @"com.apple.coredevice.feature.remote.universalhidservice", shouldCancel,
        ^int(xpc_connection_t connection, dispatch_queue_t queue, ADCSimulatorReply *state) {
            xpc_object_t reply = ADCSimulatorRequest(connection, queue, ADCRemoteTouchCreateRequest());
            if (!state.arrived && ADCRemoteTouchCreated(reply)) return 0;
            ADCSimulatorFail(error, capacity, @"The simulator's Universal HID service did not create a touch-pad service for the remote; no report sent.");
            return 1;
        },
        ^int(xpc_connection_t connection, ADCInputShouldStop stop) {
            return ADCRunDigitizerSchedule(times, reports, count, stop, ^(const uint8_t *bytes) {
                xpc_connection_send_message(connection, ADCUniversalReport(bytes, ADCRemoteTouchServiceID));
            });
        }, error, capacity);
}

// MARK: - Display information

/// XPC to Foundation for JSON: dictionaries, arrays, strings, Booleans,
/// integers and doubles. Other types (data, dates, UUIDs) become NSNull.
static id ADCFoundationValue(xpc_object_t value, int depth) {
    if (!value || depth > 16) return NSNull.null;
    xpc_type_t type = xpc_get_type(value);
    if (type == XPC_TYPE_DICTIONARY) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        xpc_dictionary_apply(value, ^bool(const char *key, xpc_object_t item) {
            result[[NSString stringWithUTF8String:key]] = ADCFoundationValue(item, depth + 1);
            return true;
        });
        return result;
    }
    if (type == XPC_TYPE_ARRAY) {
        NSMutableArray *result = [NSMutableArray array];
        xpc_array_apply(value, ^bool(size_t index, xpc_object_t item) {
            [result addObject:ADCFoundationValue(item, depth + 1)];
            return true;
        });
        return result;
    }
    if (type == XPC_TYPE_STRING) return [NSString stringWithUTF8String:xpc_string_get_string_ptr(value)] ?: NSNull.null;
    if (type == XPC_TYPE_BOOL) return @(xpc_bool_get_value(value));
    if (type == XPC_TYPE_INT64) return @(xpc_int64_get_value(value));
    if (type == XPC_TYPE_UINT64) return @(xpc_uint64_get_value(value));
    if (type == XPC_TYPE_DOUBLE) return isfinite(xpc_double_get_value(value)) ? @(xpc_double_get_value(value)) : NSNull.null;
    return NSNull.null;
}

/// A CoreDevice action request as the simulator's dtdeviceinfod expects it:
/// the device identifier and the host's CoreDevice version are required.
/// NULL with the error written ("…; `what` not requested.") when either is unknown.
static xpc_object_t ADCSimulatorActionRequest(ADCSimulatorOwner *lifetime, const char *feature, const char *action,
                                              xpc_object_t input, NSString *what, char *error, size_t capacity) {
    NSString *version = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"].infoDictionary[@"CFBundleVersion"];
    NSArray<NSString *> *parts = [version isKindOfClass:NSString.class] ? [version componentsSeparatedByString:@"."] : nil;
    if (parts.count < 1 || parts.count > 4) {
        ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"Cannot read the installed CoreDevice framework version; %@ not requested.", what]);
        return NULL;
    }
    id udid = ADCResponds(lifetime.device, @"UDID") ? ((id (*)(id, SEL))objc_msgSend)(lifetime.device, NSSelectorFromString(@"UDID")) : nil;
    if (![udid isKindOfClass:NSUUID.class]) {
        ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"CoreSimulator did not report the simulator's UDID; %@ not requested.", what]);
        return NULL;
    }
    xpc_object_t request = xpc_dictionary_create_empty(), release = xpc_dictionary_create_empty(), components = xpc_array_create_empty();
    for (NSString *part in parts) xpc_array_append_value(components, xpc_uint64_create((uint64_t)part.longLongValue));
    xpc_dictionary_set_value(release, "components", components);
    xpc_dictionary_set_int64(release, "originalComponentsCount", (int64_t)parts.count);
    xpc_dictionary_set_string(release, "stringValue", version.UTF8String);
    xpc_dictionary_set_string(request, "CoreDevice.featureIdentifier", feature);
    xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", action);
    xpc_dictionary_set_value(request, "CoreDevice.action", xpc_dictionary_create_empty());
    xpc_dictionary_set_value(request, "CoreDevice.input", input);
    xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", NSUUID.UUID.UUIDString.UTF8String);
    xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", [(NSUUID *)udid UUIDString].UTF8String);
    xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 2);
    xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", release);
    return request;
}

int ADCSimulatorDisplayInfo(void *owner, void (^sink)(const uint8_t *, size_t), char *error, size_t capacity) {
    @autoreleasepool {
        if (!owner || !sink) return ADCSimulatorFail(error, capacity, @"Simulator device is not open.");
        if (ADCPrepareCoreSimulator(0, error, capacity)) return 1;
        ADCSimulatorOwner *lifetime = (__bridge ADCSimulatorOwner *)owner;
        ADCSimulatorInfo info;
        if (ADCReadDevice(lifetime.device, &info, error, capacity)) return 1;
        if (!info.booted) return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The simulator is %s, not Booted; nothing was sent.", info.state]);
        xpc_object_t request = ADCSimulatorActionRequest(lifetime, "com.apple.coredevice.feature.getdisplayinfo", "com.apple.coredevice.action.displayinfo",
                                                         xpc_dictionary_create_empty(), @"display information", error, capacity);
        if (!request) return 1;
        ADCSimulatorReply *status = [ADCSimulatorReply new];
        xpc_connection_t connection = ADCSimulatorConnect(lifetime, @"com.apple.coredevice.feature.getdisplayinfo", status,
                                                          @"no dtdeviceinfod in this runtime?", error, capacity);
        if (!connection) return 1;
        xpc_object_t reply = ADCSimulatorRequest(connection, lifetime.queue, request);
        xpc_connection_cancel(connection);
        xpc_object_t output = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : NULL;
        if (!output) {
            xpc_object_t failure = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.error") : NULL;
            const char *detail = failure ? xpc_dictionary_get_string(xpc_dictionary_get_dictionary(failure, "userInfo"), "NSDebugDescription") : NULL;
            return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The simulator's display information request failed: %s.", detail ?: (reply ? "no output" : "no reply within 3 seconds")]);
        }
        // The shape devicectl prints for a physical device, so the physical
        // display parser reads it: {info: {outcome: success}, result: output}.
        NSDictionary *document = @{@"info": @{@"outcome": @"success"}, @"result": ADCFoundationValue(output, 0)};
        NSError *failure = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:&failure];
        if (!json.length || json.length > 1024 * 1024)
            return ADCSimulatorFail(error, capacity, @"Cannot encode the simulator's display information within 1 MiB.");
        sink(json.bytes, json.length);
        return 0;
    }
}

// MARK: - Hinge angle (iPhone Duo)

/// {value, unit: {symbol, converter: {coefficient, constant}}}, the shape
/// Foundation's Measurement decodes from (docs/duo-fold-research.md).
static xpc_object_t ADCDegrees(double value) {
    xpc_object_t measurement = xpc_dictionary_create_empty(), unit = xpc_dictionary_create_empty(), converter = xpc_dictionary_create_empty();
    xpc_dictionary_set_double(converter, "coefficient", 1.0);
    xpc_dictionary_set_double(converter, "constant", 0.0);
    xpc_dictionary_set_string(unit, "symbol", "°");
    xpc_dictionary_set_value(unit, "converter", converter);
    xpc_dictionary_set_double(measurement, "value", value);
    xpc_dictionary_set_value(measurement, "unit", unit);
    return measurement;
}

int ADCSimulatorReadHingeAngle(void *owner, double timeoutSeconds, ADCInputShouldStop shouldCancel,
                               void (^sink)(const uint8_t *, size_t), char *error, size_t capacity) {
    @autoreleasepool {
        if (!owner || !sink || !(timeoutSeconds > 0 && timeoutSeconds <= 30)) return ADCSimulatorFail(error, capacity, @"Invalid hinge angle request; nothing was sent.");
        if (shouldCancel && shouldCancel()) return ADCSimulatorFail(error, capacity, @"Hinge angle read cancelled before sending.");
        if (ADCPrepareCoreSimulator(0, error, capacity)) return 1;
        ADCSimulatorOwner *lifetime = (__bridge ADCSimulatorOwner *)owner;
        ADCSimulatorInfo info;
        if (ADCReadDevice(lifetime.device, &info, error, capacity)) return 1;
        if (!info.booted) return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The simulator is %s, not Booted; nothing was sent.", info.state]);
        // streamhingeangle input: a 0.5 degree change threshold and a 0.1 s
        // update interval (Swift Duration: [high Int64, low UInt64] attoseconds),
        // and a stream proxy naming the side channel the samples arrive on.
        xpc_object_t input = xpc_dictionary_create_empty(), actual = xpc_dictionary_create_empty(), interval = xpc_array_create_empty();
        xpc_dictionary_set_value(actual, "changeThreshold", ADCDegrees(0.5));
        xpc_array_set_int64(interval, XPC_ARRAY_APPEND, 0);
        xpc_array_set_uint64(interval, XPC_ARRAY_APPEND, 100000000000000000ULL);
        xpc_dictionary_set_value(actual, "updateInterval", interval);
        xpc_dictionary_set_value(input, "actualInput", actual);
        xpc_object_t proxy = xpc_dictionary_create_empty();
        uuid_t side;
        [NSUUID.UUID getUUIDBytes:side];
        xpc_dictionary_set_uuid(proxy, "sideChannel", side);
        xpc_dictionary_set_value(input, "streamProxy", proxy);
        xpc_object_t request = ADCSimulatorActionRequest(lifetime, "com.apple.coredevice.feature.monitormotion", "com.apple.coredevice.action.streamhingeangle",
                                                         input, @"hinge angle", error, capacity);
        if (!request) return 1;
        ADCSimulatorReply *status = [ADCSimulatorReply new], *sample = [ADCSimulatorReply new];
        // The first pushed sample is the current state. The request's reply
        // only arrives when the stream ends, so a reply first is a failure.
        xpc_connection_t connection = ADCSimulatorConnectWithEvents(lifetime, @"com.apple.coredevice.feature.monitormotion", status,
            @"no dtdeviceinfod in this runtime?", ^(xpc_object_t event) {
                if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
                xpc_object_t channel = xpc_dictionary_get_dictionary(event, "CoreDevice.XPCMessageKey.sideChannelStatus");
                xpc_object_t pushing = channel ? xpc_dictionary_get_dictionary(channel, "pushing") : NULL;
                xpc_object_t elements = pushing ? xpc_dictionary_get_array(pushing, "elements") : NULL;
                xpc_object_t first = elements && xpc_array_get_count(elements) ? xpc_array_get_value(elements, 0) : NULL;
                if (!first || xpc_get_type(first) != XPC_TYPE_DICTIONARY || sample.arrived) return;
                sample.value = (id)first;
                sample.arrived = YES;
                dispatch_semaphore_signal(sample.semaphore);
            }, error, capacity);
        if (!connection) return 1;
        xpc_connection_send_message_with_reply(connection, request, lifetime.queue, ^(xpc_object_t reply) {
            if (sample.arrived) return;
            sample.value = (id)reply;
            dispatch_semaphore_signal(sample.semaphore);
        });
        BOOL answered = ADCSimulatorWait(sample, timeoutSeconds, shouldCancel);
        // Cancelling the connection ends the stream; nothing stays open.
        xpc_connection_cancel(connection);
        if (!answered)
            return ADCSimulatorFail(error, capacity, shouldCancel && shouldCancel() ? @"Hinge angle read cancelled; the stream was closed."
                : [NSString stringWithFormat:@"The simulator sent no hinge angle sample within %.1f seconds; the stream was closed.", timeoutSeconds]);
        if (!sample.arrived) {
            xpc_object_t reply = (xpc_object_t)sample.value;
            xpc_object_t failure = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.error") : NULL;
            const char *detail = failure ? xpc_dictionary_get_string(xpc_dictionary_get_dictionary(failure, "userInfo"), "NSDebugDescription") : NULL;
            return ADCSimulatorFail(error, capacity, [NSString stringWithFormat:@"The simulator's hinge angle stream ended without a sample: %s.", detail ?: "no detail"]);
        }
        NSError *failure = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:ADCFoundationValue((xpc_object_t)sample.value, 0) options:NSJSONWritingSortedKeys error:&failure];
        if (!json.length || json.length > 64 * 1024) return ADCSimulatorFail(error, capacity, @"Cannot encode the hinge angle sample.");
        sink(json.bytes, json.length);
        return 0;
    }
}
