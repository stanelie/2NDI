#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

// Which NDI dylib backs this session. Chosen once at launch, because loading both
// libraries into one process means two independent NDI discovery stacks.
typedef NS_ENUM(NSInteger, NDIBackend) {
	NDIBackendBase     NS_SWIFT_NAME(base)     = 0, // libndi.dylib          — SpeedHQ only, no runtime limit
	NDIBackendAdvanced NS_SWIFT_NAME(advanced) = 1, // libndi_advanced.dylib — adds HX, 30-min dev-licence cutoff
};

typedef NS_ENUM(NSInteger, NDICodec) {
	NDICodecSpeedHQ NS_SWIFT_NAME(speedHQ) = 0, // uncompressed frames handed to NDI, which encodes SpeedHQ
	NDICodecH264    NS_SWIFT_NAME(h264)    = 1, // HX: we encode, NDI passes the bitstream through
	NDICodecHEVC    NS_SWIFT_NAME(hevc)    = 2,
};

@interface NDISender : NSObject

// Loads the dylib and calls NDIlib_initialize. Idempotent; the first successful call
// fixes the backend for the life of the process.
+ (BOOL)loadBackend:(NDIBackend)backend error:(NSString * _Nullable * _Nullable)error;
+ (BOOL)isLoaded;
+ (NDIBackend)loadedBackend;
// NO when the loaded dylib does not export the HX entry points, i.e. the base SDK.
+ (BOOL)supportsCompressedSend;
+ (NSString *)libraryVersion;

- (nullable instancetype)initWithName:(NSString *)ndiName;

@property (readonly) NSString *ndiName;

// SpeedHQ path. Reads straight out of the IOSurface for the duration of the call,
// so the caller must not recycle it until this returns.
- (void)sendUncompressedSurface:(IOSurfaceRef)surface
                     ignoreAlpha:(BOOL)ignoreAlpha
                      frameRateN:(NSInteger)frameRateN
                      frameRateD:(NSInteger)frameRateD;

// HX path. data is Annex B; extra is the SPS/PPS (H.264) or VPS/SPS/PPS (HEVC)
// parameter set, required on keyframes and ignored otherwise.
- (void)sendCompressed:(const void *)data
                  size:(uint32_t)size
                 extra:(nullable const void *)extra
             extraSize:(uint32_t)extraSize
              keyframe:(BOOL)keyframe
                   pts:(int64_t)pts
                   dts:(int64_t)dts
                  xres:(NSInteger)xres
                  yres:(NSInteger)yres
            frameRateN:(NSInteger)frameRateN
            frameRateD:(NSInteger)frameRateD
                 codec:(NDICodec)codec;

// Receivers ask for an IDR through the SDK; poll this and force one when it goes YES.
- (BOOL)keyframeRequiredForCodec:(NDICodec)codec xres:(NSInteger)xres yres:(NSInteger)yres
	NS_SWIFT_NAME(keyframeRequired(for:xres:yres:));

// NDI's own view of a sensible bit rate for this format, in bits/sec. Used both to
// seed the encoder and as the reference figure in the stats panel.
- (NSInteger)targetBitRateForCodec:(NDICodec)codec
                        xres:(NSInteger)xres
                        yres:(NSInteger)yres
                  frameRateN:(NSInteger)frameRateN
                  frameRateD:(NSInteger)frameRateD
	NS_SWIFT_NAME(targetBitRate(for:xres:yres:frameRateN:frameRateD:));

@property (readonly) NSInteger connectionCount;

- (void)stop;
@end

/// Receives this app's own output to confirm frames are genuinely being delivered.
///
/// There is no way to learn this from the sender. Measured against a library patched to
/// expire early: after delivery stopped dead, `NDIlib_send_get_no_connections` still
/// reported 1 receiver for minutes, every send call still returned normally, and the
/// library printed nothing. The only certain evidence is a receiver actually getting
/// frames, so the app becomes one.
///
/// The receiver asks for compressed passthrough, so frames are counted without being
/// decoded and the cost is a loopback copy rather than a second codec.
@interface NDIDeliveryMonitor : NSObject

/// @param ndiName The sender's name, as passed to NDISender.
- (nullable instancetype)initWithSourceName:(NSString *)ndiName;

/// NO until the monitor has found and connected to the source.
@property (readonly) BOOL isConnected;

/// Frames delivered since the previous call, resetting the counter.
- (NSInteger)takeFrameCount;

- (void)stop;
@end

NS_ASSUME_NONNULL_END
