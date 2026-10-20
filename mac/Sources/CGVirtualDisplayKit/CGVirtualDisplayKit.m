#import "CGVirtualDisplayKit.h"

// Interfaces of the private CoreGraphics classes (macOS 11+). Only messages are
// sent to them; class objects are resolved at runtime, so nothing here links
// against private symbols.

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation MSMVirtualDisplayMode

- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate {
    if ((self = [super init])) {
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}

@end

@implementation MSMVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(uint32_t)maxPixelsWide
                        maxPixelsHigh:(uint32_t)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                            serialNum:(uint32_t)serialNum
                                queue:(dispatch_queue_t)queue
                   terminationHandler:(nullable void (^)(void))terminationHandler {
    if (!MSMVirtualDisplay.isSupported) {
        return nil;
    }
    if ((self = [super init])) {
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        [descriptor setDispatchQueue:queue];
        descriptor.name = name;
        descriptor.maxPixelsWide = maxPixelsWide;
        descriptor.maxPixelsHigh = maxPixelsHigh;
        descriptor.sizeInMillimeters = sizeInMillimeters;
        descriptor.vendorID = vendorID;
        descriptor.productID = productID;
        descriptor.serialNum = serialNum;
        if (terminationHandler) {
            void (^handler)(void) = [terminationHandler copy];
            descriptor.terminationHandler = ^(__unused id sender, __unused CGVirtualDisplay *display) {
                handler();
            };
        }

        _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (_display == nil || _display.displayID == kCGNullDirectDisplay) {
            return nil;
        }
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

- (BOOL)applyModes:(NSArray<MSMVirtualDisplayMode *> *)modes hiDPI:(BOOL)hiDPI {
    NSMutableArray *nativeModes = [NSMutableArray arrayWithCapacity:modes.count];
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    for (MSMVirtualDisplayMode *mode in modes) {
        CGVirtualDisplayMode *nativeMode = [[modeClass alloc] initWithWidth:mode.width
                                                                     height:mode.height
                                                                refreshRate:mode.refreshRate];
        if (nativeMode) {
            [nativeModes addObject:nativeMode];
        }
    }

    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = nativeModes;
    return [_display applySettings:settings];
}

@end
