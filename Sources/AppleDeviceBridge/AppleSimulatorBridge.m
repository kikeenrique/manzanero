#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#include "AppleDeviceBridge.h"

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
