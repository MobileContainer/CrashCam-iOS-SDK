//
//  TouchSynthesis.m
//  CrashCamTouchSynthesis
//

#if DEBUG

#import "TouchSynthesis.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Private API declarations

// Private UIKit selectors — the same set KIF and PTFakeTouch have relied on
// for years. Declaring them here lets us call them directly; every call site
// is guarded with respondsToSelector: so a missing selector on a future iOS
// degrades to a log line instead of a crash.

typedef struct __IOHIDEvent *IOHIDEventRef;

@interface UITouch (UIKitPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setGestureView:(UIView *)view;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious; // older naming
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)_setHidEvent:(IOHIDEventRef)event;
@end

@interface UIApplication (UIKitPrivate)
- (UIEvent *)_touchesEvent;
@end

@interface UIEvent (UIKitPrivate)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(IOHIDEventRef)event;
@end

@interface UIView (UIKitPrivateHitTest)
- (id)_hitTestWithContext:(id)context;
@end

#pragma mark - IOHIDEvent bridge (dlsym — no link-time IOKit dependency)

// SwiftUI's event bridge (and since iOS 9 parts of UIKit itself) read the
// IOHIDEvent backing a UITouch rather than the UITouch fields alone. Without
// it, classic UIKit recognizers (e.g. UIScrollView's pan) still respond but
// SwiftUI gestures ignore the touch entirely. Constants and construction
// mirror KIF's IOHIDEvent+KIF.m; the functions are resolved at runtime so
// this target never links IOKit.

enum {
    kIOHIDDigitizerTransducerTypeHand = 3,
};

enum {
    kIOHIDEventTypeDigitizer = 11,
};

enum {
    kIOHIDDigitizerEventRange    = 0x00000001,
    kIOHIDDigitizerEventTouch    = 0x00000002,
    kIOHIDDigitizerEventPosition = 0x00000004,
};

// Field = (eventType << 16) | fieldIndex; IsDisplayIntegrated is index 25 in
// the digitizer field enum (X, Y, Z, ButtonMask, Type, Index, Identity,
// EventMask, Range, Touch, Pressure, AuxiliaryPressure, Twist, TiltX, TiltY,
// Altitude, Azimuth, Quality, Density, Irregularity, MajorRadius,
// MinorRadius, Collection, CollectionChord, ChildEventMask, IsDisplayIntegrated).
enum {
    kIOHIDEventFieldDigitizerIsDisplayIntegrated = (kIOHIDEventTypeDigitizer << 16) | 25,
};

typedef IOHIDEventRef (*CRSCreateDigitizerEventFn)(
    CFAllocatorRef allocator, AbsoluteTime timeStamp, uint32_t type,
    uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    double x, double y, double z, double tipPressure, double barrelPressure,
    Boolean range, Boolean touch, uint32_t options);
typedef IOHIDEventRef (*CRSCreateDigitizerFingerEventWithQualityFn)(
    CFAllocatorRef allocator, AbsoluteTime timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    double x, double y, double z, double tipPressure, double twist,
    double minorRadius, double majorRadius, double quality, double density,
    double irregularity, Boolean range, Boolean touch, uint32_t options);
typedef void (*CRSAppendEventFn)(IOHIDEventRef event, IOHIDEventRef childEvent);
typedef void (*CRSSetIntegerValueFn)(IOHIDEventRef event, uint32_t field, int value);

static CRSCreateDigitizerEventFn CRSCreateDigitizerEvent;
static CRSCreateDigitizerFingerEventWithQualityFn CRSCreateFingerEvent;
static CRSAppendEventFn CRSAppendEvent;
static CRSSetIntegerValueFn CRSSetIntegerValue;

static BOOL CRSLoadHIDFunctions(void) {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CRSCreateDigitizerEvent = (CRSCreateDigitizerEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        CRSCreateFingerEvent = (CRSCreateDigitizerFingerEventWithQualityFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        CRSAppendEvent = (CRSAppendEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        CRSSetIntegerValue = (CRSSetIntegerValueFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        available = CRSCreateDigitizerEvent != NULL && CRSCreateFingerEvent != NULL
            && CRSAppendEvent != NULL && CRSSetIntegerValue != NULL;
        if (!available) {
            NSLog(@"[CrashCam] IOHIDEvent functions unavailable — SwiftUI gestures will not see synthetic touches.");
        }
    });
    return available;
}

static IOHIDEventRef CRSHIDEventWithTouches(NSArray<UITouch *> *touches) {
    if (!CRSLoadHIDFunctions()) return NULL;

    uint64_t abTime = mach_absolute_time();
    AbsoluteTime timeStamp;
    timeStamp.hi = (UInt32)(abTime >> 32);
    timeStamp.lo = (UInt32)(abTime);

    IOHIDEventRef handEvent = CRSCreateDigitizerEvent(
        kCFAllocatorDefault, timeStamp,
        kIOHIDDigitizerTransducerTypeHand,
        0 /* index */, 0 /* identity */,
        kIOHIDDigitizerEventTouch, 0 /* buttonMask */,
        0, 0, 0 /* x y z */, 0, 0 /* pressures */,
        0 /* range */, true /* touch */, 0 /* options */);
    if (handEvent == NULL) return NULL;
    CRSSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    for (UITouch *touch in touches) {
        uint32_t eventMask = (touch.phase == UITouchPhaseMoved)
            ? kIOHIDDigitizerEventPosition
            : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
        Boolean isTouching = (touch.phase == UITouchPhaseEnded
                              || touch.phase == UITouchPhaseCancelled) ? 0 : 1;

        CGPoint location = [touch locationInView:touch.window];
        IOHIDEventRef fingerEvent = CRSCreateFingerEvent(
            kCFAllocatorDefault, timeStamp,
            (uint32_t)[touches indexOfObject:touch] + 1 /* index */,
            2 /* identity */, eventMask,
            location.x, location.y, 0 /* z */,
            0 /* tipPressure */, 0 /* twist */,
            5.0 /* minorRadius */, 5.0 /* majorRadius */,
            1.0 /* quality */, 1.0 /* density */, 1.0 /* irregularity */,
            isTouching /* range */, isTouching /* touch */, 0 /* options */);
        if (fingerEvent != NULL) {
            CRSSetIntegerValue(fingerEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
            CRSAppendEvent(handEvent, fingerEvent);
            CFRelease(fingerEvent);
        }
    }
    return handEvent;
}

static void CRSAttachHIDEventToTouch(UITouch *touch) {
    if (![touch respondsToSelector:@selector(_setHidEvent:)]) return;
    IOHIDEventRef event = CRSHIDEventWithTouches(@[touch]);
    if (event == NULL) return;
    [touch _setHidEvent:event];
    CFRelease(event);
}

#pragma mark - Helpers

static NSTimeInterval CRSNow(void) {
    // UITouch.timestamp lives on the systemUptime clock; gesture recognizers
    // derive velocity from it, so each send must carry a real current value.
    return [NSProcessInfo processInfo].systemUptime;
}

static void CRSSetLocation(UITouch *touch, CGPoint point, BOOL resetPrevious) {
    if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]) {
        [touch _setLocationInWindow:point resetPrevious:resetPrevious];
    } else if ([touch respondsToSelector:@selector(setLocationInWindow:resetPrevious:)]) {
        [touch setLocationInWindow:point resetPrevious:resetPrevious];
    } else {
        NSLog(@"[CrashCam] UITouch location setter not found — private API changed on this iOS version.");
    }
}

// Since iOS 18, SwiftUI's gesture targets are found through the private
// _UIHitTestContext walk rather than plain -[UIView hitTest:withEvent:]. The
// responder it returns (often a SwiftUI.UIKitGestureContainer) is what the
// touch's view must be for SwiftUI gestures to fire; without it only classic
// UIKit recognizers respond. Mirrors KIF's kif_getHitTestViewInWindow.
static id CRSHitTestViewInWindow(UIWindow *window, CGPoint point) {
    UIView *hitTestView = [window hitTest:point withEvent:nil];

    if (@available(iOS 18.0, *)) {
        static Class contextClass;
        static SEL contextSel;
        static BOOL canUseContext;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            contextClass = NSClassFromString(@"_UIHitTestContext");
            contextSel = NSSelectorFromString(@"contextWithPoint:radius:");
            canUseContext = contextClass != Nil
                && [contextClass respondsToSelector:contextSel]
                && [UIView instancesRespondToSelector:@selector(_hitTestWithContext:)];
        });

        if (canUseContext) {
            id context = ((id (*)(id, SEL, CGPoint, CGFloat))objc_msgSend)(contextClass, contextSel, point, 0);
            if (context != nil) {
                id foundResponder = nil;
                UIView *currentView = hitTestView;
                while (foundResponder == nil && currentView != nil) {
                    foundResponder = [currentView _hitTestWithContext:context];
                    currentView = currentView.superview;
                }
                if (foundResponder != nil) return foundResponder;
            }
        }
    }
    return hitTestView;
}

#pragma mark - UITouch (CrashCamSynthesis)

@implementation UITouch (CrashCamSynthesis)

+ (nullable UITouch *)crs_touchBeginningAtPoint:(CGPoint)pointInWindow window:(UIWindow *)window {
    UITouch *touch = [[UITouch alloc] init];
    if (!touch) return nil;

    // setWindow: wipes other values — must come first.
    if ([touch respondsToSelector:@selector(setWindow:)])   [touch setWindow:window];
    if ([touch respondsToSelector:@selector(setTapCount:)]) [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(setIsTap:)])    [touch setIsTap:YES];

    CRSSetLocation(touch, pointInWindow, YES);

    id hitView = CRSHitTestViewInWindow(window, pointInWindow);
    if (hitView && [touch respondsToSelector:@selector(setView:)]) {
        [touch setView:hitView];
    }

    if ([touch respondsToSelector:@selector(setPhase:)]) [touch setPhase:UITouchPhaseBegan];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    if ([touch respondsToSelector:@selector(setTimestamp:)]) [touch setTimestamp:CRSNow()];
    if (hitView && [touch respondsToSelector:@selector(setGestureView:)]) {
        [touch setGestureView:hitView];
    }

    CRSAttachHIDEventToTouch(touch);

    return touch;
}

- (void)crs_moveToPoint:(CGPoint)pointInWindow {
    CRSSetLocation(self, pointInWindow, NO);
    if ([self respondsToSelector:@selector(setTimestamp:)]) [self setTimestamp:CRSNow()];
    if ([self respondsToSelector:@selector(setPhase:)])     [self setPhase:UITouchPhaseMoved];
}

- (void)crs_setPhase:(UITouchPhase)phase {
    if ([self respondsToSelector:@selector(setTimestamp:)]) [self setTimestamp:CRSNow()];
    if ([self respondsToSelector:@selector(setPhase:)])     [self setPhase:phase];
}

@end

#pragma mark - CRSTouchSender

@implementation CRSTouchSender

+ (void)sendTouches:(NSArray<UITouch *> *)touches {
    NSAssert(NSThread.isMainThread, @"Synthetic touches must be sent on the main thread");
    if (touches.count == 0) return;

    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(_touchesEvent)]) {
        NSLog(@"[CrashCam] -_touchesEvent not available — private API changed.");
        return;
    }

    UIEvent *event = [app _touchesEvent];
    if ([event respondsToSelector:@selector(_clearTouches)]) {
        [event _clearTouches];
    }

    // UIEvent.timestamp is readonly; set the backing ivar via KVC (best effort).
    @try {
        [event setValue:@(CRSNow()) forKey:@"timestamp"];
    } @catch (__unused NSException *e) { /* non-fatal */ }

    // Refresh the HID backing — per touch and on the event — to the touches'
    // current phase/location before delivery. SwiftUI reads these, not the
    // UITouch fields.
    for (UITouch *touch in touches) {
        CRSAttachHIDEventToTouch(touch);
    }
    if ([event respondsToSelector:@selector(_setHIDEvent:)]) {
        IOHIDEventRef hidEvent = CRSHIDEventWithTouches(touches);
        if (hidEvent != NULL) {
            [event _setHIDEvent:hidEvent];
            CFRelease(hidEvent);
        }
    }

    for (UITouch *touch in touches) {
        if ([event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) {
            [event _addTouch:touch forDelayedDelivery:NO];
        }
    }

    [app sendEvent:event];
}

@end

#endif
