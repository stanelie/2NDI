#import "NDISender.h"
#import <dlfcn.h>
#import <Processing.NDI.Advanced.h>

// The two SDKs export the same C symbols, so they cannot both be linked. We compile
// against the Advanced headers (a superset) and bind the entry points with dlsym at
// launch, which also makes "is HX available?" a straightforward NULL check rather
// than a build-time flag.
typedef bool (*fn_initialize)(void);
typedef void (*fn_destroy)(void);
typedef const char* (*fn_version)(void);
typedef NDIlib_send_instance_t (*fn_send_create)(const NDIlib_send_create_t*);
typedef void (*fn_send_destroy)(NDIlib_send_instance_t);
typedef void (*fn_send_video)(NDIlib_send_instance_t, const NDIlib_video_frame_v2_t*);
typedef int  (*fn_send_connections)(NDIlib_send_instance_t, uint32_t);
typedef void (*fn_send_scatter)(NDIlib_send_instance_t, const NDIlib_video_frame_v2_t*, const NDIlib_frame_scatter_t*);
typedef bool (*fn_send_keyframe_required)(NDIlib_send_instance_t, const NDIlib_video_frame_v2_t*);
typedef int  (*fn_send_target_bit_rate)(NDIlib_send_instance_t, const NDIlib_video_frame_v2_t*);
typedef NDIlib_find_instance_t (*fn_find_create)(const NDIlib_find_create_t*);
typedef void (*fn_find_destroy)(NDIlib_find_instance_t);
typedef bool (*fn_find_wait)(NDIlib_find_instance_t, uint32_t);
typedef const NDIlib_source_t* (*fn_find_sources)(NDIlib_find_instance_t, uint32_t*);
typedef NDIlib_recv_instance_t (*fn_recv_create)(const NDIlib_recv_create_v3_t*);
typedef void (*fn_recv_destroy)(NDIlib_recv_instance_t);
typedef NDIlib_frame_type_e (*fn_recv_capture)(NDIlib_recv_instance_t, NDIlib_video_frame_v2_t*, NDIlib_audio_frame_v3_t*, NDIlib_metadata_frame_t*, uint32_t);
typedef void (*fn_recv_free_video)(NDIlib_recv_instance_t, const NDIlib_video_frame_v2_t*);

static struct {
	void *handle;
	NDIBackend backend;
	BOOL loaded;

	fn_initialize             initialize;
	fn_destroy                destroy;
	fn_version                version;
	fn_send_create            send_create;
	fn_send_destroy           send_destroy;
	fn_send_video             send_video;
	fn_send_connections       send_connections;
	// Advanced only — NULL under the base SDK.
	fn_send_scatter           send_scatter;
	fn_send_keyframe_required send_keyframe_required;
	fn_send_target_bit_rate   send_target_bit_rate;

	// Used by NDIDeliveryMonitor to receive our own output.
	fn_find_create     find_create;
	fn_find_destroy    find_destroy;
	fn_find_wait       find_wait;
	fn_find_sources    find_sources;
	fn_recv_create     recv_create;
	fn_recv_destroy    recv_destroy;
	fn_recv_capture    recv_capture;
	fn_recv_free_video recv_free_video;
} g;

static NSString *DylibPathForBackend(NDIBackend backend)
{
	// The app bundle carries both dylibs; fall back to an installed SDK for a dev run
	// straight out of the build directory.
	NSString *leaf = (backend == NDIBackendAdvanced) ? @"libndi_advanced.dylib" : @"libndi.dylib";
	NSString *bundled = [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:leaf];
	if ([[NSFileManager defaultManager] fileExistsAtPath:bundled]) return bundled;

	NSString *sdk = (backend == NDIBackendAdvanced) ? @"/Library/NDI Advanced SDK for Apple" : @"/Library/NDI SDK for Apple";
	return [sdk stringByAppendingFormat:@"/lib/macOS/%@", leaf];
}

@implementation NDISender {
	NDIlib_send_instance_t _send;
}

+ (BOOL)loadBackend:(NDIBackend)backend error:(NSString * _Nullable * _Nullable)error
{
	if (g.loaded) {
		if (g.backend != backend && error)
			*error = @"A different NDI library is already loaded in this process.";
		return g.backend == backend;
	}

	NSString *path = DylibPathForBackend(backend);
	// RTLD_LOCAL keeps these symbols out of the global namespace, so a later load of
	// the other SDK could not silently bind to this one.
	void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
	if (!handle) {
		if (error) *error = [NSString stringWithFormat:@"Could not load %@: %s", path, dlerror()];
		return NO;
	}

	g.handle = handle;
	g.backend = backend;

	#define BIND(field, sym) g.field = (typeof(g.field))dlsym(handle, sym)
	BIND(initialize,             "NDIlib_initialize");
	BIND(destroy,                "NDIlib_destroy");
	BIND(version,                "NDIlib_version");
	BIND(send_create,            "NDIlib_send_create");
	BIND(send_destroy,           "NDIlib_send_destroy");
	BIND(send_video,             "NDIlib_send_send_video_v2");
	BIND(send_connections,       "NDIlib_send_get_no_connections");
	BIND(send_scatter,           "NDIlib_send_send_video_scatter");
	BIND(send_keyframe_required, "NDIlib_send_is_keyframe_required");
	BIND(send_target_bit_rate,   "NDIlib_send_get_target_bit_rate");
	BIND(find_create,            "NDIlib_find_create_v2");
	BIND(find_destroy,           "NDIlib_find_destroy");
	BIND(find_wait,              "NDIlib_find_wait_for_sources");
	BIND(find_sources,           "NDIlib_find_get_current_sources");
	BIND(recv_create,            "NDIlib_recv_create_v3");
	BIND(recv_destroy,           "NDIlib_recv_destroy");
	BIND(recv_capture,           "NDIlib_recv_capture_v2");
	BIND(recv_free_video,        "NDIlib_recv_free_video_v2");
	#undef BIND

	if (!g.initialize || !g.send_create || !g.send_video || !g.send_destroy) {
		if (error) *error = [NSString stringWithFormat:@"%@ is missing required NDI entry points.", path.lastPathComponent];
		dlclose(handle);
		g.handle = NULL;
		return NO;
	}

	if (!g.initialize()) {
		if (error) *error = @"NDIlib_initialize() failed — this CPU may be unsupported.";
		dlclose(handle);
		g.handle = NULL;
		return NO;
	}

	g.loaded = YES;
	return YES;
}

+ (BOOL)isLoaded { return g.loaded; }
+ (NDIBackend)loadedBackend { return g.backend; }
+ (BOOL)supportsCompressedSend { return g.loaded && g.send_scatter != NULL; }

+ (NSString *)libraryVersion
{
	if (!g.loaded || !g.version) return @"not loaded";
	return [NSString stringWithUTF8String:g.version()];
}

- (instancetype)initWithName:(NSString *)ndiName
{
	self = [super init];
	if (!self) return nil;
	if (!g.loaded) return nil;

	_ndiName = [ndiName copy];

	NDIlib_send_create_t desc = {0};
	desc.p_ndi_name = ndiName.UTF8String;
	desc.p_groups = NULL;
	// The Syphon server is the clock: frames are sent as the host app produces them.
	// Letting NDI clock the stream would add a queue in front of the wire and make the
	// latency figures measure our own buffering rather than the codec's.
	desc.clock_video = false;
	desc.clock_audio = false;

	_send = g.send_create(&desc);
	return _send ? self : nil;
}

- (void)sendUncompressedSurface:(IOSurfaceRef)surface
                     ignoreAlpha:(BOOL)ignoreAlpha
                      frameRateN:(NSInteger)frameRateN
                      frameRateD:(NSInteger)frameRateD
{
	if (!_send || !surface) return;

	IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);

	NDIlib_video_frame_v2_t frame = {0};
	frame.xres = (int)IOSurfaceGetWidth(surface);
	frame.yres = (int)IOSurfaceGetHeight(surface);
	// BGRX tells receivers to ignore the alpha channel. Syphon sources routinely carry
	// a meaningless or zeroed alpha, which shows up as a black or keyed-out image
	// downstream, so this is the safer default.
	frame.FourCC = ignoreAlpha ? NDIlib_FourCC_type_BGRX : NDIlib_FourCC_type_BGRA;
	frame.frame_rate_N = (int)frameRateN;
	frame.frame_rate_D = (int)frameRateD;
	frame.picture_aspect_ratio = (float)frame.xres / (float)frame.yres;
	frame.frame_format_type = NDIlib_frame_format_type_progressive;
	frame.timecode = NDIlib_send_timecode_synthesize;
	frame.p_data = (uint8_t *)IOSurfaceGetBaseAddress(surface);
	frame.line_stride_in_bytes = (int)IOSurfaceGetBytesPerRow(surface);

	// Synchronous: NDI is done with the pixels when this returns, so the caller may
	// immediately recycle the surface.
	g.send_video(_send, &frame);

	IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
}

static NDIlib_FourCC_video_type_e VideoFourCCForCodec(NDICodec codec, BOOL preview)
{
	switch (codec) {
		case NDICodecHEVC: return (NDIlib_FourCC_video_type_e)(preview
			? NDIlib_FourCC_video_type_ex_HEVC_lowest_bandwidth
			: NDIlib_FourCC_video_type_ex_HEVC_highest_bandwidth);
		case NDICodecH264: return (NDIlib_FourCC_video_type_e)(preview
			? NDIlib_FourCC_video_type_ex_H264_lowest_bandwidth
			: NDIlib_FourCC_video_type_ex_H264_highest_bandwidth);
		default:           return NDIlib_FourCC_type_BGRX;
	}
}

- (void)sendCompressed:(const void *)data
                  size:(uint32_t)size
                 extra:(const void *)extra
             extraSize:(uint32_t)extraSize
              keyframe:(BOOL)keyframe
                   pts:(int64_t)pts
                   dts:(int64_t)dts
                  xres:(NSInteger)xres
                  yres:(NSInteger)yres
            frameRateN:(NSInteger)frameRateN
            frameRateD:(NSInteger)frameRateD
                 codec:(NDICodec)codec
               preview:(BOOL)preview
{
	if (!_send || !g.send_scatter || !data || size == 0) return;

	NDIlib_compressed_packet_t packet = {0};
	packet.version = sizeof(NDIlib_compressed_packet_t);
	packet.fourCC = (codec == NDICodecHEVC) ? NDIlib_compressed_FourCC_type_HEVC
	                                        : NDIlib_compressed_FourCC_type_H264;
	packet.pts = pts;
	packet.dts = dts;
	packet.flags = keyframe ? 1 /* flags_keyframe */ : 0;
	// Parameter sets belong only on keyframes; the SDK expects 0 elsewhere.
	const BOOL withParameterSets = (keyframe && extra && extraSize);
	packet.extra_data_size = withParameterSets ? extraSize : 0;
	// The parameter sets go in the bitstream *as well as* in extra_data, so data_size
	// counts them. NDI's own HX2 reference sender does this — its keyframes carry
	// [SPS][PPS][IDR] in the data and SPS/PPS again in extra_data — and a decoder handed
	// only the elementary stream cannot determine the format without them. VideoToolbox
	// emits them out-of-band only, so sending them the way it hands them over produced a
	// stream that NDI's own software receivers decoded happily (they read extra_data)
	// while a hardware decoder reported "video decoder not found".
	packet.data_size = withParameterSets ? (extraSize + size) : size;

	// Header, parameter sets, bitstream, parameter sets again — the layout the reference
	// sender uses.
	const uint8_t *blocks[5];
	int sizes[5];
	int n = 0;
	blocks[n] = (const uint8_t *)&packet;  sizes[n] = (int)sizeof(packet);        n++;
	if (withParameterSets) {
		blocks[n] = (const uint8_t *)extra; sizes[n] = (int)extraSize;             n++;
	}
	blocks[n] = (const uint8_t *)data;     sizes[n] = (int)size;                  n++;
	if (withParameterSets) {
		blocks[n] = (const uint8_t *)extra; sizes[n] = (int)extraSize;             n++;
	}
	blocks[n] = NULL; sizes[n] = 0;

	NDIlib_video_frame_v2_t frame = {0};
	frame.xres = (int)xres;
	frame.yres = (int)yres;
	frame.FourCC = VideoFourCCForCodec(codec, preview);
	frame.frame_rate_N = (int)frameRateN;
	frame.frame_rate_D = (int)frameRateD;
	frame.picture_aspect_ratio = (float)xres / (float)yres;
	frame.frame_format_type = NDIlib_frame_format_type_progressive;
	// pts is already in 100 ns units, which is exactly NDI's timecode base.
	frame.timecode = pts;

	NDIlib_frame_scatter_t scatter = { blocks, sizes };
	g.send_scatter(_send, &frame, &scatter);
}

- (BOOL)keyframeRequiredForCodec:(NDICodec)codec xres:(NSInteger)xres yres:(NSInteger)yres
                         preview:(BOOL)preview
{
	if (!_send || !g.send_keyframe_required) return NO;

	NDIlib_video_frame_v2_t frame = {0};
	frame.xres = (int)xres;
	frame.yres = (int)yres;
	frame.FourCC = VideoFourCCForCodec(codec, preview);
	return g.send_keyframe_required(_send, &frame);
}

- (NSInteger)targetBitRateForCodec:(NDICodec)codec
                        xres:(NSInteger)xres
                        yres:(NSInteger)yres
                  frameRateN:(NSInteger)frameRateN
                  frameRateD:(NSInteger)frameRateD
{
	if (!_send || !g.send_target_bit_rate) return 0;

	NDIlib_video_frame_v2_t frame = {0};
	frame.xres = (int)xres;
	frame.yres = (int)yres;
	frame.FourCC = VideoFourCCForCodec(codec, NO);
	frame.frame_rate_N = (int)frameRateN;
	frame.frame_rate_D = (int)frameRateD;
	frame.frame_format_type = NDIlib_frame_format_type_progressive;
	return g.send_target_bit_rate(_send, &frame);
}

- (NSInteger)connectionCount
{
	if (!_send || !g.send_connections) return 0;
	return g.send_connections(_send, 0);
}

- (void)stop
{
	if (_send) {
		g.send_destroy(_send);
		_send = NULL;
	}
}

- (void)dealloc
{
	[self stop];
}

@end

@implementation NDIDeliveryMonitor {
	NSString *_ndiName;
	NDIlib_recv_instance_t _recv;
	NSThread *_thread;
	NSLock *_lock;
	NSInteger _frames;
	BOOL _connected;
	BOOL _stopping;
}

- (instancetype)initWithSourceName:(NSString *)ndiName
{
	self = [super init];
	if (!self) return nil;
	if (!g.loaded || !g.find_create || !g.recv_create || !g.recv_capture) return nil;

	_ndiName = [ndiName copy];
	_lock = [[NSLock alloc] init];

	_thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
	_thread.name = @"ca.exmachina.syphonndi.delivery-monitor";
	[_thread start];
	return self;
}

- (void)run
{
	@autoreleasepool {
		// Find our own sender. It is on this machine, so local sources must be visible.
		NDIlib_find_create_t find_desc = {0};
		find_desc.show_local_sources = true;
		NDIlib_find_instance_t finder = g.find_create(&find_desc);
		if (!finder) return;

		NDIlib_source_t source = {0};
		char name_buffer[256] = {0};

		while (!_stopping && !_recv) {
			if (g.find_wait) g.find_wait(finder, 1000);
			uint32_t count = 0;
			const NDIlib_source_t *sources = g.find_sources(finder, &count);
			for (uint32_t i = 0; i < count && !_recv; i++) {
				if (!sources[i].p_ndi_name) continue;
				// NDI publishes as "HOST (name)", so match the name we were given.
				if (!strstr(sources[i].p_ndi_name, _ndiName.UTF8String)) continue;

				strncpy(name_buffer, sources[i].p_ndi_name, sizeof(name_buffer) - 1);
				source.p_ndi_name = name_buffer;
				source.p_url_address = NULL;

				NDIlib_recv_create_v3_t recv_desc = {0};
				recv_desc.source_to_connect_to = source;
				// Passthrough: frames are counted, never decoded, so this costs a copy
				// rather than a second codec running alongside the encoder.
				recv_desc.color_format = g.send_scatter
					? (NDIlib_recv_color_format_e)NDIlib_recv_color_format_ex_compressed_v4
					: NDIlib_recv_color_format_BGRX_BGRA;
				recv_desc.bandwidth = NDIlib_recv_bandwidth_highest;
				recv_desc.allow_video_fields = false;
				_recv = g.recv_create(&recv_desc);
			}
		}
		if (finder && g.find_destroy) g.find_destroy(finder);
		if (!_recv) return;

		[_lock lock]; _connected = YES; [_lock unlock];

		while (!_stopping) {
			NDIlib_video_frame_v2_t video = {0};
			NDIlib_frame_type_e type = g.recv_capture(_recv, &video, NULL, NULL, 200);
			if (type == NDIlib_frame_type_video) {
				[_lock lock]; _frames++; [_lock unlock];
				if (g.recv_free_video) g.recv_free_video(_recv, &video);
			}
		}

		if (g.recv_destroy) g.recv_destroy(_recv);
		_recv = NULL;
	}
}

- (BOOL)isConnected
{
	[_lock lock];
	BOOL connected = _connected;
	[_lock unlock];
	return connected;
}

- (NSInteger)takeFrameCount
{
	[_lock lock];
	NSInteger frames = _frames;
	_frames = 0;
	[_lock unlock];
	return frames;
}

- (void)stop
{
	_stopping = YES;
}

- (void)dealloc
{
	[self stop];
}

@end
