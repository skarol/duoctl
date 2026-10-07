// duoctl-helper runs inside a foldable iOS Simulator (via `xcrun simctl spawn`) and
// posts the private HID events Xcode's Device Hub uses for the iPhone Duo.
//
//   duoctl-helper hinge <degrees>                     0 = closed, 180 = flat
//   duoctl-helper orientation <value>                 portrait | pud | landscape-left | landscape-right | faceup | facedown
//   duoctl-helper tap <displayUUID> <nx> <ny> [hold-seconds]
//   duoctl-helper swipe <displayUUID> <nx1> <ny1> <nx2> <ny2> [seconds]
//   duoctl-helper touchscreens
//
// Coordinates are normalized (0...1) in the panel's native, unrotated axes.
//
// Hinge and orientation: Device Hub sends a vendor-defined event (usage page
// 0xFF61, usage 0x5B) carrying a binary-serialized dictionary, which locationd's
// CMDeviceStateRelayManager turns into a hinge angle or a device orientation.
// The hinge payload was first documented by https://github.com/artemnovichkov/hinge.
//
// Touches: every display has its own CoreDevice touchscreen service, tagged with
// that display's UUID. Simulator HID clients such as idb/AXe only ever reach the
// main (cover) touchscreen. duoctl-helper clones the target display's touchscreen
// as a virtual HID service and dispatches digitizer events through the clone.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, CFDictionaryRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern CFDataRef IOCFSerialize(CFTypeRef, CFOptionFlags);
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t usagePage, uint32_t usage,
    uint32_t version, const uint8_t *data, CFIndex length, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t transducerType, uint32_t index,
    uint32_t identity, uint32_t eventMask, uint32_t buttonMask, double x, double y, double z, double tipPressure,
    double barrelPressure, Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t index, uint32_t identity,
    uint32_t eventMask, double x, double y, double z, double tipPressure, double twist, Boolean range, Boolean touch,
    uint32_t options);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, CFIndex value);

enum {
    kClientTypeMonitor = 1,
    kClientTypeSimple = 4,
    kSerializeBinary = 1,
    kVendorUsagePage = 0xFF61,
    kVendorUsage = 0x5B,
    kDigitizerUsagePage = 0x0D,
    kTransducerHand = 3,
    kMaskRange = 1 << 0,
    kMaskTouch = 1 << 1,
    kMaskPosition = 1 << 2,
    kMaskIdentity = 1 << 5,
    kFieldDigitizerIsDisplayIntegrated = (11 << 16) | 25,
    kVirtualServiceEnumerated = 10,
};

static const double kMoveRate = 60.0;

#pragma mark - Device state (hinge, orientation)

static int postDeviceState(NSString *source, NSString *type, id value) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
    if (!client) {
        fprintf(stderr, "duoctl-helper: could not create a HID event system client\n");
        return 1;
    }
    NSDictionary *payload = @{
        @"provider": @"com.apple.Virtualization",
        @"source": source,
        @"type": type,
        @"value": value,
    };
    NSData *data = CFBridgingRelease(IOCFSerialize((__bridge CFTypeRef)payload, kSerializeBinary));
    IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), kVendorUsagePage, kVendorUsage,
                                                             0, data.bytes, (CFIndex)data.length, 0);
    IOHIDEventSystemClientDispatchEvent(client, event);
    CFRelease(event);
    // The event system delivers asynchronously; exiting at once can drop the event.
    usleep(100000);
    CFRelease(client);
    return 0;
}

#pragma mark - Touchscreens

static NSArray<NSDictionary *> *touchscreens(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, kClientTypeMonitor, NULL);
    if (!client) return @[];
    NSArray *services = CFBridgingRelease(IOHIDEventSystemClientCopyServices(client));
    NSArray *keys = @[ @"PrimaryUsagePage", @"PrimaryUsage", @"DeviceUsagePairs", @"Product", @"Transport",
                       @"Built-In", @"DeviceTypeHint", @"displayUUID", @"_ServiceID" ];
    NSMutableArray *result = [NSMutableArray array];
    for (id service in services) {
        NSMutableDictionary *props = [NSMutableDictionary dictionary];
        for (NSString *key in keys) {
            id value = CFBridgingRelease(IOHIDServiceClientCopyProperty((__bridge IOHIDServiceClientRef)service,
                                                                        (__bridge CFStringRef)key));
            if (value) props[key] = value;
        }
        if ([props[@"PrimaryUsagePage"] intValue] == kDigitizerUsagePage && props[@"displayUUID"]) {
            [result addObject:props];
        }
    }
    CFRelease(client);
    return result;
}

@interface DuoTouchscreenClone : NSObject
@property (copy) NSDictionary *properties;
@property (strong) dispatch_semaphore_t enumerated;
@property (strong) id service;
@end

@implementation DuoTouchscreenClone

- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
    return YES;
}

- (id)propertyForKey:(NSString *)key forService:(id)service {
    return self.properties[key];
}

- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service {
    return nil;
}

- (BOOL)setOutputEvent:(id)event forService:(id)service {
    return YES;
}

- (void)notification:(NSInteger)type withProperty:(NSDictionary *)property forService:(id)service {
    if (type == kVirtualServiceEnumerated) dispatch_semaphore_signal(self.enumerated);
}

- (BOOL)activate {
    if (!dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW)) {
        fprintf(stderr, "duoctl-helper: %s\n", dlerror());
        return NO;
    }
    Class serviceClass = NSClassFromString(@"HIDVirtualEventService");
    if (!serviceClass) {
        fprintf(stderr, "duoctl-helper: HIDVirtualEventService is missing from this runtime\n");
        return NO;
    }
    self.enumerated = dispatch_semaphore_create(0);
    self.service = [serviceClass new];
    ((void (*)(id, SEL, id))objc_msgSend)(self.service, @selector(setDelegate:), self);
    ((void (*)(id, SEL, id))objc_msgSend)(self.service, @selector(setDispatchQueue:),
                                          dispatch_queue_create("duoctl-helper.touchscreen", NULL));
    ((void (*)(id, SEL))objc_msgSend)(self.service, @selector(activate));
    if (dispatch_semaphore_wait(self.enumerated, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "duoctl-helper: the event system never opened the virtual touchscreen\n");
        return NO;
    }
    return YES;
}

- (BOOL)dispatchX:(double)x y:(double)y touching:(BOOL)touching moving:(BOOL)moving {
    uint64_t now = mach_absolute_time();
    uint32_t mask = moving ? kMaskPosition : (kMaskRange | kMaskTouch | kMaskIdentity);
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(NULL, now, kTransducerHand, 0, 0, mask, 0, x, y, 0, 0, 0,
                                                        touching, touching, 0);
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(NULL, now, 1, 2, mask, x, y, 0, touching ? 1.0 : 0.0,
                                                               0, touching, touching, 0);
    IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSetIntegerValue(finger, kFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventAppendEvent(hand, finger, 0);
    BOOL dispatched = ((BOOL (*)(id, SEL, id))objc_msgSend)(self.service, @selector(dispatchEvent:),
                                                            (__bridge id)hand);
    CFRelease(finger);
    CFRelease(hand);
    return dispatched;
}

- (void)cancel {
    // Let the last events drain before the service goes away.
    usleep(300000);
    ((void (*)(id, SEL))objc_msgSend)(self.service, @selector(cancel));
}

@end

static DuoTouchscreenClone *cloneTouchscreen(NSString *displayUUID) {
    for (NSDictionary *props in touchscreens()) {
        if ([[props[@"displayUUID"] uppercaseString] isEqualToString:displayUUID.uppercaseString]) {
            NSMutableDictionary *cloned = [props mutableCopy];
            [cloned removeObjectForKey:@"_ServiceID"];
            cloned[@"Product"] = @"duoctl touchscreen";
            DuoTouchscreenClone *clone = [DuoTouchscreenClone new];
            clone.properties = cloned;
            return [clone activate] ? clone : nil;
        }
    }
    fprintf(stderr, "duoctl-helper: no touchscreen for display %s\n", displayUUID.UTF8String);
    return nil;
}

static double clamp01(const char *value) {
    return fmin(fmax(atof(value), 0), 1);
}

static int tap(NSString *displayUUID, double x, double y, double hold) {
    DuoTouchscreenClone *clone = cloneTouchscreen(displayUUID);
    if (!clone) return 1;
    BOOL ok = [clone dispatchX:x y:y touching:YES moving:NO];
    usleep((useconds_t)(hold * 1e6));
    ok = [clone dispatchX:x y:y touching:NO moving:NO] && ok;
    [clone cancel];
    return ok ? 0 : 1;
}

static int swipe(NSString *displayUUID, double x1, double y1, double x2, double y2, double seconds) {
    DuoTouchscreenClone *clone = cloneTouchscreen(displayUUID);
    if (!clone) return 1;
    int steps = MAX(2, (int)(seconds * kMoveRate));
    BOOL ok = [clone dispatchX:x1 y:y1 touching:YES moving:NO];
    for (int step = 1; step <= steps; step++) {
        double t = (double)step / steps;
        usleep((useconds_t)(1e6 / kMoveRate));
        ok = [clone dispatchX:x1 + (x2 - x1) * t y:y1 + (y2 - y1) * t touching:YES moving:YES] && ok;
    }
    ok = [clone dispatchX:x2 y:y2 touching:NO moving:NO] && ok;
    [clone cancel];
    return ok ? 0 : 1;
}

#pragma mark - Entry point

static int usage(void) {
    fprintf(stderr,
            "usage: duoctl-helper hinge <degrees>\n"
            "       duoctl-helper orientation <portrait|pud|landscape-left|landscape-right|faceup|facedown>\n"
            "       duoctl-helper tap <displayUUID> <nx> <ny> [hold-seconds]\n"
            "       duoctl-helper swipe <displayUUID> <nx1> <ny1> <nx2> <ny2> [seconds]\n"
            "       duoctl-helper touchscreens\n");
    return 64;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return usage();
        NSString *command = @(argv[1]);

        if ([command isEqualToString:@"hinge"] && argc == 3) {
            double degrees = fmin(fmax(atof(argv[2]), 0), 180);
            return postDeviceState(@"hinge-slider-control", @"range", @(degrees));
        }
        if ([command isEqualToString:@"orientation"] && argc == 3) {
            NSSet *valid = [NSSet setWithArray:@[ @"portrait", @"pud", @"landscape-left", @"landscape-right",
                                                  @"faceup", @"facedown" ]];
            NSString *value = @(argv[2]);
            if (![valid containsObject:value]) return usage();
            return postDeviceState(@"orientation-picker-control", @"enum", value);
        }
        if ([command isEqualToString:@"tap"] && (argc == 5 || argc == 6)) {
            return tap(@(argv[2]), clamp01(argv[3]), clamp01(argv[4]), argc == 6 ? fmax(atof(argv[5]), 0) : 0.08);
        }
        if ([command isEqualToString:@"swipe"] && (argc == 7 || argc == 8)) {
            return swipe(@(argv[2]), clamp01(argv[3]), clamp01(argv[4]), clamp01(argv[5]), clamp01(argv[6]),
                         argc == 8 ? fmax(atof(argv[7]), 0.05) : 0.3);
        }
        if ([command isEqualToString:@"touchscreens"] && argc == 2) {
            for (NSDictionary *props in touchscreens()) {
                printf("%s %s\n", [props[@"displayUUID"] UTF8String], [props[@"Product"] UTF8String]);
            }
            return 0;
        }
        return usage();
    }
}
