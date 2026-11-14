#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

// Internal Objective-C boundary, not part of the Swift/public bridge surface.
@interface ADCMediaControl : NSObject
+ (instancetype)openUUID:(const char *)uuid version:(const char *)version streaming:(BOOL)streaming
               cancelled:(int (^)(void))cancelled error:(char *)error capacity:(size_t)capacity;
- (xpc_object_t)requestAction:(const char *)action input:(xpc_object_t)input deadline:(uint64_t)deadline
                   cancelled:(int (^)(void))cancelled error:(char *)error capacity:(size_t)capacity;
- (void)close;
@end
