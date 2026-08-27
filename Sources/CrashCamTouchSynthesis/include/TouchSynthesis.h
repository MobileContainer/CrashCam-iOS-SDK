//
//  TouchSynthesis.h
//  CrashCamTouchSynthesis
//
//  Debug-only synthetic touch injection for in-process crash replay
//  (the KIF/PTFakeTouch technique). Everything is guarded by #if DEBUG and
//  the target only defines DEBUG for debug configurations, so Release builds
//  compile this file to nothing — private API must never ship.
//

#if DEBUG

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UITouch (CrashCamSynthesis)

/// A new touch in the `began` phase at a point in window coordinates,
/// hit-tested against the window to bind its target view.
+ (nullable UITouch *)crs_touchBeginningAtPoint:(CGPoint)pointInWindow
                                         window:(UIWindow *)window
    NS_SWIFT_NAME(crs_touchBeginning(at:window:));

/// Moves an active touch to a new point (window coordinates), phase `moved`.
- (void)crs_moveToPoint:(CGPoint)pointInWindow NS_SWIFT_NAME(crs_move(to:));

/// Transitions the touch to a new phase (`ended` / `cancelled` / …).
- (void)crs_setPhase:(UITouchPhase)phase;

@end

@interface CRSTouchSender : NSObject

/// Packages the touches into the app's shared UITouchesEvent and delivers
/// them via -[UIApplication sendEvent:]. Main thread only.
+ (void)sendTouches:(NSArray<UITouch *> *)touches NS_SWIFT_NAME(send(_:));

@end

NS_ASSUME_NONNULL_END

#endif
