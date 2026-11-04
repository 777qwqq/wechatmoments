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
    if (now - self.lastClearTime < 1.5) return;
    self.lastClearTime = now;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];

    UITabBarItem *item = bridge.discoverItem;
    if (!item) {
        WQMLog(@"no discover item, skip badge work");
        return;
    }

    int before = wqm_badge_parse_text([self currentDiscoverBadgeText].UTF8String);
    if (before <= 0) {
        WQMLog(@"discover badge already empty");
        return;
    }

    /*
     * 首选路径：让微信自己把朋友圈记为已读，再让它自己重算汇总。
     * 这样视频号/直播等子项的未读会被保留，而不是被我们顺手抹掉。
     */
    BOOL clearedAtSource = [self clearMomentsUnreadAtSource:timelineController];
    BOOL recomputed = [self requestAggregateRecompute];
    if (clearedAtSource && recomputed) {
        WQMLog(@"badge handled by WeChat itself (before=%d)", before);
        return;
    }

    NSInteger momentsUnread = -1;
    if (![self readMomentsUnreadFrom:timelineController outValue:&momentsUnread]) {
        momentsUnread = -1;
    }

    WQMBadgeInput input = { before, (int)momentsUnread };
    int after = wqm_badge_total_after_moments_read(input);
    [self applyTotal:after toItem:item previous:before moments:momentsUnread];
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
