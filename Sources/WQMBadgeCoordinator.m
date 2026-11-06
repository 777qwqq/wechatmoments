#include <limits.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "WQMBadgeCoordinator.h"
#import "WQMBadgeMath.h"
#import "WQMLog.h"
#import "WQMTabBarBridge.h"

/* 服务端把旧汇总推回来的窗口：这段时间内只丢弃"和清除前一模一样"的值。 */
static const double kWQMBadgeLedgerWindow = 5.0;

@interface WQMBadgeCoordinator ()
@property (nonatomic) NSInteger clearAttempts;
/* 每轮进入自增，让上一轮挂起的重试 block 自动失效。 */
@property (nonatomic) NSUInteger clearGeneration;
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
    (void)timelineController;
    self.clearAttempts = 0;
    self.clearGeneration += 1;
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
 * 前提（WQMMomentsRouter 已经做好）：timeline.delegate 指向 proxy（已读回调额外喂给发现页）、
 * 发现页 m_inTimeline = YES。有了这两样，朋友圈加载完数据后会自己完成已读落库。
 * 这里只负责"催一下"：异步回调没到就用发现页的 onTimeLineViewReturn 重算，
 * 再不行才动显示层。
 */
- (void)runBadgeClearAttempt {
    if (self.clearAttempts >= 3) {
        WQMLog(@"badge clear gave up after %ld attempts", (long)self.clearAttempts);
        return;
    }
    self.clearAttempts += 1;
    NSUInteger generation = self.clearGeneration;

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
        if (!self || self.clearGeneration != generation) return;
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
            if (!self || self.clearGeneration != generation) return;
            if (![[WQMTabBarBridge shared] discoverBadgeVisible]) {
                return;
            }
            /* 微信的结算链路没走到（版本改了内部方法时常见），最后压一次显示层。 */
            if (self.clearAttempts >= 2) {
                [self removeDiscoverRedDot:before];
            }
            if (self.clearAttempts < 3) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf || strongSelf.clearGeneration != generation) return;
                    [strongSelf runBadgeClearAttempt];
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
 * 三级兜底：只调微信自己的显示层接口，绝不写 unreadCount / badgeString 这类内部计数
 * —— 那一格是子项汇总，写 0 会把视频号 / 直播的未读一起抹掉。
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
    }

    [self openLedgerFrom:before];
    return ![bridge discoverBadgeVisible];
}

- (void)openLedgerFrom:(int)before {
    /* 纯小圆点没有计数：传 1 才能激活窗口，否则最常见的红点形态反而不拦截。 */
    wqm_badge_ledger_open(&_ledger, MAX(1, before), CACurrentMediaTime(), kWQMBadgeLedgerWindow);
}

- (NSString *)adjustedBadgeValue:(NSString *)value forItem:(UITabBarItem *)item {
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
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    if (index == NSUIntegerMax || index != bridge.discoverIndex) return YES;

    int incoming = (int)MIN(value, (long long)INT_MAX);
    return !wqm_badge_ledger_should_drop(&_ledger, incoming, CACurrentMediaTime());
}

#pragma mark - 汇总重算

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

@end
