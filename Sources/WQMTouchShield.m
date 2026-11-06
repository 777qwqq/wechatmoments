#import "WQMTouchShield.h"
#import "WQMLog.h"

static __weak UIView *gShieldView = nil;

/* 纯吞触摸的视图：命中后不做任何事，事件自然消失。 */
@interface WQMShieldView : UIView
@end

@implementation WQMShieldView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}

@end

@implementation WQMTouchShield

+ (UIWindow *)keyWindow {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) return window;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

+ (void)installNowForDuration:(NSTimeInterval)duration {
    [gShieldView removeFromSuperview];

    UIWindow *window = [self keyWindow];
    if (!window) return;

    WQMShieldView *shield = [[WQMShieldView alloc] initWithFrame:window.bounds];
    shield.backgroundColor = [UIColor clearColor];
    shield.userInteractionEnabled = YES;
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:shield];
    gShieldView = shield;

    WQMLog(@"touch shield up for %.2fs", duration);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gShieldView == shield) {
            [shield removeFromSuperview];
            gShieldView = nil;
        }
    });
}

+ (void)installForDuration:(NSTimeInterval)duration {
    if (duration <= 0) return;

    /* 同帧生效：异步安装会在跳转后留出一帧没有任何遮挡的穿透窗口。 */
    if ([NSThread isMainThread]) {
        [self installNowForDuration:duration];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installNowForDuration:duration];
        });
    }
}

@end
