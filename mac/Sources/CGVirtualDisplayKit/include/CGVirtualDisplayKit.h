// Public, stable wrapper around the private CGVirtualDisplay API in CoreGraphics.
//
// The private classes are looked up at runtime (NSClassFromString), so the app
// still launches on systems where they are missing; `MSMVirtualDisplay.isSupported`
// reports whether virtual displays can be created.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One display mode offered by a virtual display. Width and height are in pixels.
@interface MSMVirtualDisplayMode : NSObject
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Owns one virtual display. The display disappears when this object is deallocated.
@interface MSMVirtualDisplay : NSObject

/// `YES` when the CGVirtualDisplay classes are available on this system.
@property (class, nonatomic, readonly) BOOL isSupported;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Creates a virtual display. Returns nil if the system refuses to create it.
/// - Parameters:
///   - maxPixelsWide/maxPixelsHigh: largest backing size (pixels) of any mode that will be applied.
///   - sizeInMillimeters: physical size reported to macOS (drives the default scale).
///   - vendorID/productID/serialNum: identify the display; macOS remembers arrangement per identity.
///   - terminationHandler: called on `queue` if the system tears the display down.
- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(uint32_t)maxPixelsWide
                        maxPixelsHigh:(uint32_t)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                            serialNum:(uint32_t)serialNum
                                queue:(dispatch_queue_t)queue
                   terminationHandler:(nullable void (^)(void))terminationHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Replaces the display's mode list. With `hiDPI`, macOS also offers each mode at 2x (half the size in points).
- (BOOL)applyModes:(NSArray<MSMVirtualDisplayMode *> *)modes hiDPI:(BOOL)hiDPI;

@end

NS_ASSUME_NONNULL_END
