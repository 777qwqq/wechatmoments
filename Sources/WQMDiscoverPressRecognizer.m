#import <QuartzCore/QuartzCore.h>
#import "WQMDiscoverPressRecognizer.h"
#import "WQMLog.h"

static const CGFloat kWQMDragSlopInPoints = 14.0;

@implementation WQMDiscoverPressRecognizer {
    WQMPressMachine _machine;
    CGPoint _initialPoint;
    NSTimer *_holdTimer;
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

    /* 立刻吃下这次触摸：底栏收到 touchesCancelled，不会把"发现"选中。 */
    self.state = UIGestureRecognizerStateBegan;

    if (self.onArmed) self.onArmed();
    WQMLog(@"long press armed, waiting for lift");
}

#pragma mark - Touch handling

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible) return;

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
}

@end
