#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "WQMBadgeCoordinator.h"
#import "WQMBadgeMath.h"
#import "WQMConfig.h"
#import "WQMLog.h"
#import "WQMTabBarBridge.h"

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
 * 一次完整的清除尝试，最多三轮（间隔 1.2s）。
 *
 * 为什么要重试：朋友圈自己的"已读上报"是网络请求，落库到红点汇总有延迟。
 * 第一次清完之后，服务端可能把旧的汇总推回来，红点会闪一下又出现；
 * 再补一次就能压住，而且一旦读到"没有红点"就立刻停，不会无限重清。
 */
- (void)runBadgeClearAttempt {
    if (self.clearAttempts >= 3) {
        WQMLog(@"badge clear gave up after %ld attempts", (long)self.clearAttempts);
        return;
    }
    self.clearAttempts += 1;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];

    /*
     * 注意：不能只看 badgeString / badgeValue。
     * 微信底栏的"发现"红点绝大多数时候是一个没有数字的小圆点，
     * 两个字段都是空的，但 badgeView 显示着。
     */
    if (![bridge discoverBadgeVisible]) {
        WQMLog(@"discover badge not visible (attempt %ld)", (long)self.clearAttempts);
        return;
    }

    int before = (int)MAX(0LL, [bridge discoverUnreadCount]);
    WQMLog(@"discover badge visible (unread %d), attempt %ld",
           before, (long)self.clearAttempts);

    /*
     * 一级：走微信自己的"从朋友圈返回"。
     * 发现页的 onTimeLineViewReturn 就是这条链路的官方回调：清掉朋友圈这一项，
     * 再按剩下的子项重算汇总，所以视频号 / 直播的未读会被原样保留。
     */
    UIViewController *discover = [bridge discoverController];
    BOOL asked = wqm_invoke_noarg(discover, @"onTimeLineViewReturn");
    if (asked) [self openLedgerFrom:before];
    WQMLog(@"asked WeChat to settle moments return (%d), discover page %@",
           asked, discover ? NSStringFromClass(discover.class) : @"nil");

    __weak typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (![[WQMTabBarBridge shared] discoverBadgeVisible]) {
            WQMLog(@"badge cleared by WeChat itself");
            return;
        }

        /*
         * 二级：只关掉发现页上"朋友圈红点"这一个开关（isShowingMomentsRedDot），
         * 其它子项一概不碰，然后请微信按现有子项重算汇总。
         */
        BOOL flagged = [self clearMomentsDotOnDiscoverPage];
        BOOL recomputed = [self requestAggregateRecompute];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (![[WQMTabBarBridge shared] discoverBadgeVisible]) {
                WQMLog(@"badge cleared via discover flag (flag=%d recompute=%d)",
                       flagged, recomputed);
                return;
            }

            /*
             * 三级：显示层清除。
             * 数字红点走保守扣减（只减朋友圈那一份），
             * 纯小圆点没有数量可分，直接调微信自己的"移除该 tab 红点"。
             */
            WQMTabBarBridge *bar = [WQMTabBarBridge shared];
            if ([bar discoverBadgeString].length > 0) {
                NSInteger momentsUnread = -1;
                if (![self readMomentsUnreadFrom:self.timelineController outValue:&momentsUnread]) {
                    momentsUnread = -1;
                }
                WQMBadgeInput input = { before, (int)momentsUnread };
                int target = wqm_badge_total_after_moments_read(input);
                [self applyTotal:target
                          toItem:bar.discoverItem
                        previous:before
                         moments:momentsUnread];
            } else {
                [self removeDiscoverRedDot:before];
            }

            if ([[WQMTabBarBridge shared] discoverBadgeVisible] && self.clearAttempts < 3) {
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

    BOOL called = NO;
    SEL removeSel = NSSelectorFromString(@"removeRedDotOnTabBarItemAtIndex:");
    if (controller && index != NSUIntegerMax && [controller respondsToSelector:removeSel]) {
        @try {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
                controller, removeSel, (unsigned long long)index);
            called = YES;
        } @catch (NSException *exception) {
            called = NO;
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
    BOOL still = [bridge discoverBadgeVisible];
    WQMLog(@"removeDiscoverRedDot called=%d itemView=%@ stillVisible=%d",
           called, itemView ? @"yes" : @"no", still);
    return !still;
}

- (void)openLedgerFrom:(int)before {
    double window = [[WQMConfig wqm_shared] wqm_doubleForKey:@"badgeWindow" defaultValue:5.0];
    wqm_badge_ledger_open(&_ledger, before, CACurrentMediaTime(), window);
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

    double window = [[WQMConfig wqm_shared] wqm_doubleForKey:@"badgeWindow" defaultValue:5.0];
    wqm_badge_ledger_open(&_ledger, before, CACurrentMediaTime(), window);

    WQMLog(@"badge %d -> %@ (moments unread %ld, window %.1fs)",
           before, newValue ?: @"nil", (long)moments, window);
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

    NSString *configured = [[WQMConfig wqm_shared] wqm_stringForKey:@"sourceClearSelectors" defaultValue:@""];
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    if (configured.length) {
        for (NSString *piece in [configured componentsSeparatedByString:@","]) {
            NSString *trimmed = [piece stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length) [selectors addObject:trimmed];
        }
    } else {
        [selectors addObjectsFromArray:@[
            @"markAllAsRead",
            @"markTimelineAsRead",
            @"clearUnread",
            @"resetUnreadCount"
        ]];
    }

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
