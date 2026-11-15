#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "AppleDeviceBridge.h"

// The single table of dynamically resolved Apple interfaces, grouped by the
// capability that needs them. Operation code keeps its own lazy guards; this
// table mirrors them (see docs/dependencies.md) so doctor can name a missing
// interface before a device operation starts.
//
// Checking only loads frameworks, with the same path and flags the operation
// uses, and looks names up. It never calls a resolved function (in particular
// not _coredevice_xpc_add_bundle or _coredevice_xpc_init_services), never sends
// an Objective-C message to a checked class, and opens no connection.

typedef struct {
    int kind;
    const char *name;
    const char *owner;
    int required;
    int loadFlags;
} ADCRequirementSpec;

typedef struct {
    const char *identifier;
    const char *summary;
    int minimumMacOSMajor;
    int usedByCommands;
    const ADCRequirementSpec *requirements;
    size_t requirementCount;
} ADCCapabilitySpec;

#define ADC_FRAMEWORK(path, flags) { ADCInterfaceFramework, path, NULL, 1, flags }
#define ADC_SYMBOL(name) { ADCInterfaceSymbol, name, NULL, 1, 0 }
#define ADC_CLASS(name) { ADCInterfaceClass, name, NULL, 1, 0 }
#define ADC_OPTIONAL_CLASS(name) { ADCInterfaceClass, name, NULL, 0, 0 }
#define ADC_METHOD(owner, name) { ADCInterfaceInstanceMethod, name, owner, 1, 0 }
#define ADC_OPTIONAL_METHOD(owner, name) { ADCInterfaceInstanceMethod, name, owner, 0, 0 }
#define ADC_CLASS_METHOD(owner, name) { ADCInterfaceClassMethod, name, owner, 1, 0 }
#define ADC_FILE(path) { ADCInterfaceFile, path, NULL, 1, 0 }
#define ADC_COUNT(array) (sizeof(array) / sizeof((array)[0]))

// Frameworks listed before the names they provide; flags match the operation's dlopen.
#define ADC_COREDEVICE_PREPARE \
    ADC_FRAMEWORK("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice", RTLD_NOW | RTLD_GLOBAL), \
    ADC_SYMBOL("_coredevice_xpc_add_bundle"), \
    ADC_SYMBOL("_coredevice_xpc_init_services")
#define ADC_REMOTE_XPC_DESCRIPTOR_CONTROL \
    ADC_SYMBOL("xpc_remote_connection_create_with_connected_fd"), \
    ADC_SYMBOL("xpc_remote_connection_set_event_handler"), \
    ADC_SYMBOL("xpc_remote_connection_activate"), \
    ADC_SYMBOL("xpc_remote_connection_cancel")
#define ADC_MEDIA_CONTROL \
    ADC_COREDEVICE_PREPARE, ADC_REMOTE_XPC_DESCRIPTOR_CONTROL, \
    ADC_SYMBOL("xpc_remote_connection_send_message_with_reply")
#define ADC_AVCONFERENCE_NEGOTIATION \
    ADC_FRAMEWORK("/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference", RTLD_NOW | RTLD_LOCAL), \
    ADC_CLASS("AVCMediaStreamNegotiator"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "initWithMode:options:error:"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "negotiatorSettings"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "createOffer"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "offer"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "setAnswer:withError:"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "generateMediaStreamConfigurationWithError:"), \
    ADC_METHOD("AVCMediaStreamNegotiator", "generateMediaStreamInitOptionsWithError:"), \
    ADC_CLASS("AVCMediaStreamNegotiatorSettings"), \
    ADC_CLASS_METHOD("AVCMediaStreamNegotiatorSettings", "negotiatorSettingsForMode:deviceRole:options:errorString:"), \
    ADC_METHOD("AVCMediaStreamNegotiatorSettings", "localSSRC"), \
    ADC_CLASS("AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing")

// ADCPressButton, ADCPressKeyboardKey, ADCPerformKeyboard, ADCPerformTouch,
// ADCPerformTwoContactTouch: Indigo HID over a CoreDevice service socket.
static const ADCRequirementSpec ADCPhysicalInput[] = {
    ADC_COREDEVICE_PREPARE, ADC_REMOTE_XPC_DESCRIPTOR_CONTROL,
    ADC_SYMBOL("xpc_remote_connection_send_message"),
    ADC_SYMBOL("xpc_remote_connection_send_message_with_reply"),
};
// ADCPerformCancellableDigitizerReports: Universal HID touchscreen reports.
static const ADCRequirementSpec ADCMultiContactInput[] = {
    ADC_COREDEVICE_PREPARE, ADC_REMOTE_XPC_DESCRIPTOR_CONTROL,
    ADC_SYMBOL("xpc_remote_connection_send_message"),
    ADC_SYMBOL("xpc_remote_connection_send_message_with_reply"),
};
// ADCOpenRSDDirectoryNetwork, then a plain socket to the advertised AX port.
static const ADCRequirementSpec ADCRSDAccessibility[] = {
    ADC_COREDEVICE_PREPARE,
    ADC_SYMBOL("xpc_remote_connection_create_with_nw_connection"),
    ADC_SYMBOL("xpc_remote_connection_setup_nw_parameters"),
    ADC_SYMBOL("xpc_remote_connection_get_failsafe_version_flags"),
    ADC_SYMBOL("xpc_remote_connection_cancel"),
    ADC_SYMBOL("xpc_remote_connection_set_event_handler"),
    ADC_SYMBOL("xpc_remote_connection_activate"),
    ADC_SYMBOL("xpc_remote_connection_send_message"),
};
// ADCInspectMedia through ADCMediaControl.
static const ADCRequirementSpec ADCMediaInspectionRequirements[] = { ADC_MEDIA_CONTROL };
// ADCCreateVideoPacketSession/ADCStartVideoSession (production recording mode).
// The five selectors after negotiatorSettings are called without a guard.
static const ADCRequirementSpec ADCNativeRecording[] = {
    ADC_MEDIA_CONTROL, ADC_AVCONFERENCE_NEGOTIATION,
    // VideoReadNegotiatedFeedback: missing contracts leave feedback unknown.
    ADC_OPTIONAL_METHOD("AVCMediaStreamNegotiator", "mediaNegotiator"),
    ADC_OPTIONAL_CLASS("VCMediaNegotiatorBase"),
    ADC_OPTIONAL_METHOD("VCMediaNegotiatorBase", "negotiatedScreenSettings"),
    ADC_OPTIONAL_CLASS("VCMediaNegotiatorResultsVideo"),
    ADC_OPTIONAL_METHOD("VCMediaNegotiatorResultsVideo", "isRTCPFBEnabled"),
};
// ADCPrepareCoreSimulator and ADCOpenSimulatorDevice: one SimDevice by UUID.
#define ADC_CORESIMULATOR_DEVICE \
    ADC_FRAMEWORK("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL), \
    ADC_CLASS("SimServiceContext"), \
    ADC_CLASS_METHOD("SimServiceContext", "sharedServiceContextForDeveloperDir:error:"), \
    ADC_METHOD("SimServiceContext", "defaultDeviceSetWithError:"), \
    ADC_CLASS("SimDeviceSet"), \
    ADC_METHOD("SimDeviceSet", "devicesByUDID"), \
    ADC_CLASS("SimDevice"), \
    ADC_METHOD("SimDevice", "stateString"), \
    ADC_METHOD("SimDevice", "deviceType"), \
    ADC_METHOD("SimDevice", "lookup:error:"), \
    ADC_OPTIONAL_METHOD("SimDevice", "name"), \
    ADC_CLASS("SimDeviceType"), \
    ADC_METHOD("SimDeviceType", "mainScreenSize"), \
    ADC_METHOD("SimDeviceType", "mainScreenScale")
// Simulator tap, long-press, swipe, drag, button, key and type: Indigo HID
// dictionaries over host XPC to the dtuhidd daemon CoreSimulator injects into
// a booted iOS simulator. The daemon's launchd plist is a file check only;
// whether the booted runtime runs it cannot be seen without a simulator.
static const ADCRequirementSpec ADCSimulatorInput[] = {
    ADC_CORESIMULATOR_DEVICE,
    ADC_SYMBOL("xpc_endpoint_create_mach_port_4sim"),
    ADC_SYMBOL("xpc_connection_create_from_endpoint"),
    ADC_SYMBOL("xpc_connection_enable_sim2host_4sim"),
    ADC_FILE("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/Library/LaunchDaemons/com.apple.coredevice.dtuhidd.plist"),
};
// Simulator tree, press/scroll by id or label and waits: archived
// AXPTranslatorRequest objects through -[SimDevice sendAccessibilityRequestAsync:...].
static const ADCRequirementSpec ADCSimulatorAccessibility[] = {
    ADC_CORESIMULATOR_DEVICE,
    ADC_METHOD("SimDevice", "sendAccessibilityRequestAsync:completionQueue:completionHandler:"),
    ADC_FRAMEWORK("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW | RTLD_LOCAL),
    ADC_CLASS("AXPTranslatorRequest"),
    ADC_CLASS_METHOD("AXPTranslatorRequest", "supportsSecureCoding"),
    ADC_CLASS("AXPTranslatorResponse"),
    ADC_CLASS_METHOD("AXPTranslatorResponse", "supportsSecureCoding"),
    ADC_CLASS("AXPTranslationObject"),
    ADC_CLASS_METHOD("AXPTranslationObject", "supportsSecureCoding"),
};
// ADCReadArchiveUID (CoreFoundation is linked, so no framework load).
static const ADCRequirementSpec ADCKeyedArchiveUID[] = {
    ADC_SYMBOL("_CFKeyedArchiverUIDGetTypeID"),
    ADC_SYMBOL("_CFKeyedArchiverUIDGetValue"),
};

// Bridge path that no CLI or MCP command reaches today.
// ADCCreateVideoSession (decoded-JPEG mode). Its runtime access check,
// -[AVCStreamOutput validateAccess], needs an instance and is not run here.
static const ADCRequirementSpec ADCNativeRecordingJPEG[] = {
    ADC_MEDIA_CONTROL, ADC_AVCONFERENCE_NEGOTIATION,
    ADC_CLASS("AVCVideoStream"),
    ADC_METHOD("AVCVideoStream", "initWithNetworkSockets:options:error:"),
    ADC_METHOD("AVCVideoStream", "configure:error:"),
    ADC_METHOD("AVCVideoStream", "setDelegate:"),
    ADC_METHOD("AVCVideoStream", "start"),
    ADC_METHOD("AVCVideoStream", "stop"),
    ADC_METHOD("AVCVideoStream", "streamToken"),
    ADC_CLASS("AVCStreamOutput"),
    ADC_METHOD("AVCStreamOutput", "initWithStreamToken:delegate:queue:error:"),
    ADC_METHOD("AVCStreamOutput", "setDelegate:"),
    ADC_METHOD("AVCStreamOutput", "validateAccess"),
};

static const ADCCapabilitySpec ADCCapabilities[] = {
    { "physical-input", "button, key, type, paste, tap, long-press, drag, swipe, pinch and two-contact multi-drag through CoreDevice Indigo HID", 0, 1,
      ADCPhysicalInput, ADC_COUNT(ADCPhysicalInput) },
    { "multi-contact-input", "gesture, multi-tap and multi-contact multi-drag through CoreDevice Universal HID digitizer reports", 0, 1,
      ADCMultiContactInput, ADC_COUNT(ADCMultiContactInput) },
    { "tunnel-assertion", "Exact-UDID tunnel assertion through the public XPC pairing-daemon service; nothing is resolved dynamically", 0, 1,
      NULL, 0 },
    { "rsd-accessibility", "Native physical accessibility (tree, press/scroll by id or label) through a Network RemoteXPC RSD directory", 0, 1,
      ADCRSDAccessibility, ADC_COUNT(ADCRSDAccessibility) },
    { "media-inspection", "Read-only native media support and status through a CoreDevice RemoteXPC media socket", 0, 1,
      ADCMediaInspectionRequirements, ADC_COUNT(ADCMediaInspectionRequirements) },
    { "native-recording", "record-screen --recording-backend coredevice: AVConference negotiation over the media socket", 26, 1,
      ADCNativeRecording, ADC_COUNT(ADCNativeRecording) },
    { "simulator-input", "Simulator tap, long-press, swipe, drag, button, key and type through host XPC to the simulator's dtuhidd Indigo HID daemon", 0, 1,
      ADCSimulatorInput, ADC_COUNT(ADCSimulatorInput) },
    { "simulator-accessibility", "Simulator accessibility (tree, press/scroll by id or label, waits) through CoreSimulator AXPTranslator requests", 0, 1,
      ADCSimulatorAccessibility, ADC_COUNT(ADCSimulatorAccessibility) },
    { "keyed-archive-uid", "Reading keyed-archive UID values in AX archives and decode-ax-archive", 0, 1,
      ADCKeyedArchiveUID, ADC_COUNT(ADCKeyedArchiveUID) },
    { "native-recording-jpeg", "Decoded-JPEG native video session (bridge path not used by commands)", 26, 0,
      ADCNativeRecordingJPEG, ADC_COUNT(ADCNativeRecordingJPEG) },
};

// Walks method lists only: no message is sent, so no +initialize or dynamic
// method resolution runs in the checked class.
static int ADCClassDeclaresMethod(Class type, SEL selector) {
    for (Class current = type; current; current = class_getSuperclass(current)) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(current, &count);
        int found = 0;
        for (unsigned i = 0; i < count && !found; i++) found = method_getName(methods[i]) == selector;
        free(methods);
        if (found) return 1;
    }
    return 0;
}

static int ADCRequirementAvailable(const ADCRequirementSpec *spec) {
    switch (spec->kind) {
    case ADCInterfaceFramework:
        // Loading may run the image's own initializers; no exported function is called.
        return dlopen(spec->name, spec->loadFlags) != NULL;
    case ADCInterfaceSymbol:
        return dlsym(RTLD_DEFAULT, spec->name) != NULL;
    case ADCInterfaceFile:
        // Existence only: the file is neither opened nor parsed.
        return access(spec->name, F_OK) == 0;
    case ADCInterfaceClass:
        return objc_lookUpClass(spec->name) != Nil;
    case ADCInterfaceInstanceMethod:
    case ADCInterfaceClassMethod: {
        Class type = spec->owner ? objc_lookUpClass(spec->owner) : Nil;
        if (!type) return 0;
        if (spec->kind == ADCInterfaceClassMethod) type = object_getClass((id)type);
        return ADCClassDeclaresMethod(type, sel_registerName(spec->name));
    }
    default:
        return 0;
    }
}

void ADCCheckCapabilities(__attribute__((noescape)) void (^sink)(const ADCCapabilityCheck *capability)) {
    if (!sink) return;
    @autoreleasepool {
        for (size_t c = 0; c < ADC_COUNT(ADCCapabilities); c++) {
            const ADCCapabilitySpec *spec = &ADCCapabilities[c];
            size_t count = spec->requirementCount;
            ADCInterfaceRequirement results[count ? count : 1];
            for (size_t r = 0; r < count; r++) {
                const ADCRequirementSpec *requirement = &spec->requirements[r];
                results[r] = (ADCInterfaceRequirement){
                    .kind = requirement->kind, .name = requirement->name, .owner = requirement->owner,
                    .required = requirement->required, .available = ADCRequirementAvailable(requirement)
                };
            }
            ADCCapabilityCheck check = {
                .identifier = spec->identifier, .summary = spec->summary,
                .minimumMacOSMajor = spec->minimumMacOSMajor, .usedByCommands = spec->usedByCommands,
                .requirements = results, .requirementCount = count
            };
            sink(&check);
        }
    }
}
