#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// One entry from the Syphon server directory, flattened for the UI.
@interface SyphonSource : NSObject
@property (readonly) NSString *uuid;        // stable identity, never shown to the user
@property (readonly) NSString *name;        // server name, e.g. "Main output"
@property (readonly) NSString *appName;     // host app, e.g. "Millumin"
@property (readonly) NSString *displayName; // "Millumin — Main output"
@property (readonly) NSDictionary *serverDescription;
@end

// Wraps SyphonMetalClient. Frames arrive as MTLTextures owned by the Syphon server's
// surface ring, so the pipeline must copy out of them before the next frame lands.
@interface SyphonInput : NSObject

// Snapshot of the shared directory. Observe SyphonServerAnnounce/Update/Retire
// notifications to know when to re-read it.
+ (NSArray<SyphonSource *> *)availableSources;

- (nullable instancetype)initWithSource:(SyphonSource *)source
                        device:(id<MTLDevice>)device
                  frameHandler:(void (^)(void))handler;

@property (readonly) BOOL isValid;
@property (readonly) SyphonSource *source;

// +1 retained; nil when the server has not published a new frame.
- (nullable id<MTLTexture>)newFrameTexture;

- (void)stop;
@end

NS_ASSUME_NONNULL_END
