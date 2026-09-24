#import "SyphonInput.h"
#import <Syphon/Syphon.h>

@implementation SyphonSource

- (instancetype)initWithDescription:(NSDictionary *)desc
{
	self = [super init];
	if (!self) return nil;
	_serverDescription = desc;
	_uuid = desc[SyphonServerDescriptionUUIDKey] ?: @"";
	_name = desc[SyphonServerDescriptionNameKey] ?: @"";
	_appName = desc[SyphonServerDescriptionAppNameKey] ?: @"";

	// Servers commonly publish an app name with an empty server name (QLab does this for
	// its stage outputs), so build the label from whichever parts actually exist.
	if (_name.length && _appName.length)
		_displayName = [NSString stringWithFormat:@"%@ — %@", _appName, _name];
	else
		_displayName = _appName.length ? _appName : (_name.length ? _name : @"Untitled Syphon source");

	return self;
}

@end

@implementation SyphonInput {
	SyphonMetalClient *_client;
}

+ (NSArray<SyphonSource *> *)availableSources
{
	NSArray *descriptions = [[SyphonServerDirectory sharedDirectory] servers];
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:descriptions.count];
	for (NSDictionary *desc in descriptions)
		[out addObject:[[SyphonSource alloc] initWithDescription:desc]];

	[out sortUsingComparator:^NSComparisonResult(SyphonSource *a, SyphonSource *b) {
		return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
	}];
	return out;
}

- (instancetype)initWithSource:(SyphonSource *)source
                        device:(id<MTLDevice>)device
                  frameHandler:(void (^)(void))handler
{
	self = [super init];
	if (!self) return nil;
	_source = source;

	// The handler fires on a Syphon-owned thread; the pipeline hops to its own queue.
	_client = [[SyphonMetalClient alloc] initWithServerDescription:source.serverDescription
	                                                        device:device
	                                                       options:nil
	                                               newFrameHandler:^(SyphonMetalClient *c) {
		if (handler) handler();
	}];
	return _client ? self : nil;
}

- (BOOL)isValid
{
	return _client.isValid;
}

- (id<MTLTexture>)newFrameTexture
{
	return [_client newFrameImage];
}

- (void)stop
{
	[_client stop];
	_client = nil;
}

@end
