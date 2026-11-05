#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "WQMBadgeCoordinator.h"
#import "WQMBadgeMath.h"
#import "WQMLog.h"
#import "WQMTabBarBridge.h"

/* 服务端把旧汇总推回来的窗口：这段时间内只丢弃"和清除前一模一样"的值。 */
static const double kWQMBadgeLedgerWindow = 5.0;

@interface WQMBadgeCoordinator ()
@property (nonatomic) BOOL writing;
@property (nonatomic, weak) UIViewController *timelineController;
@property (nonatomic) NSInteger clearAttempts;
@property (nonatomic) WQMBadgeLedger ledger;
@end

/* 只调用"无参数、返回 void"的方法，签名不符就跳过，绝不瞎调。 */
static BOOL wqm_invoke_noarg(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return NO;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return NO;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        WQMLog(@"%@ threw: %@", selectorName, exception.reason);
        return NO;
    }
    return YES;
}

/* 读取一个返回整型的方法，用于拿到"朋友圈未读数"（拿不到就返回 NO）。 */
static BOOL wqm_read_integer(id target, NSString *selectorName, NSInteger *outValue) {
    if (!target || selectorName.length == 0) return NO;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return NO;
    if (signature.methodReturnLength != sizeof(NSInteger) &&
        signature.methodReturnLength != sizeof(int) &&
        signature.methodReturnLength != sizeof(long)) {
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        return NO;
    }

    NSInteger value = 0;
    [invocation getReturnValue:&value];
    if (outValue) *outValue = value;
    return YES;
}

@implementation WQMBadgeCoordinator

+ (instancetype)shared {
    static WQMBadgeCoordinator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - 对外

- (void)momentsTimelineDidAppear:(UIViewController *)timelineController {
    self.timelineController = timelineController;
    self.clearAttempts = 0;
    [self runBadgeClearAttempt];
}

/*
 * 退出前的最后一次原生结算。
 * 朋友圈在用户浏览期间会断断续续回调 onMarkWCObjectAsRead:，
 * 离开时再让发现页按当前状态重算一次，确保它把"已读到哪"写下去。
 */
- (void)momentsTimelineWillDisappear {
    UIViewController *discover = [[WQMTabBarBridge shared] discoverController];
    if (!discover) return;

    wqm_invoke_noarg(discover, @"onTimeLineViewReturn");
}

/*
 * 走微信自己的结算，不自己算数字。
 *
 * 前提（WQMMomentsRouter 已经做好）：timeline.delegate = 发现页、发现页 m_inTimeline = YES。
 * 有了这两样，朋友圈加载完数据后会自己回调 onMarkWCObjectAsRead:，
 * 发现页据此把"已读位置"落到本地存储 —— 所以冷启动不会再回来。
 *
 * 这里只负责"催一下"：如果朋友圈的异步回调还没到，就用发现页自己的
 * onTimeLineViewReturn 让它按当前状态重算一次；再不行才动显示层。
 */
- (void)runBadgeClearAttempt {
    if (self.clearAttempts >= 3) {
        WQMLog(@"badge clear gave up after %ld attempts", (long)self.clearAttempts);
        return;
    }
    self.clearAttempts += 1;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];

    if (![bridge discoverBadgeVisible]) {
        WQMLog(@"discover badge not visible (attempt %ld)", (long)self.clearAttempts);
        return;
    }

    int before = (int)MAX(0LL, [bridge discoverUnreadCount]);
    [self openLedgerFrom:before];

    wqm_invoke_noarg([bridge discoverController], @"onTimeLineViewReturn");

    __weak typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (![[WQMTabBarBridge shared] discoverBadgeVisible]) {
            WQMLog(@"badge cleared by WeChat itself");
            return;
        }

        /*
         * 朋友圈的已读回调是异步的（要等数据落地）。
         * 第二轮不再重复催 onTimeLineViewReturn，而是把发现页上"朋友圈红点"
         * 这一个开关关掉，再让它按剩余子项重算 —— 视频号 / 直播的未读不动。
         */
        [self clearMomentsDotOnDiscoverPage];
        [self requestAggregateRecompute];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (![[WQMTabBarBridge shared] discoverBadgeVisible]) {
                return;
            }
            if (self.clearAttempts < 3) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf runBadgeClearAttempt];
                });
            }
        });
    });
}

/* 发现页把"朋友圈有没有红点"记在 isShowingMomentsRedDot + m_timelineRedDotView 上。 */
- (BOOL)clearMomentsDotOnDiscoverPage {
    UIViewController *discover = [[WQMTabBarBridge shared] discoverController];
    if (!discover) return NO;

    BOOL ok = NO;
    @try {
        [discover setValue:@NO forKey:@"isShowingMomentsRedDot"];
        ok = YES;
    } @catch (NSException *exception) {
        ok = NO;
    }
    @try {
        id dot = [discover valueForKey:@"m_timelineRedDotView"];
        if ([dot isKindOfClass:[UIView class]]) {
            ((UIView *)dot).hidden = YES;
        }
    } @catch (NSException *exception) {
        /* 没有这个视图就算了 */
    }
    /*
     * 微信自己的入口：noteTabBarBadge:andTotalCount: 是发现页把
     * "还有没有别的子项未读"告诉底栏的地方，第二个参数给 0 表示"按剩余子项算"。
     */
    SEL noteSel = NSSelectorFromString(@"noteTabBarBadge:andTotalCount:");
    if ([discover respondsToSelector:noteSel]) {
        @try {
            ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(discover, noteSel, NO, 0LL);
            ok = YES;
        } @catch (NSException *exception) {
            /* 签名不符就跳过 */
        }
    }
    return ok;
}

/*
 * 三级兜底：调用 MMTabBarController 自己的"移除该 tab 红点"。
 * 前两级已经把朋友圈这一项的已读状态结算掉了，这里清的是显示层；
 * 若视频号 / 直播确实还有未读，微信下一次汇总会把点重新点回来。
 */
- (BOOL)removeDiscoverRedDot:(int)before {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    UITabBarController *controller = bridge.tabBarController;
    NSUInteger index = bridge.discoverIndex;

    SEL removeSel = NSSelectorFromString(@"removeRedDotOnTabBarItemAtIndex:");
    if (controller && index != NSUIntegerMax && [controller respondsToSelector:removeSel]) {
        @try {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
                controller, removeSel, (unsigned long long)index);
        } @catch (NSException *exception) {
            /* 这个版本没有该入口就跳过 */
        }
    }

    /* 视图层再补一刀：MMTabBarItemView 自己有 removeSmallRedDot / setBadgeViewHidden:。 */
    UIView *itemView = [bridge discoverItemView];
    if (itemView) {
        wqm_invoke_noarg(itemView, @"removeSmallRedDot");
        SEL hideSel = NSSelectorFromString(@"setBadgeViewHidden:");
        if ([itemView respondsToSelector:hideSel]) {
            @try {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(itemView, hideSel, YES);
            } @catch (NSException *exception) {
                /* 忽略 */
            }
        }
        @try {
            [itemView setValue:@0 forKey:@"unreadCount"];
            [itemView setValue:nil forKey:@"badgeString"];
        } @catch (NSException *exception) {
            /* 只读字段就跳过 */
        }
    }

    [self openLedgerFrom:before];
    return ![bridge discoverBadgeVisible];
}

- (void)openLedgerFrom:(int)before {
    wqm_badge_ledger_open(&_ledger, before, CACurrentMediaTime(), kWQMBadgeLedgerWindow);
}

- (NSString *)adjustedBadgeValue:(NSString *)value forItem:(UITabBarItem *)item {
    if (self.writing) return value;

    UITabBarItem *discoverItem = [WQMTabBarBridge shared].discoverItem;
    if (!discoverItem || item != discoverItem) return value;

    int incoming = wqm_badge_parse_text(value.UTF8String);
    if (wqm_badge_ledger_should_drop(&_ledger, incoming, CACurrentMediaTime())) {
        WQMLog(@"drop stale aggregate badge %d (ceiling %d)", incoming, _ledger.ceiling);
        return nil;
    }
    return value;
}

- (NSString *)adjustedBadgeString:(id)value forIndex:(NSUInteger)index {
    if (self.writing) return value;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    if (index == NSUIntegerMax || index != bridge.discoverIndex) return value;
    if (![value isKindOfClass:[NSString class]]) return value;

    NSString *string = (NSString *)value;
    int incoming = wqm_badge_parse_text(string.UTF8String);
    if (wqm_badge_ledger_should_drop(&_ledger, incoming, CACurrentMediaTime())) {
        WQMLog(@"drop stale aggregate badge string %d (ceiling %d)", incoming, _ledger.ceiling);
        return nil;
    }
    return string;
}

- (BOOL)shouldAcceptBadgeValue:(long long)value forIndex:(NSUInteger)index {
    if (self.writing) return YES;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    if (index == NSUIntegerMax || index != bridge.discoverIndex) return YES;

    return !wqm_badge_ledger_should_drop(&_ledger, (int)value, CACurrentMediaTime());
}

#pragma mark - 写入

- (void)applyTotal:(int)after toItem:(UITabBarItem *)item previous:(int)before moments:(NSInteger)moments {
    NSString *newValue = (after > 0) ? [NSString stringWithFormat:@"%d", after] : nil;

    self.writing = YES;
    [self writeDiscoverBadgeString:newValue fallbackItem:item];
    self.writing = NO;

    wqm_badge_ledger_open(&_ledger, before, CACurrentMediaTime(), kWQMBadgeLedgerWindow);

    WQMLog(@"badge %d -> %@ (moments unread %ld, window %.1fs)",
           before, newValue ?: @"nil", (long)moments, kWQMBadgeLedgerWindow);
}

/* 微信真实底栏只认 MMTabBarItemView，优先走它自己的写入接口。 */
- (void)writeDiscoverBadgeString:(NSString *)value fallbackItem:(UITabBarItem *)item {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    UITabBarController *controller = bridge.tabBarController;
    NSUInteger index = bridge.discoverIndex;

    SEL stringSelector = NSSelectorFromString(@"setTabBarBadgeString:forIndex:");
    if (controller && index != NSUIntegerMax && [controller respondsToSelector:stringSelector]) {
        ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(
            controller, stringSelector, value, (unsigned long long)index);
        return;
    }

    SEL valueSelector = NSSelectorFromString(@"setTabBarBadgeValue:forIndex:");
    if (controller && index != NSUIntegerMax && [controller respondsToSelector:valueSelector]) {
        ((void (*)(id, SEL, unsigned long long, unsigned long long))objc_msgSend)(
            controller, valueSelector, (unsigned long long)MAX(0, value.integerValue),
            (unsigned long long)index);
        return;
    }

    item.badgeValue = value;
}

#pragma mark - 数据源

- (BOOL)clearMomentsUnreadAtSource:(UIViewController *)timelineController {
    if (!timelineController) return NO;

    /* 各版本清未读的入口名不一样，挨个试，命中即止。 */
    NSArray<NSString *> *selectors = @[
        @"markAllAsRead",
        @"markTimelineAsRead",
        @"clearUnread",
        @"resetUnreadCount"
    ];

    BOOL cleared = NO;
    for (NSString *selector in selectors) {
        if (wqm_invoke_noarg(timelineController, selector)) {
            WQMLog(@"cleared moments unread via -%@", selector);
            cleared = YES;
        }
    }
    return cleared;
}

- (BOOL)requestAggregateRecompute {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    NSArray<NSString *> *selectors = @[
        @"updateBadge",
        @"refreshBadge",
        @"updateTabBarBadge",
        @"refreshRedDot",
        @"updateRedDot"
    ];

    BOOL done = NO;
    for (NSString *selector in selectors) {
        if (wqm_invoke_noarg(bridge.tabBarController, selector)) done = YES;
        if (wqm_invoke_noarg(bridge.tabBar, selector)) done = YES;
        /* 发现页才是汇总红点的真正持有者（badgeAtMomentCell / updateTabBarBadge）。 */
        if (wqm_invoke_noarg([bridge discoverController], selector)) done = YES;
    }
    return done;
}

- (BOOL)readMomentsUnreadFrom:(UIViewController *)controller outValue:(NSInteger *)outValue {
    if (!controller) return NO;
    NSArray<NSString *> *selectors = @[@"unreadCount", @"snsUnreadCount", @"newUnreadCount", @"badgeCount"];
    for (NSString *selector in selectors) {
        if (wqm_read_integer(controller, selector, outValue)) return YES;
    }
    return NO;
}

@end
