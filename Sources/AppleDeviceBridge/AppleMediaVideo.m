#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include "AppleDeviceBridge.h"
#import "AppleMediaControl.h"

// Objective-C method contracts checked against installed AVConference and the
// interoperable ipb reference. All instances and callbacks belong to one owner.
@interface AVCMediaStreamNegotiator : NSObject
- (instancetype)initWithMode:(long)mode options:(NSDictionary *)options error:(NSError **)error;
- (BOOL)createOffer;
- (NSData *)offer;
- (BOOL)setAnswer:(NSData *)answer withError:(NSError **)error;
- (id)generateMediaStreamConfigurationWithError:(NSError **)error;
- (id)generateMediaStreamInitOptionsWithError:(NSError **)error;
- (id)negotiatorSettings;
- (id)mediaNegotiator;
@end
@interface VCMediaNegotiatorBase : NSObject
- (id)negotiatedScreenSettings;
@end
@interface VCMediaNegotiatorResultsVideo : NSObject
- (BOOL)isRTCPFBEnabled;
@end
@interface AVCMediaStreamNegotiatorSettings : NSObject
+ (id)negotiatorSettingsForMode:(long)mode deviceRole:(int)role options:(NSDictionary *)options errorString:(NSString **)error;
- (uint32_t)localSSRC;
@end

static int VideoFail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String);
    return 1;
}
static BOOL VideoUInt(xpc_object_t object, uint64_t *value) {
    if (!object) return NO;
    if (xpc_get_type(object) == XPC_TYPE_UINT64) { *value = xpc_uint64_get_value(object); return YES; }
    if (xpc_get_type(object) == XPC_TYPE_INT64 && xpc_int64_get_value(object) >= 0) { *value = (uint64_t)xpc_int64_get_value(object); return YES; }
    return NO;
}
static uint64_t VideoNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }

// Read the installed native negotiated result rather than parsing a private
// blob or assuming that ordinary RTCP enablement permits keyframe feedback.
// Checked selectors are zero-argument getters with the expected return ABI.
static BOOL VideoGetter(id object, SEL selector, const char *resultType) {
    if (!object || ![object respondsToSelector:selector]) return NO;
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && (resultType[0] == '@' ? type[0] == '@' : !strcmp(type, resultType));
    free(type);
    return valid;
}

static void VideoReadNegotiatedFeedback(AVCMediaStreamNegotiator *negotiator, ADCVideoRTCPProfile *profile) {
    profile->feedbackKnown = 0; profile->feedbackEnabled = 0;
    @try {
        if (!VideoGetter(negotiator, @selector(mediaNegotiator), @encode(id))) return;
        id media = negotiator.mediaNegotiator;
        Class base = NSClassFromString(@"VCMediaNegotiatorBase");
        if (!base || ![media isKindOfClass:base] || !VideoGetter(media, @selector(negotiatedScreenSettings), @encode(id))) return;
        id screen = [(VCMediaNegotiatorBase *)media negotiatedScreenSettings];
        Class settings = NSClassFromString(@"VCMediaNegotiatorResultsVideo");
        if (!settings || ![screen isKindOfClass:settings] || !VideoGetter(screen, @selector(isRTCPFBEnabled), @encode(BOOL))) return;
        BOOL enabled = [(VCMediaNegotiatorResultsVideo *)screen isRTCPFBEnabled];
        profile->feedbackEnabled = enabled ? 1 : 0;
        profile->feedbackKnown = 1;
    } @catch (__unused NSException *exception) {
        // Unsupported contracts stay unknown; this observation never enables
        // a sender or changes the established receiver-report behavior.
    }
}

int ADCValidateVideoRTCPProfile(const void *borrowed, uint32_t offeredReceiver, uint16_t receiverPort,
                                ADCVideoRTCPProfile *profile, char *error, size_t capacity) {
    if (profile) memset(profile, 0, sizeof(*profile));
    xpc_object_t reply = borrowed ? (__bridge xpc_object_t)borrowed : nil;
    if (!profile || !offeredReceiver || !receiverPort || !reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(reply, "CoreDevice.error"))
        return VideoFail(error, capacity, @"Invalid native RTCP profile reply.");
    xpc_object_t output = xpc_dictionary_get_dictionary(reply, "CoreDevice.output");
    xpc_object_t connection = output ? xpc_dictionary_get_dictionary(output, "connection") : nil;
    xpc_object_t config = connection ? xpc_dictionary_get_dictionary(connection, "streamConfig") : nil;
    uint64_t sender = 0, receiver = 0, port = 0;
    xpc_object_t enabled = config ? xpc_dictionary_get_value(config, "RTCPEnabled") : nil;
    xpc_object_t interval = config ? xpc_dictionary_get_value(config, "RTCPSendInterval") : nil;
    if (!config || !VideoUInt(xpc_dictionary_get_value(config, "LocalSSRC"), &sender) || !sender || sender > UINT32_MAX ||
        !VideoUInt(xpc_dictionary_get_value(config, "RemoteSSRC"), &receiver) || receiver != offeredReceiver || sender == receiver ||
        !VideoUInt(xpc_dictionary_get_value(config, "RTCPRemotePort"), &port) || port != receiverPort ||
        !enabled || xpc_get_type(enabled) != XPC_TYPE_BOOL || !xpc_bool_get_value(enabled) ||
        !interval || xpc_get_type(interval) != XPC_TYPE_DOUBLE)
        return VideoFail(error, capacity, @"Native RTCP reply did not confirm the owned receiver and sender.");
    double seconds = xpc_double_get_value(interval);
    if (!isfinite(seconds) || seconds < 0.2 || seconds > 10)
        return VideoFail(error, capacity, @"Native RTCP report interval is unsupported.");
    profile->senderSSRC = (uint32_t)sender; profile->receiverSSRC = (uint32_t)receiver; profile->reportIntervalSeconds = seconds;
    return 0;
}

int ADCValidateVideoPacketProfile(const void *reply, ADCVideoPacketProfile *profile, char *error, size_t capacity) {
    if (profile) memset(profile, 0, sizeof(*profile));
    xpc_object_t root = reply ? (__bridge xpc_object_t)reply : nil;
    if (!profile || !root || xpc_get_type(root) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(root, "CoreDevice.error"))
        return VideoFail(error, capacity, @"Invalid native RTP profile reply.");
    xpc_object_t output = xpc_dictionary_get_dictionary(root, "CoreDevice.output");
    xpc_object_t connection = output ? xpc_dictionary_get_dictionary(output, "connection") : nil;
    xpc_object_t config = connection ? xpc_dictionary_get_dictionary(connection, "streamConfig") : nil;
    ADCVideoPacketProfile parsed = {0}; uint64_t transport = 0, rtpCipher = 0, rtcpCipher = 0;
    if (!config || !VideoUInt(xpc_dictionary_get_value(config, "TransportProtocolType"), &transport) || transport != 2 ||
        !VideoUInt(xpc_dictionary_get_value(config, "SRTPCipherSuite"), &rtpCipher) || rtpCipher ||
        !VideoUInt(xpc_dictionary_get_value(config, "SRTCPCipherSuite"), &rtcpCipher) || rtcpCipher)
        return VideoFail(error, capacity, @"Native packet probe requires a negotiated unencrypted standard-RTP stream.");
    if (!VideoUInt(xpc_dictionary_get_value(config, "CustomWidth"), &parsed.width) || !parsed.width || parsed.width > 8192 ||
        !VideoUInt(xpc_dictionary_get_value(config, "CustomHeight"), &parsed.height) || !parsed.height || parsed.height > 8192 ||
        parsed.width * parsed.height > 20000000 ||
        !VideoUInt(xpc_dictionary_get_value(config, "Framerate"), &parsed.frameRate) || !parsed.frameRate || parsed.frameRate > 240 ||
        !VideoUInt(xpc_dictionary_get_value(config, "TxPayloadType"), &parsed.payloadType) || parsed.payloadType > 127)
        return VideoFail(error, capacity, @"Native RTP reply has invalid or oversized video metadata.");
    *profile = parsed;
    return 0;
}

static BOOL VideoAddressMatches(xpc_object_t endpoint, const char *expected) {
    const char *text = endpoint ? xpc_dictionary_get_string(endpoint, "ipv6Address") : NULL;
    struct in6_addr actual, address;
    return text && expected && inet_pton(AF_INET6, text, &actual) == 1 &&
        inet_pton(AF_INET6, expected, &address) == 1 && !memcmp(&actual, &address, sizeof(address));
}

int ADCValidateVideoEndpoints(const void *reply, const char *hostAddress, const char *deviceAddress,
                              uint16_t receiverPort, uint16_t *senderPort, char *error, size_t capacity) {
    if (senderPort) *senderPort = 0;
    xpc_object_t root = reply ? (__bridge xpc_object_t)reply : nil;
    if (!root || xpc_get_type(root) != XPC_TYPE_DICTIONARY || !senderPort || !receiverPort ||
        xpc_dictionary_get_value(root, "CoreDevice.error"))
        return VideoFail(error, capacity, @"Invalid native video endpoint reply.");
    xpc_object_t output = xpc_dictionary_get_dictionary(root, "CoreDevice.output");
    xpc_object_t connection = output ? xpc_dictionary_get_dictionary(output, "connection") : nil;
    xpc_object_t sender = connection ? xpc_dictionary_get_dictionary(connection, "sender") : nil;
    xpc_object_t receiver = connection ? xpc_dictionary_get_dictionary(connection, "receiver") : nil;
    xpc_object_t config = connection ? xpc_dictionary_get_dictionary(connection, "streamConfig") : nil;
    uint64_t remote = 0, local = 0, source = 0;
    if (!VideoAddressMatches(sender, deviceAddress) || !VideoAddressMatches(receiver, hostAddress) ||
        !VideoUInt(sender ? xpc_dictionary_get_value(sender, "port") : nil, &remote) || !remote || remote > UINT16_MAX ||
        !VideoUInt(receiver ? xpc_dictionary_get_value(receiver, "port") : nil, &local) || local != receiverPort ||
        !VideoUInt(config ? xpc_dictionary_get_value(config, "SourcePort") : nil, &source) || source != remote)
        return VideoFail(error, capacity, @"Media reply endpoints do not match the selected tunnel and owned receiver.");
    *senderPort = (uint16_t)remote;
    return 0;
}

// One standard-RTP packet session: Apple's negotiator, an owned datagram
// socket and the control channel. Packets are decoded in Swift.
@interface ADCVideoOwner : NSObject
@property(nonatomic, strong) ADCMediaControl *control;
@property(nonatomic, strong) AVCMediaStreamNegotiator *negotiator;
@property(nonatomic, copy) NSString *hostAddress;
@property(nonatomic, copy) NSString *deviceAddress;
@property(nonatomic, strong) NSUUID *clientID;
@property(nonatomic) int socket;
@property(nonatomic) uint16_t receiverPort;
@property(nonatomic) uint32_t ownedIdentifier;
@property(nonatomic) BOOL hasIdentifier;
@property(nonatomic) BOOL startAttempted;
@property(nonatomic) BOOL configured;
@property(nonatomic) ADCVideoPacketProfile packetProfile;
@property(nonatomic) ADCVideoRTCPProfile rtcpProfile;
@property(nonatomic) BOOL closing;
// The device's system audio beside the video, in the same client session:
// a second negotiator, socket and owned stream (ADCStartAudioSession).
@property(nonatomic, strong) AVCMediaStreamNegotiator *audioNegotiator;
@property(nonatomic) int audioSocket;
@property(nonatomic) uint16_t audioReceiverPort;
@property(nonatomic) uint32_t audioIdentifier;
@property(nonatomic) BOOL hasAudioIdentifier;
@property(nonatomic) BOOL audioStartAttempted;
@property(nonatomic) BOOL audioConfigured;
@property(nonatomic) ADCAudioPacketProfile audioProfile;
@property(nonatomic) ADCVideoRTCPProfile audioRTCPProfile;
@property(nonatomic) BOOL hasAudioRTCP;
@end
@implementation ADCVideoOwner
- (instancetype)init {
    if ((self = [super init])) {
        _socket = -1;
        _audioSocket = -1;
        _clientID = NSUUID.UUID;
    }
    return self;
}
- (void)dealloc {
    // The Swift owner must explicitly close. This only releases local resources;
    // deinit is not presented as acknowledged remote cleanup.
    if (_socket >= 0) close(_socket);
    if (_audioSocket >= 0) close(_audioSocket);
    [_control close];
}
@end

static BOOL VideoAPIAvailable(char *error, size_t capacity) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ framework = dlopen("/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference", RTLD_NOW | RTLD_LOCAL); });
    if (!framework) { VideoFail(error, capacity, @"Cannot load installed AVConference; no stream started."); return NO; }
    // Every negotiator method the session later calls is checked here, so a
    // method removed by an OS update fails cleanly instead of raising an
    // unrecognized-selector exception after negotiation has begun.
    NSArray *checks = @[@[@"AVCMediaStreamNegotiator", @"initWithMode:options:error:"],
        @[@"AVCMediaStreamNegotiator", @"createOffer"], @[@"AVCMediaStreamNegotiator", @"offer"],
        @[@"AVCMediaStreamNegotiator", @"setAnswer:withError:"],
        @[@"AVCMediaStreamNegotiator", @"generateMediaStreamConfigurationWithError:"],
        @[@"AVCMediaStreamNegotiator", @"generateMediaStreamInitOptionsWithError:"]];
    for (NSArray *check in checks) {
        Class type = NSClassFromString(check[0]);
        if (!type || ![type instancesRespondToSelector:NSSelectorFromString(check[1])]) {
            VideoFail(error, capacity, [NSString stringWithFormat:@"Installed native media API missing: %@.%@; no stream started.", check[0], check[1]]); return NO;
        }
    }
    Class settings = NSClassFromString(@"AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing");
    if (!settings || ![NSClassFromString(@"AVCMediaStreamNegotiatorSettings") respondsToSelector:@selector(negotiatorSettingsForMode:deviceRole:options:errorString:)] ||
        ![NSClassFromString(@"AVCMediaStreamNegotiator") instancesRespondToSelector:@selector(negotiatorSettings)] ||
        ![NSClassFromString(@"AVCMediaStreamNegotiatorSettings") instancesRespondToSelector:@selector(localSSRC)]) {
        VideoFail(error, capacity, @"Installed Apple screen-sharing negotiation settings are unavailable; no stream started."); return NO;
    }
    return YES;
}

int ADCCreateVideoPacketSession(const char *uuid, const char *version, const char *interface,
                                const char *hostAddress, const char *deviceAddress, int (^cancelled)(void),
                                void **owner, char *error, size_t capacity) {
    if (owner) *owner = NULL;
    struct in6_addr host = {0}, device = {0};
    BOOL validVersion = version && strnlen(version, 64) > 0 && strnlen(version, 64) < 64;
    if (validVersion) {
        BOOL digit = NO;
        for (const char *part = version; *part; part++) {
            if (*part >= '0' && *part <= '9') digit = YES;
            else if (*part == '.' && digit) digit = NO;
            else { validVersion = NO; break; }
        }
        validVersion = validVersion && digit;
    }
    BOOL validUUID = uuid && strnlen(uuid, 37) == 36 && [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid]] != nil;
    if (!owner || !validUUID || !validVersion || !interface || strnlen(interface, IFNAMSIZ) >= IFNAMSIZ || strncmp(interface, "utun", 4) ||
        !hostAddress || !deviceAddress || inet_pton(AF_INET6, hostAddress, &host) != 1 || inet_pton(AF_INET6, deviceAddress, &device) != 1 ||
        IN6_IS_ADDR_UNSPECIFIED(&host) || IN6_IS_ADDR_MULTICAST(&host) || IN6_IS_ADDR_UNSPECIFIED(&device) || IN6_IS_ADDR_MULTICAST(&device) ||
        memcmp(&host, &device, 8) || !memcmp(&host, &device, sizeof(host)) || (cancelled && cancelled()))
        return VideoFail(error, capacity, @"Invalid or cancelled native video endpoint; no media resources opened.");
    if (![NSThread isMainThread]) return VideoFail(error, capacity, @"Native video lifecycle must run on the main thread.");
    if (!VideoAPIAvailable(error, capacity)) return 1;
    unsigned index = if_nametoindex(interface);
    if (!index) return VideoFail(error, capacity, @"Selected media tunnel interface is unavailable.");
    ADCVideoOwner *state = [ADCVideoOwner new];
    state.hostAddress = [NSString stringWithUTF8String:hostAddress]; state.deviceAddress = [NSString stringWithUTF8String:deviceAddress];
    state.control = [ADCMediaControl openUUID:uuid version:version streaming:YES cancelled:cancelled error:error capacity:capacity];
    if (!state.control) return 1;
    state.socket = socket(AF_INET6, SOCK_DGRAM, 0);
    int flags = state.socket >= 0 ? fcntl(state.socket, F_GETFL) : -1;
    if (flags < 0 || fcntl(state.socket, F_SETFL, flags | O_NONBLOCK) || fcntl(state.socket, F_SETFD, FD_CLOEXEC))
        return VideoFail(error, capacity, @"Cannot create owned nonblocking video socket.");
    int receiveBuffer = 1024 * 1024;
    if (setsockopt(state.socket, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, sizeof(receiveBuffer)))
        return VideoFail(error, capacity, @"Cannot configure the bounded video receive buffer.");
    struct sockaddr_in6 address = {0}; address.sin6_len = sizeof(address); address.sin6_family = AF_INET6;
    address.sin6_addr = host; address.sin6_scope_id = index;
    socklen_t length = sizeof(address);
    if (bind(state.socket, (struct sockaddr *)&address, sizeof(address)) || getsockname(state.socket, (struct sockaddr *)&address, &length))
        return VideoFail(error, capacity, @"Cannot bind the fresh native media tunnel endpoint.");
    state.receiverPort = ntohs(address.sin6_port);
    NSError *failure = nil;
    NSDictionary *negotiation = @{@"AVCMediaStreamNegotiatorTransportProtocolType": @2,
        @"AVCMediaStreamNegotiatorAccessNetworkType": @1};
    // The settings' operatingMode and the negotiator's mode are different enums.
    // The installed factory has a bounded 1...16 table. Resolve its concrete
    // screen-sharing class locally, without generating offers for other modes.
    Class settingsClass = NSClassFromString(@"AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing");
    Class factory = NSClassFromString(@"AVCMediaStreamNegotiatorSettings");
    long mode = 0;
    for (long candidate = 1; candidate <= 16; candidate++) {
        NSString *reason = nil;
        id settings = [factory negotiatorSettingsForMode:candidate deviceRole:1 options:negotiation errorString:&reason];
        if ([settings isKindOfClass:settingsClass]) { mode = candidate; break; }
    }
    if (!mode) return VideoFail(error, capacity, @"Installed Apple settings factory did not resolve screen sharing; no stream started.");
    ADCVideoPacketProfile profile = {0}; profile.negotiatorMode = (uint64_t)mode; state.packetProfile = profile;
    state.negotiator = [[NSClassFromString(@"AVCMediaStreamNegotiator") alloc] initWithMode:mode options:negotiation error:&failure];
    if (![state.negotiator.negotiatorSettings isKindOfClass:settingsClass])
        return VideoFail(error, capacity, @"Apple negotiator selected a different media mode; no stream started.");
    if (!state.negotiator || ![state.negotiator createOffer] || ![state.negotiator.offer isKindOfClass:NSData.class] ||
        !state.negotiator.offer.length || state.negotiator.offer.length > 1048576)
        return VideoFail(error, capacity, @"Apple media negotiator did not create a bounded offer.");
    *owner = (void *)CFBridgingRetain(state);
    return 0;
}

// Apple's negotiator offers, for the HEVC payload, the feature `VRAE`:
// VideoToolbox's resolution adaptation, with which a sender changes the
// picture's size between key frames and the receiver's decoder has to be
// told each frame's size. An Apple TV 4K uses it, and a standard decoder
// then shows its pictures on top of each other. This takes the feature out
// of the offer, whose blob is cached when the negotiator is made and so is
// made again, before the stream is started.
int ADCOfferVideoWithoutResolutionAdaptation(void *owner, char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || state.closing || state.startAttempted || ![NSThread isMainThread])
        return VideoFail(error, capacity, @"The video offer cannot be changed now; no stream started.");
    @try {
        id media = [(id)state.negotiator valueForKey:@"mediaNegotiator"];
        id local = [media valueForKey:@"localSettings"];
        SEL selector = NSSelectorFromString(@"mediaConfigurationForMediaType:");
        if (!local || ![local respondsToSelector:selector] || ![media respondsToSelector:NSSelectorFromString(@"negotiationData")])
            return VideoFail(error, capacity, @"Installed Apple negotiator has no local video configuration; no stream started.");
        NSRegularExpression *feature = [NSRegularExpression regularExpressionWithPattern:@"VRAE(:-?[0-9]+)?;" options:0 error:nil];
        BOOL changed = NO;
        // The two screen media types of the screen-sharing settings.
        for (uint8_t type = 2; type <= 3; type++) {
            id configuration = ((id (*)(id, SEL, uint8_t))objc_msgSend)(local, selector, type);
            NSDictionary *strings = [configuration valueForKey:@"videoFeatureStrings"];
            if (![strings isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *plain = [NSMutableDictionary dictionary];
            for (id key in strings) {
                id value = strings[key];
                if ([value isKindOfClass:NSString.class]) {
                    NSString *without = [feature stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, [value length]) withTemplate:@""];
                    if (![without isEqualToString:value]) changed = YES;
                    value = without;
                }
                plain[key] = value;
            }
            [configuration setValue:plain forKey:@"videoFeatureStrings"];
        }
        if (!changed) return 0;
        NSData *blob = [media valueForKey:@"negotiationData"];
        if (![blob isKindOfClass:NSData.class] || !blob.length || blob.length > 1048576)
            return VideoFail(error, capacity, @"Apple negotiator gave no bounded blob for the changed offer; no stream started.");
        [(id)state.negotiator setValue:blob forKey:@"mediaBlobCompressed"];
        if (![state.negotiator createOffer] || ![state.negotiator.offer isKindOfClass:NSData.class] ||
            !state.negotiator.offer.length || state.negotiator.offer.length > 1048576)
            return VideoFail(error, capacity, @"Apple media negotiator did not create the changed offer; no stream started.");
        return 0;
    } @catch (__unused NSException *exception) {
        return VideoFail(error, capacity, @"Installed Apple negotiator refused the changed offer; no stream started.");
    }
}

int ADCStartVideoSession(void *owner, int64_t displayID, int (^cancelled)(void), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || state.closing || state.startAttempted || displayID <= 0 || ![NSThread isMainThread] || (cancelled && cancelled()))
        return VideoFail(error, capacity, @"Native video start refused before mutation.");
    uint64_t deadline = VideoNow() + 20ULL * NSEC_PER_SEC;
    xpc_object_t support = [state.control requestAction:"com.apple.coredevice.action.mediastreamgetsupportinfo" input:xpc_dictionary_create_empty() deadline:deadline cancelled:cancelled error:error capacity:capacity];
    if (!support) return 1;
    xpc_object_t status = [state.control requestAction:"com.apple.coredevice.action.mediastreamstatus" input:xpc_dictionary_create_empty() deadline:deadline cancelled:cancelled error:error capacity:capacity];
    ADCMediaInspection baseline;
    if (!status || ADCValidateMediaInspection((__bridge const void *)support, (__bridge const void *)status, &baseline, error, capacity)) return 1;
    // The only session there may be is this owner's audio stream, started first.
    if (baseline.sessionCount != (state.hasAudioIdentifier ? 1 : 0) || (baseline.running && !state.hasAudioIdentifier))
        return VideoFail(error, capacity, @"Another media session is active; no recording started or existing stream stopped.");
    xpc_object_t input = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(input, "receiverIP", state.hostAddress.UTF8String); xpc_dictionary_set_uint64(input, "receiverPort", state.receiverPort);
    xpc_dictionary_set_string(input, "senderIP", state.deviceAddress.UTF8String); xpc_dictionary_set_uint64(input, "senderPort", 51000);
    xpc_dictionary_set_uint64(input, "timeout", 30); xpc_dictionary_set_string(input, "type", "video"); xpc_dictionary_set_string(input, "direction", "output");
    NSData *offer = state.negotiator.offer;
    xpc_dictionary_set_data(input, "negotiatorOffer", offer.bytes, offer.length);
    // 140 is the observed standard-RTP reference advertisement; support flags
    // are not interpreted as proof of recording or decoding availability.
    xpc_dictionary_set_uint64(input, "clientSupportedFeatures", 140);
    xpc_object_t options = xpc_dictionary_create_empty(), client = xpc_dictionary_create_empty();
    uuid_t bytes; [state.clientID getUUIDBytes:bytes]; xpc_dictionary_set_uuid(client, "uuid", bytes);
    // Current Apple utilities expose these display-selection keys. Values use
    // CoreDevice's CodableValue envelope, as does the native UUID option.
    xpc_object_t mode = xpc_dictionary_create_empty(), display = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(mode, "string", "DisplayByID");
    xpc_dictionary_set_int64(display, "int", displayID);
    xpc_dictionary_set_value(options, "CoreDeviceVideoDisplayMode", mode);
    xpc_dictionary_set_value(options, "VideoStreamForDisplayID", display);
    xpc_object_t transport = xpc_dictionary_create_empty(), network = xpc_dictionary_create_empty();
    xpc_dictionary_set_int64(transport, "int", 2); xpc_dictionary_set_int64(network, "int", 1);
    xpc_dictionary_set_value(options, "AVCMediaStreamNegotiatorTransportProtocolType", transport);
    xpc_dictionary_set_value(options, "AVCMediaStreamNegotiatorAccessNetworkType", network);
    xpc_dictionary_set_value(options, "avcMediaStreamOptionClientSessionID", client); xpc_dictionary_set_value(input, "options", options);
    if (cancelled && cancelled()) return VideoFail(error, capacity, @"Native video cancelled before start submission.");
    state.startAttempted = YES;
    xpc_object_t reply = [state.control requestAction:"com.apple.coredevice.action.mediastreamstart" input:input deadline:VideoNow() + 8ULL * NSEC_PER_SEC cancelled:cancelled error:error capacity:capacity];
    if (!reply) return 1;
    xpc_object_t output = xpc_dictionary_get_dictionary(reply, "CoreDevice.output");
    xpc_object_t connection = output ? xpc_dictionary_get_dictionary(output, "connection") : nil;
    xpc_object_t config = connection ? xpc_dictionary_get_dictionary(connection, "streamConfig") : nil;
    uint64_t identifier = 0;
    if (!config || !VideoUInt(xpc_dictionary_get_value(config, "RemoteSSRC"), &identifier) || identifier > UINT32_MAX)
        return VideoFail(error, capacity, @"Media start reply has no owned stream identifier; start outcome/cleanup may be unknown.");
    state.ownedIdentifier = (uint32_t)identifier; state.hasIdentifier = YES;
    uint16_t senderPort = 0;
    if (ADCValidateVideoEndpoints((__bridge const void *)reply, state.hostAddress.UTF8String,
        state.deviceAddress.UTF8String, state.receiverPort, &senderPort, error, capacity)) return 1;
    ADCVideoPacketProfile profile;
    if (ADCValidateVideoPacketProfile((__bridge const void *)reply, &profile, error, capacity)) return 1;
    profile.negotiatorMode = state.packetProfile.negotiatorMode;
    state.packetProfile = profile;
    ADCVideoRTCPProfile feedback;
    AVCMediaStreamNegotiatorSettings *negotiated = state.negotiator.negotiatorSettings;
    if (ADCValidateVideoRTCPProfile((__bridge const void *)reply, negotiated.localSSRC, state.receiverPort, &feedback, error, capacity)) return 1;
    state.rtcpProfile = feedback;
    size_t answerLength = 0;
    const void *answer = xpc_dictionary_get_data(output, "negotiatorAnswer", &answerLength);
    if (!answer || !answerLength || answerLength > 1048576) return VideoFail(error, capacity, @"Media start reply has no bounded negotiator answer.");
    NSError *failure = nil;
    if (![state.negotiator setAnswer:[NSData dataWithBytes:answer length:answerLength] withError:&failure])
        return VideoFail(error, capacity, @"Apple media negotiator refused the answer.");
    VideoReadNegotiatedFeedback(state.negotiator, &feedback);
    state.rtcpProfile = feedback;
    id configuration = [state.negotiator generateMediaStreamConfigurationWithError:&failure];
    id initial = [state.negotiator generateMediaStreamInitOptionsWithError:&failure];
    if (!configuration || ![initial isKindOfClass:NSDictionary.class]) return VideoFail(error, capacity, @"Apple media configuration is unavailable.");
    // Match installed NetworkUtils.withSharedSocketDictionary: connect to the
    // validated negotiated peer without waiting for an unsolicited datagram.
    struct sockaddr_in6 peer = {0}; peer.sin6_len = sizeof(peer); peer.sin6_family = AF_INET6;
    inet_pton(AF_INET6, state.deviceAddress.UTF8String, &peer.sin6_addr);
    peer.sin6_port = htons(senderPort);
    struct sockaddr_in6 local = {0}; socklen_t localLength = sizeof(local);
    if (getsockname(state.socket, (struct sockaddr *)&local, &localLength))
        return VideoFail(error, capacity, @"Cannot inspect the owned video socket scope.");
    peer.sin6_scope_id = local.sin6_scope_id;
    if (cancelled && cancelled()) return VideoFail(error, capacity, @"Native video cancelled before the media socket was connected.");
    if (connect(state.socket, (struct sockaddr *)&peer, sizeof(peer))) return VideoFail(error, capacity, @"Cannot connect the owned video media socket.");
    state.configured = YES;
    return 0;
}

// The device's system audio as a second stream of the same client session,
// started before the video as Apple's Device Hub starts it
// (docs/recording.md#sound). Its negotiator is the one AVConference keeps for
// a CoreDevice's system audio; the socket is a second one, because the video
// socket is connected to the video's sender. Nothing is played or muted on
// the device by it.
int ADCStartAudioSession(void *owner, int (^cancelled)(void), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || state.closing || state.startAttempted || state.audioStartAttempted || ![NSThread isMainThread] || (cancelled && cancelled()))
        return VideoFail(error, capacity, @"Native audio start refused before mutation.");
    Class settingsClass = NSClassFromString(@"AVCMediaStreamNegotiatorSettingsCoreDeviceSystemAudio");
    Class factory = NSClassFromString(@"AVCMediaStreamNegotiatorSettings");
    if (!settingsClass) return VideoFail(error, capacity, @"Installed Apple system-audio negotiation settings are unavailable; no stream started.");
    NSDictionary *negotiation = @{@"AVCMediaStreamNegotiatorTransportProtocolType": @2, @"AVCMediaStreamNegotiatorAccessNetworkType": @1};
    long mode = 0;
    for (long candidate = 1; candidate <= 16; candidate++) {
        NSString *reason = nil;
        id settings = [factory negotiatorSettingsForMode:candidate deviceRole:1 options:negotiation errorString:&reason];
        if ([settings isKindOfClass:settingsClass]) { mode = candidate; break; }
    }
    if (!mode) return VideoFail(error, capacity, @"Installed Apple settings factory did not resolve system audio; no stream started.");
    NSError *failure = nil;
    state.audioNegotiator = [[NSClassFromString(@"AVCMediaStreamNegotiator") alloc] initWithMode:mode options:negotiation error:&failure];
    if (!state.audioNegotiator || ![state.audioNegotiator.negotiatorSettings isKindOfClass:settingsClass] || ![state.audioNegotiator createOffer] ||
        ![state.audioNegotiator.offer isKindOfClass:NSData.class] || !state.audioNegotiator.offer.length || state.audioNegotiator.offer.length > 1048576)
        return VideoFail(error, capacity, @"Apple media negotiator did not create a bounded audio offer; no stream started.");
    // A second socket on the same tunnel address and interface as the video's.
    struct sockaddr_in6 address = {0}; socklen_t length = sizeof(address);
    if (getsockname(state.socket, (struct sockaddr *)&address, &length)) return VideoFail(error, capacity, @"Cannot inspect the owned video socket; no audio stream started.");
    address.sin6_port = 0;
    state.audioSocket = socket(AF_INET6, SOCK_DGRAM, 0);
    int flags = state.audioSocket >= 0 ? fcntl(state.audioSocket, F_GETFL) : -1;
    int receiveBuffer = 256 * 1024;
    if (flags < 0 || fcntl(state.audioSocket, F_SETFL, flags | O_NONBLOCK) || fcntl(state.audioSocket, F_SETFD, FD_CLOEXEC) ||
        setsockopt(state.audioSocket, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, sizeof(receiveBuffer)) ||
        bind(state.audioSocket, (struct sockaddr *)&address, sizeof(address)) || getsockname(state.audioSocket, (struct sockaddr *)&address, &length))
        return VideoFail(error, capacity, @"Cannot create and bind the owned audio socket; no stream started.");
    state.audioReceiverPort = ntohs(address.sin6_port);
    uint64_t deadline = VideoNow() + 20ULL * NSEC_PER_SEC;
    xpc_object_t support = [state.control requestAction:"com.apple.coredevice.action.mediastreamgetsupportinfo" input:xpc_dictionary_create_empty() deadline:deadline cancelled:cancelled error:error capacity:capacity];
    if (!support) return 1;
    xpc_object_t status = [state.control requestAction:"com.apple.coredevice.action.mediastreamstatus" input:xpc_dictionary_create_empty() deadline:deadline cancelled:cancelled error:error capacity:capacity];
    ADCMediaInspection baseline;
    if (!status || ADCValidateMediaInspection((__bridge const void *)support, (__bridge const void *)status, &baseline, error, capacity)) return 1;
    if (baseline.running || baseline.sessionCount) return VideoFail(error, capacity, @"Another media session is active; no recording started or existing stream stopped.");
    xpc_object_t input = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(input, "receiverIP", state.hostAddress.UTF8String); xpc_dictionary_set_uint64(input, "receiverPort", state.audioReceiverPort);
    // No sender port is named: Apple's Device Hub names none for either stream.
    xpc_dictionary_set_string(input, "senderIP", state.deviceAddress.UTF8String);
    xpc_dictionary_set_uint64(input, "timeout", 30); xpc_dictionary_set_string(input, "type", "audio"); xpc_dictionary_set_string(input, "direction", "output");
    NSData *offer = state.audioNegotiator.offer;
    xpc_dictionary_set_data(input, "negotiatorOffer", offer.bytes, offer.length);
    xpc_dictionary_set_uint64(input, "clientSupportedFeatures", 140);
    xpc_object_t options = xpc_dictionary_create_empty(), client = xpc_dictionary_create_empty();
    uuid_t bytes; [state.clientID getUUIDBytes:bytes]; xpc_dictionary_set_uuid(client, "uuid", bytes);
    xpc_object_t transport = xpc_dictionary_create_empty(), network = xpc_dictionary_create_empty();
    xpc_dictionary_set_int64(transport, "int", 2); xpc_dictionary_set_int64(network, "int", 1);
    xpc_dictionary_set_value(options, "AVCMediaStreamNegotiatorTransportProtocolType", transport);
    xpc_dictionary_set_value(options, "AVCMediaStreamNegotiatorAccessNetworkType", network);
    xpc_dictionary_set_value(options, "avcMediaStreamOptionClientSessionID", client); xpc_dictionary_set_value(input, "options", options);
    if (cancelled && cancelled()) return VideoFail(error, capacity, @"Native audio cancelled before start submission.");
    state.audioStartAttempted = YES;
    xpc_object_t reply = [state.control requestAction:"com.apple.coredevice.action.mediastreamstart" input:input deadline:VideoNow() + 8ULL * NSEC_PER_SEC cancelled:cancelled error:error capacity:capacity];
    if (!reply) return 1;
    xpc_object_t output = xpc_dictionary_get_dictionary(reply, "CoreDevice.output");
    xpc_object_t connection = output ? xpc_dictionary_get_dictionary(output, "connection") : nil;
    xpc_object_t config = connection ? xpc_dictionary_get_dictionary(connection, "streamConfig") : nil;
    uint64_t identifier = 0, payload = 0;
    if (!config || !VideoUInt(xpc_dictionary_get_value(config, "RemoteSSRC"), &identifier) || identifier > UINT32_MAX)
        return VideoFail(error, capacity, @"Audio start reply has no owned stream identifier; start outcome/cleanup may be unknown.");
    state.audioIdentifier = (uint32_t)identifier; state.hasAudioIdentifier = YES;
    uint16_t senderPort = 0;
    if (ADCValidateVideoEndpoints((__bridge const void *)reply, state.hostAddress.UTF8String,
        state.deviceAddress.UTF8String, state.audioReceiverPort, &senderPort, error, capacity)) return 1;
    if (!VideoUInt(xpc_dictionary_get_value(config, "TxPayloadType"), &payload) || payload > 127)
        return VideoFail(error, capacity, @"Audio start reply names no RTP payload type.");
    size_t answerLength = 0;
    const void *answer = xpc_dictionary_get_data(output, "negotiatorAnswer", &answerLength);
    if (!answer || !answerLength || answerLength > 1048576) return VideoFail(error, capacity, @"Audio start reply has no bounded negotiator answer.");
    // The stream's RTCP sender and receiver, for receiver reports: without
    // them the device ended the audio stream about 30 s in (2026-11-21).
    // Optional: a reply that names none starts the stream as before.
    ADCVideoRTCPProfile audioFeedback;
    char ignored[256] = {0};
    AVCMediaStreamNegotiatorSettings *audioSettings = state.audioNegotiator.negotiatorSettings;
    if ([audioSettings respondsToSelector:@selector(localSSRC)] &&
        !ADCValidateVideoRTCPProfile((__bridge const void *)reply, audioSettings.localSSRC,
                                     state.audioReceiverPort, &audioFeedback, ignored, sizeof(ignored))) {
        state.audioRTCPProfile = audioFeedback; state.hasAudioRTCP = YES;
    }
    if (![state.audioNegotiator setAnswer:[NSData dataWithBytes:answer length:answerLength] withError:&failure])
        return VideoFail(error, capacity, @"Apple media negotiator refused the audio answer.");
    // What was agreed is in the negotiator, not in the reply: the codec by
    // AVConference's own number, the channels and the packet's duration.
    ADCAudioPacketProfile profile = {0};
    profile.payloadType = payload; profile.streamIdentifier = identifier;
    @try {
        NSDictionary *initial = [state.audioNegotiator generateMediaStreamInitOptionsWithError:&failure];
        id configuration = [state.audioNegotiator generateMediaStreamConfigurationWithError:&failure];
        NSNumber *(^number)(NSString *) = ^NSNumber *(NSString *key) {
            id value = [initial isKindOfClass:NSDictionary.class] ? initial[key] : nil;
            if (![value isKindOfClass:NSNumber.class] && [configuration isKindOfClass:NSDictionary.class]) value = ((NSDictionary *)configuration)[key];
            return [value isKindOfClass:NSNumber.class] ? value : nil;
        };
        profile.codecType = number(@"vcMediaStreamCodecType").unsignedLongLongValue;
        profile.channels = number(@"vcMediaStreamChannelCount").unsignedLongLongValue;
        profile.packetMilliseconds = number(@"vcMediaStreamPtime").unsignedLongLongValue;
        Class utilities = NSClassFromString(@"VCPayloadUtils");
        SEL rate = NSSelectorFromString(@"sampleRateForPayload:");
        if ([utilities respondsToSelector:rate]) profile.sampleRate = (uint64_t)((unsigned int (*)(id, SEL, int))objc_msgSend)(utilities, rate, (int)payload);
    } @catch (__unused NSException *exception) {
        // The stream is started; a profile left at zero says the values are unknown.
    }
    state.audioProfile = profile;
    struct sockaddr_in6 peer = {0}; peer.sin6_len = sizeof(peer); peer.sin6_family = AF_INET6;
    inet_pton(AF_INET6, state.deviceAddress.UTF8String, &peer.sin6_addr);
    peer.sin6_port = htons(senderPort); peer.sin6_scope_id = address.sin6_scope_id;
    if (connect(state.audioSocket, (struct sockaddr *)&peer, sizeof(peer))) return VideoFail(error, capacity, @"Cannot connect the owned audio media socket.");
    state.audioConfigured = YES;
    return 0;
}

int ADCCopyNextAudioPacket(void *owner, void (^sink)(const uint8_t *, size_t), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !state.audioConfigured || state.closing || !sink || ![NSThread isMainThread]) {
        VideoFail(error, capacity, @"Native audio packet read is unavailable."); return -1;
    }
    uint8_t packet[65535];
    ssize_t count = recv(state.audioSocket, packet, sizeof(packet), MSG_DONTWAIT);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    if (count <= 0) { VideoFail(error, capacity, @"Native audio datagram receive failed."); return -1; }
    sink(packet, (size_t)count);
    return 1;
}

int ADCReadAudioPacketProfile(void *owner, ADCAudioPacketProfile *profile) {
    if (profile) memset(profile, 0, sizeof(*profile));
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !profile || !state.audioConfigured || state.closing || ![NSThread isMainThread]) return 1;
    *profile = state.audioProfile;
    return 0;
}

int ADCReadAudioRTCPProfile(void *owner, ADCVideoRTCPProfile *profile) {
    if (profile) memset(profile, 0, sizeof(*profile));
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !profile || !state.audioConfigured || !state.hasAudioRTCP || state.closing || ![NSThread isMainThread]) return 1;
    *profile = state.audioRTCPProfile;
    return 0;
}

int ADCSendAudioReceiverReport(void *owner, const uint8_t *packet, size_t length, int (^cancelled)(void), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !state.audioConfigured || !state.hasAudioRTCP || state.closing || ![NSThread isMainThread] || (cancelled && cancelled())) {
        VideoFail(error, capacity, @"Native audio RTCP report send is unavailable or cancelled."); return -1;
    }
    if (ADCValidateVideoReceiverReport(packet, length, state.audioRTCPProfile.senderSSRC, state.audioRTCPProfile.receiverSSRC, error, capacity)) return -1;
    ssize_t count = send(state.audioSocket, packet, length, MSG_DONTWAIT);
    if (count < 0 && (errno == EAGAIN || errno == EINTR || errno == ENOBUFS)) return 0;
    if (count != (ssize_t)length) { VideoFail(error, capacity, @"Native audio RTCP receiver report send failed."); return -1; }
    return 1;
}

int ADCCopyNextVideoPacket(void *owner, int (^cancelled)(void), void (^sink)(const uint8_t *, size_t), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !state.configured || state.closing || !sink || ![NSThread isMainThread] || (cancelled && cancelled())) {
        VideoFail(error, capacity, @"Native video packet read is unavailable or cancelled."); return -1;
    }
    uint8_t packet[65535];
    ssize_t count = recv(state.socket, packet, sizeof(packet), MSG_DONTWAIT);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    if (count <= 0) { VideoFail(error, capacity, @"Native video datagram receive failed."); return -1; }
    sink(packet, (size_t)count);
    return 1;
}

int ADCReadVideoPacketProfile(void *owner, ADCVideoPacketProfile *profile) {
    if (profile) memset(profile, 0, sizeof(*profile));
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !profile || state.closing || ![NSThread isMainThread]) return 1;
    *profile = state.packetProfile;
    return 0;
}

int ADCReadVideoRTCPProfile(void *owner, ADCVideoRTCPProfile *profile) {
    if (profile) memset(profile, 0, sizeof(*profile));
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !state.configured || state.closing || !profile || ![NSThread isMainThread]) return 1;
    *profile = state.rtcpProfile;
    return 0;
}

int ADCValidateVideoReceiverReport(const uint8_t *packet, size_t length, uint32_t sender, uint32_t receiver, char *error, size_t capacity) {
    if (!packet || length < 20 || length > 1024 || !sender || !receiver || sender == receiver)
        return VideoFail(error, capacity, @"Native RTCP compound report bounds are invalid.");
    // Only compound RR + SDES packets generated by our receiver are accepted.
    size_t first = (((size_t)packet[2] << 8) | packet[3]) * 4 + 4;
    uint32_t source = ((uint32_t)packet[4] << 24) | ((uint32_t)packet[5] << 16) | ((uint32_t)packet[6] << 8) | packet[7];
    if (packet[0] >> 6 != 2 || packet[1] != 201 || (packet[0] & 63) > 1 || first != 8 + (packet[0] & 31) * 24 ||
        first > length - 12 || source != receiver || packet[first] != 0x81 || packet[first + 1] != 202 ||
        ((((size_t)packet[first + 2] << 8) | packet[first + 3]) + 1) * 4 != length - first) {
        return VideoFail(error, capacity, @"Native RTCP compound receiver report is invalid.");
    }
    if (first == 32) {
        uint32_t target = ((uint32_t)packet[8] << 24) | ((uint32_t)packet[9] << 16) | ((uint32_t)packet[10] << 8) | packet[11];
        if (target != sender) return VideoFail(error, capacity, @"Native RTCP report block refers to another sender.");
    }
    uint32_t cnameSource = ((uint32_t)packet[first + 4] << 24) | ((uint32_t)packet[first + 5] << 16) | ((uint32_t)packet[first + 6] << 8) | packet[first + 7];
    size_t end = first + 10 + packet[first + 9];
    if (cnameSource != source || packet[first + 8] != 1 || !packet[first + 9] || end >= length || packet[end] != 0)
        return VideoFail(error, capacity, @"Native RTCP CNAME differs from its owned receiver or is invalid.");
    for (size_t i = end; i < length; i++) if (packet[i]) return VideoFail(error, capacity, @"Native RTCP CNAME padding is invalid.");
    return 0;
}

int ADCSendVideoReceiverReport(void *owner, const uint8_t *packet, size_t length, int (^cancelled)(void), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || !state.configured || state.closing || ![NSThread isMainThread] || (cancelled && cancelled())) {
        VideoFail(error, capacity, @"Native RTCP report send is unavailable or cancelled."); return -1;
    }
    if (ADCValidateVideoReceiverReport(packet, length, state.rtcpProfile.senderSSRC, state.rtcpProfile.receiverSSRC, error, capacity)) return -1;
    ssize_t count = send(state.socket, packet, length, MSG_DONTWAIT);
    if (count < 0 && (errno == EAGAIN || errno == EINTR || errno == ENOBUFS)) return 0;
    if (count != (ssize_t)length) { VideoFail(error, capacity, @"Native RTCP receiver report send failed."); return -1; }
    return 1;
}

int ADCValidateOwnedVideoStatus(const void *borrowed, uint32_t ownedIdentifier, char *error, size_t capacity) {
    xpc_object_t reply = borrowed ? (__bridge xpc_object_t)borrowed : nil;
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(reply, "CoreDevice.error")) {
        VideoFail(error, capacity, @"Native video status reply failed or is unsupported."); return -1;
    }
    xpc_object_t output = xpc_dictionary_get_dictionary(reply, "CoreDevice.output");
    xpc_object_t sessions = output ? xpc_dictionary_get_array(output, "sessions") : nil;
    xpc_object_t running = output ? xpc_dictionary_get_value(output, "running") : nil;
    if (!sessions || xpc_array_get_count(sessions) > 128 || !running || xpc_get_type(running) != XPC_TYPE_BOOL) {
        VideoFail(error, capacity, @"Native video status inventory is invalid or unavailable."); return -1;
    }
    size_t matches = 0;
    for (size_t i = 0; i < xpc_array_get_count(sessions); i++) {
        xpc_object_t session = xpc_array_get_value(sessions, i);
        if (!session || xpc_get_type(session) != XPC_TYPE_DICTIONARY) {
            VideoFail(error, capacity, @"Native video status contains an unsupported session."); return -1;
        }
        xpc_object_t connection = xpc_dictionary_get_dictionary(session, "connection");
        xpc_object_t config = connection ? xpc_dictionary_get_dictionary(connection, "streamConfig") : nil;
        uint64_t identifier = 0;
        if (!config || !VideoUInt(xpc_dictionary_get_value(config, "RemoteSSRC"), &identifier) || identifier > UINT32_MAX) {
            VideoFail(error, capacity, @"Native video status cannot establish stream ownership."); return -1;
        }
        if (identifier == ownedIdentifier) matches++;
    }
    if (matches > 1) { VideoFail(error, capacity, @"Native video ownership is ambiguous."); return -1; }
    return matches == 1 && xpc_bool_get_value(running) ? 1 : 0;
}

int ADCVideoSessionActive(void *owner, int (^cancelled)(void), char *error, size_t capacity) {
    ADCVideoOwner *state = owner ? (__bridge ADCVideoOwner *)owner : nil;
    if (!state || state.closing || !state.hasIdentifier || ![NSThread isMainThread]) {
        VideoFail(error, capacity, @"Native video status has no active owner."); return -1;
    }
    xpc_object_t reply = [state.control requestAction:"com.apple.coredevice.action.mediastreamstatus" input:xpc_dictionary_create_empty()
        deadline:VideoNow() + 4ULL * NSEC_PER_SEC cancelled:cancelled error:error capacity:capacity];
    return ADCValidateOwnedVideoStatus(reply ? (__bridge const void *)reply : NULL, state.ownedIdentifier, error, capacity);
}

int ADCCloseVideoSession(void *owner, ADCVideoCleanup *result, char *error, size_t capacity) {
    if (result) memset(result, 0, sizeof(*result));
    if (!owner) return 0;
    ADCVideoOwner *state = CFBridgingRelease(owner);
    state.closing = YES;
    if (result) result->startAttempted = state.startAttempted || state.audioStartAttempted;
    BOOL confirmed = !state.startAttempted;
    // The audio stream beside the video is stopped by its own identifier,
    // in the same request, and has to be acknowledged too.
    BOOL audioConfirmed = !state.audioStartAttempted;
    @try {
        if (state.hasIdentifier || state.hasAudioIdentifier) {
            xpc_object_t input = xpc_dictionary_create_empty(), identifiers = xpc_array_create_empty();
            xpc_dictionary_set_bool(input, "stopAll", false);
            if (state.hasIdentifier) xpc_array_append_value(identifiers, xpc_uint64_create(state.ownedIdentifier));
            if (state.hasAudioIdentifier) xpc_array_append_value(identifiers, xpc_uint64_create(state.audioIdentifier));
            xpc_dictionary_set_value(input, "identifiers", identifiers);
            xpc_object_t reply = [state.control requestAction:"com.apple.coredevice.action.mediastreamstop" input:input deadline:VideoNow() + 4ULL * NSEC_PER_SEC cancelled:nil error:error capacity:capacity];
            xpc_object_t output = reply ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : nil;
            xpc_object_t stopped = output ? xpc_dictionary_get_array(output, "stoppedStreams") : nil;
            if (stopped && xpc_array_get_count(stopped) <= 128) {
                for (size_t i = 0; i < xpc_array_get_count(stopped); i++) {
                    uint64_t identifier;
                    if (!VideoUInt(xpc_array_get_value(stopped, i), &identifier)) continue;
                    if (state.hasIdentifier && identifier == state.ownedIdentifier) confirmed = YES;
                    if (state.hasAudioIdentifier && identifier == state.audioIdentifier) audioConfirmed = YES;
                }
            }
            if (result && confirmed && audioConfirmed) result->stopAcknowledged = 1;
            // A fresh server-status read is stronger than the stop carrier ack.
            xpc_object_t status = [state.control requestAction:"com.apple.coredevice.action.mediastreamstatus" input:xpc_dictionary_create_empty() deadline:VideoNow() + 4ULL * NSEC_PER_SEC cancelled:nil error:error capacity:capacity];
            xpc_object_t info = status ? xpc_dictionary_get_dictionary(status, "CoreDevice.output") : nil;
            xpc_object_t sessions = info ? xpc_dictionary_get_array(info, "sessions") : nil;
            if (sessions && xpc_array_get_count(sessions) == 0) { if (result) result->ownedStreamAbsent = 1; }
        }
    } @finally {
        if (state.socket >= 0) { close(state.socket); state.socket = -1; }
        if (state.audioSocket >= 0) { close(state.audioSocket); state.audioSocket = -1; }
        [state.control close];
    }
    // Which acknowledgement is missing: on 2026-11-21 a recording with sound
    // ended with no stream left on the device and its stop unconfirmed, and
    // the message did not say whether the video or the sound was not named.
    if (!confirmed || !audioConfirmed) {
        NSString *missing = [NSString stringWithFormat:@"Owned media stop is unconfirmed (video named: %@, sound named: %@); no stop-all fallback was sent.",
            confirmed ? @"yes" : @"no", state.audioStartAttempted ? (audioConfirmed ? @"yes" : @"no") : @"no sound stream"];
        return VideoFail(error, capacity, missing);
    }
    return 0;
}

int ADCReadVideoOwnedIdentifier(void *owner, uint32_t *identifier) {
    if (!owner || !identifier) return 1;
    ADCVideoOwner *state = (__bridge ADCVideoOwner *)owner;
    if (!state.hasIdentifier) return 1;
    *identifier = state.ownedIdentifier;
    return 0;
}

int ADCStopVideoStreamByIdentifier(const char *uuid, const char *version, uint32_t identifier, int (^cancelled)(void),
                                   ADCVideoCleanup *result, char *error, size_t capacity) {
    @autoreleasepool {
        if (result) memset(result, 0, sizeof(*result));
        if (result) result->startAttempted = 1;
        ADCMediaControl *control = [ADCMediaControl openUUID:uuid version:version streaming:NO cancelled:cancelled error:error capacity:capacity];
        if (!control) return 1;
        BOOL confirmed = NO;
        @try {
            // The one owned stream, by its identifier; never stop-all.
            xpc_object_t input = xpc_dictionary_create_empty(), identifiers = xpc_array_create_empty();
            xpc_dictionary_set_bool(input, "stopAll", false);
            xpc_array_append_value(identifiers, xpc_uint64_create(identifier));
            xpc_dictionary_set_value(input, "identifiers", identifiers);
            xpc_object_t reply = [control requestAction:"com.apple.coredevice.action.mediastreamstop" input:input deadline:VideoNow() + 4ULL * NSEC_PER_SEC cancelled:cancelled error:error capacity:capacity];
            xpc_object_t output = reply ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : nil;
            xpc_object_t stopped = output ? xpc_dictionary_get_array(output, "stoppedStreams") : nil;
            if (stopped && xpc_array_get_count(stopped) <= 128) {
                for (size_t i = 0; i < xpc_array_get_count(stopped); i++) {
                    uint64_t value;
                    if (VideoUInt(xpc_array_get_value(stopped, i), &value) && value == identifier) confirmed = YES;
                }
            }
            if (result && confirmed) result->stopAcknowledged = 1;
            xpc_object_t status = [control requestAction:"com.apple.coredevice.action.mediastreamstatus" input:xpc_dictionary_create_empty() deadline:VideoNow() + 4ULL * NSEC_PER_SEC cancelled:cancelled error:error capacity:capacity];
            xpc_object_t info = status ? xpc_dictionary_get_dictionary(status, "CoreDevice.output") : nil;
            xpc_object_t sessions = info ? xpc_dictionary_get_array(info, "sessions") : nil;
            if (sessions && xpc_array_get_count(sessions) == 0 && result) result->ownedStreamAbsent = 1;
        } @finally { [control close]; }
        if (!confirmed) return VideoFail(error, capacity, @"The owned stream's stop by identifier was not acknowledged; no stop-all was sent.");
        return 0;
    }
}
