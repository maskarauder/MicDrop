// WebRTC symbol stubs for x86_64 iOS Simulator builds.
//
// Modern WebRTC releases (including the pinned Shiguredo m155 build) distribute native xcframework
// slices for iOS device (arm64) and Apple Silicon simulator (arm64), omitting deprecated x86_64 simulator
// slices. On Intel (x86_64) macOS hosts, compiling the application
// target for iphonesimulator links against architecture x86_64.
//
// Unit tests in MicDropAppTests do not instantiate WebRTC native engines; they test pure Swift models,
// controllers, and transports with in-memory fakes. These empty symbols satisfy the linker for
// x86_64 iphonesimulator builds without modifying the genuine arm64 device or arm64 simulator builds.

#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR && defined(__x86_64__)
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RTCTlsCertPolicy) {
    RTCTlsCertPolicySecure = 0,
    RTCTlsCertPolicyInsecureNoCheck,
};

@interface RTCAudioDeviceModule : NSObject
@end
@implementation RTCAudioDeviceModule
@end

@interface RTCAudioSessionConfiguration : NSObject
@end
@implementation RTCAudioSessionConfiguration
@end

@interface RTCAudioSession : NSObject
+ (instancetype)sharedInstance;
@end
@implementation RTCAudioSession
+ (instancetype)sharedInstance {
    return nil;
}
@end

@interface RTCAudioTrack : NSObject
@end
@implementation RTCAudioTrack
@end

@interface RTCIceServer : NSObject
@property(nonatomic, copy) NSArray<NSString *> *urlStrings;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *credential;
@property(nonatomic, copy) NSString *hostname;
@property(nonatomic, assign) RTCTlsCertPolicy tlsCertPolicy;

- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings;
- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings
                          username:(NSString *)username
                        credential:(NSString *)credential;
- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings
                          username:(NSString *)username
                        credential:(NSString *)credential
                     tlsCertPolicy:(RTCTlsCertPolicy)tlsCertPolicy;
- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings
                          username:(NSString *)username
                        credential:(NSString *)credential
                     tlsCertPolicy:(RTCTlsCertPolicy)tlsCertPolicy
                          hostname:(NSString *)hostname;
@end

@implementation RTCIceServer
- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings {
    return [self initWithURLStrings:urlStrings username:nil credential:nil tlsCertPolicy:RTCTlsCertPolicySecure hostname:nil];
}

- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings
                          username:(NSString *)username
                        credential:(NSString *)credential {
    return [self initWithURLStrings:urlStrings username:username credential:credential tlsCertPolicy:RTCTlsCertPolicySecure hostname:nil];
}

- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings
                          username:(NSString *)username
                        credential:(NSString *)credential
                     tlsCertPolicy:(RTCTlsCertPolicy)tlsCertPolicy {
    return [self initWithURLStrings:urlStrings username:username credential:credential tlsCertPolicy:tlsCertPolicy hostname:nil];
}

- (instancetype)initWithURLStrings:(NSArray<NSString *> *)urlStrings
                          username:(NSString *)username
                        credential:(NSString *)credential
                     tlsCertPolicy:(RTCTlsCertPolicy)tlsCertPolicy
                          hostname:(NSString *)hostname {
    self = [super init];
    if (self) {
        _urlStrings = [urlStrings copy];
        _username = [username copy];
        _credential = [credential copy];
        _tlsCertPolicy = tlsCertPolicy;
        _hostname = [hostname copy];
    }
    return self;
}
@end

@interface RTCConfiguration : NSObject
@property(nonatomic, copy) NSArray<RTCIceServer *> *iceServers;
@property(nonatomic, assign) NSInteger iceTransportPolicy;
@property(nonatomic, assign) NSInteger bundlePolicy;
@property(nonatomic, assign) NSInteger rtcpMuxPolicy;
@property(nonatomic, assign) NSInteger tcpCandidatePolicy;
@property(nonatomic, assign) NSInteger candidateNetworkPolicy;
@property(nonatomic, assign) NSInteger continualGatheringPolicy;
@property(nonatomic, assign) NSInteger sdpSemantics;
@property(nonatomic, assign) BOOL audioJitterBufferFastAccelerate;
@property(nonatomic, assign) int32_t audioJitterBufferMaxPackets;
@end
@implementation RTCConfiguration
@end

@interface RTCIceCandidate : NSObject
@property(nonatomic, readonly, copy) NSString *sdpMid;
@property(nonatomic, readonly) int sdpMLineIndex;
@property(nonatomic, readonly, copy) NSString *sdp;
- (instancetype)initWithSdp:(NSString *)sdp sdpMLineIndex:(int)sdpMLineIndex sdpMid:(NSString *)sdpMid;
@end
@implementation RTCIceCandidate
- (instancetype)initWithSdp:(NSString *)sdp sdpMLineIndex:(int)sdpMLineIndex sdpMid:(NSString *)sdpMid {
    self = [super init];
    if (self) {
        _sdp = [sdp copy];
        _sdpMLineIndex = sdpMLineIndex;
        _sdpMid = [sdpMid copy];
    }
    return self;
}
@end

@interface RTCMediaConstraints : NSObject
@end
@implementation RTCMediaConstraints
@end

@interface RTCPeerConnectionFactoryOptions : NSObject
@end
@implementation RTCPeerConnectionFactoryOptions
@end

@interface RTCPeerConnectionFactory : NSObject
@end
@implementation RTCPeerConnectionFactory
@end

@interface RTCRtpCodecCapability : NSObject
@end
@implementation RTCRtpCodecCapability
@end

@interface RTCRtpTransceiverInit : NSObject
@end
@implementation RTCRtpTransceiverInit
@end

@interface RTCRtpTransceiver : NSObject
@end
@implementation RTCRtpTransceiver
@end

@interface RTCSessionDescription : NSObject
@property(nonatomic, readonly) NSInteger type;
@property(nonatomic, readonly, copy) NSString *sdp;
- (instancetype)initWithType:(NSInteger)type sdp:(NSString *)sdp;
@end
@implementation RTCSessionDescription
- (instancetype)initWithType:(NSInteger)type sdp:(NSString *)sdp {
    self = [super init];
    if (self) {
        _type = type;
        _sdp = [sdp copy];
    }
    return self;
}
@end

@interface RTCStatistics : NSObject
@end
@implementation RTCStatistics
@end

void RTCInitializeSSL(void);
void RTCInitializeSSL(void) {}

void RTCSetMinDebugLogLevel(int level);
void RTCSetMinDebugLogLevel(int level) {
    (void)level;
}

NSString * const kRTCMediaStreamTrackKindAudio = @"audio";

#endif
