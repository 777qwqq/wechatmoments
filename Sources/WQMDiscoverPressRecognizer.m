#import <QuartzCore/QuartzCore.h>
#import "WQMDiscoverPressRecognizer.h"
#import "WQMLog.h"

static const CGFloat kWQMDragSlopInPoints = 14.0;

@implementation WQMDiscoverPressRecognizer {
    WQMPressMachine _machine;
    CGPoint _initialPoint;
    NSTimer *_holdTimer;
    BOOL _longPressFired;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _holdDelay = 0.40;
        wqm_press_init(&_machine, _holdDelay);

        /* 不要把 touchesBegan 也扣住：底栏的高亮反馈仍然即时。 */
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = YES;
        self.cancelsTouchesInView = YES;
    }
    return self;
}

- (void)dealloc {
    [_holdTimer invalidate];
    _holdTimer = nil;
}

#pragma mark - Timer

- (void)startHoldTimer {
    [_holdTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _holdTimer = [NSTimer timerWithTimeInterval:_holdDelay repeats:NO block:^(NSTimer *timer) {
        [weakSelf holdTimerFired];
    }];
    /* 用 common modes，避免滚动/追踪模式下定时器被挂起导致长按被漏判。 */
    [[NSRunLoop mainRunLoop] addTimer:_holdTimer forMode:NSRunLoopCommonModes];
}

- (void)stopHoldTimer {
    [_holdTimer invalidate];
    _holdTimer = nil;
}

- (void)holdTimerFired {
    if (self.state != UIGestureRecognizerStatePossible) return;

    if (!wqm_press_hold_elapsed(&_machine, CACurrentMediaTime())) return;

    /*
     * 时间一到就直接跳，不等抬手。
     *
     * 抬手会不会误触发现页九宫格？不会：这次触摸在 touchesBegan 时就落给了底栏，
     * UIKit 不会对进行中的触摸重新做 hit-test，所以手指下面是哪一格都跟它没关系。
     * 底栏自己的 singleTapGesture 又被我们要求 fail，也不会补一次 tab 切换。
     */
    _longPressFired = YES;
    self.state = UIGestureRecognizerStateEnded;

    if (self.onArmed) self.onArmed();
    WQMLog(@"long press");
    if (self.onLongPress) self.onLongPress();
}

#pragma mark - Touch handling

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible) return;

    _longPressFired = NO;
    UITouch *touch = touches.anyObject;
    if (!touch) return;

    CGPoint point = [touch locationInView:self.view];
    BOOL inside = self.isInDiscoverSlot ? self.isInDiscoverSlot(point) : NO;

    if (_machine.phase != WQMPressPhaseIdle) {
        /* 第二根手指：不再猜用户意图，整轮放弃。 */
        [self stopHoldTimer];
        wqm_press_reset(&_machine);
        self.state = UIGestureRecognizerStateFailed;
        return;
    }

    wqm_press_init(&_machine, _holdDelay);
    WQMPressOutcome outcome = wqm_press_down(&_machine, inside ? 1 : 0, CACurrentMediaTime());
    if (outcome == WQMPressOutcomeAbort) {
        /* 点的是别的 tab：立刻失败，交给系统原生处理。 */
        self.state = UIGestureRecognizerStateFailed;
        return;
    }

    _initialPoint = point;
    [self startHoldTimer];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible &&
        self.state != UIGestureRecognizerStateBegan) {
        return;
    }

    UITouch *touch = touches.anyObject;
    if (!touch) return;

    CGPoint point = [touch locationInView:self.view];
    CGFloat dx = point.x - _initialPoint.x;
    CGFloat dy = point.y - _initialPoint.y;
    BOOL insideSlop = (dx * dx + dy * dy) <= (kWQMDragSlopInPoints * kWQMDragSlopInPoints);

    if (wqm_press_drag(&_machine, insideSlop ? 1 : 0, CACurrentMediaTime()) == WQMPressOutcomeAbort) {
        [self stopHoldTimer];
        self.state = (self.state == UIGestureRecognizerStateBegan)
                         ? UIGestureRecognizerStateCancelled
                         : UIGestureRecognizerStateFailed;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self stopHoldTimer];

    /* 长按已经在定时器里发过了，这里只收尾，不能再触发一次。 */
    if (_longPressFired) {
        return;
    }

    WQMPressOutcome outcome = wqm_press_up(&_machine, CACurrentMediaTime());

    switch (outcome) {
        case WQMPressOutcomeTap: {
            /*
             * 抬手瞬间才转 Began：delaysTouchesEnded 保证底栏还没收到 touchesEnded，
             * 于是底栏拿到的是 touchesCancelled —— UP 事件被吞掉，不会切到发现页。
             */
            self.state = UIGestureRecognizerStateBegan;
            self.state = UIGestureRecognizerStateEnded;
            WQMLog(@"tap");
            if (self.onTap) self.onTap();
            break;
        }
        case WQMPressOutcomeLongPress: {
            self.state = UIGestureRecognizerStateEnded;
            WQMLog(@"long press");
            if (self.onLongPress) self.onLongPress();
            break;
        }
        default: {
            self.state = (self.state == UIGestureRecognizerStateBegan)
                             ? UIGestureRecognizerStateCancelled
                             : UIGestureRecognizerStateFailed;
            break;
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self stopHoldTimer];
    wqm_press_cancel(&_machine);
    if (_longPressFired) return;
    self.state = (self.state == UIGestureRecognizerStateBegan)
                     ? UIGestureRecognizerStateCancelled
                     : UIGestureRecognizerStateFailed;
}

- (void)cancelCurrentGesture {
    [self stopHoldTimer];
    wqm_press_reset(&_machine);
    if (self.state == UIGestureRecognizerStatePossible ||
        self.state == UIGestureRecognizerStateBegan) {
        self.state = UIGestureRecognizerStateCancelled;
    }
}

- (void)reset {
    [super reset];
    [self stopHoldTimer];
    wqm_press_reset(&_machine);
    _initialPoint = CGPointZero;
    _longPressFired = NO;
}

@end
