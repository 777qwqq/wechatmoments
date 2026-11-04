#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "WQMBadgeCoordinator.h"
#import "WQMBadgeMath.h"
#import "WQMConfig.h"
#import "WQMLog.h"
#import "WQMTabBarBridge.h"

@interface WQMBadgeCoordinator ()
@property (nonatomic) BOOL writing;
@property (nonatomic) NSTimeInterval lastClearTime;
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
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastClearTime < 1.0) return;
    self.lastClearTime = now;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];

    int before = wqm_badge_parse_text([self currentDiscoverBadgeText].UTF8String);
    if (before <= 0) {
        WQMLog(@"discover badge already empty");
        return;
    }

    /*
     * 一级：走微信自己的"从朋友圈返回"。
     * 发现页的 onTimeLineViewReturn 就是这条链路的官方回调：清掉朋友圈这一项，
     * 再按剩下的子项重算汇总，所以视频号 / 直播的未读会被原样保留。
     */
    UIViewController *discover = [bridge discoverController];
    BOOL asked = wqm_invoke_noarg(discover, @"onTimeLineViewReturn");
    WQMLog(@"badge %d present, asked WeChat to mark moments read (%d)", before, asked);

    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakTimeline = timelineController;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        int after = wqm_badge_parse_text([self currentDiscoverBadgeText].UTF8String);
        if (after < before) {
            [self openLedgerFrom:before];
            WQMLog(@"badge cleared by WeChat itself: %d -> %d", before, after);
            return;
        }

        /*
         * 二级：只关掉发现页上"朋友圈红点"这一个开关，其它子项一概不碰，
         * 然后请微信重算汇总。
         */
        BOOL flagged = [self clearMomentsDotOnDiscoverPage];
        [self requestAggregateRecompute];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            int after2 = wqm_badge_parse_text([self currentDiscoverBadgeText].UTF8String);
            if (after2 < before) {
                [self openLedgerFrom:before];
                WQMLog(@"badge cleared via discover flag (%d): %d -> %d",
                       flagged, before, after2);
                return;
            }

            /* 三级：拿不到子项计数就保守扣减，最多只扣朋友圈那一份。 */
            NSInteger momentsUnread = -1;
            if (![self readMomentsUnreadFrom:weakTimeline outValue:&momentsUnread]) {
                momentsUnread = -1;
            }
            WQMBadgeInput input = { before, (int)momentsUnread };
            int target = wqm_badge_total_after_moments_read(input);
            WQMLog(@"badge fallback path (flag=%d, moments unread %ld)",
                   flagged, (long)momentsUnread);
            [self applyTotal:target
                      toItem:[[WQMTabBarBridge shared] discoverItem]
                    previous:before
                     moments:momentsUnread];
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
    return ok;
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

- (NSString *)currentDiscoverBadgeText {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    UITabBarItem *item = bridge.discoverItem;
    if (item.badgeValue.length) return item.badgeValue;

    UITabBar *bar = bridge.tabBar;
    NSArray *views = nil;
    @try {
        views = [bar valueForKey:@"tabBarItemViews"];
    } @catch (NSException *exception) {
        views = nil;
    }
    if (![views isKindOfClass:[NSArray class]]) return nil;

    NSUInteger index = bridge.discoverIndex;
    if (index == NSUIntegerMax || index >= views.count) return nil;

    id itemView = views[index];
    NSString *badge = nil;
    @try {
        badge = [itemView valueForKey:@"badgeString"];
    } @catch (NSException *exception) {
        badge = nil;
    }
    return [badge isKindOfClass:[NSString class]] ? badge : nil;
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
