#import <math.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import "WQMTabBarBridge.h"
#import "WQMDiscoverPressRecognizer.h"
#import "WQMLog.h"
#import "WQMMomentsRouter.h"
#import "WQMTouchShield.h"

static NSString * const kWQMDiscoverTitle = @"发现";
static NSString * const kWQMMessageTitle = @"微信";
static const NSUInteger kWQMDiscoverFallbackIndex = 2;

/* 微信自己的类名；只在运行时按字符串取，不硬链接。 */
static NSString * const kWQMDiscoverClassName = @"FindFriendEntryViewController";
static NSString * const kWQMMainFrameClassName = @"NewMainFrameViewController";

@interface WQMTabBarBridge ()
@property (nonatomic, readwrite, weak) UITabBar *tabBar;
@property (nonatomic, readwrite, weak) UITabBarController *tabBarController;
@property (nonatomic, readwrite, weak) UITabBarItem *discoverItem;
@property (nonatomic, readwrite) NSUInteger discoverIndex;
@property (nonatomic, readwrite) NSUInteger messageIndex;
@property (nonatomic, weak) WQMDiscoverPressRecognizer *recognizer;
@property (nonatomic, readwrite) BOOL forcingHighlight;
@property (nonatomic, readwrite) BOOL tabBarHidden;
@property (nonatomic, weak) UIGestureRecognizer *observedSingleTap;
@end

static BOOL wqm_view_looks_like_tab_bar(UIView *view) {
    if ([view isKindOfClass:[UITabBar class]]) return YES;
    NSString *className = NSStringFromClass(view.class);
    return [className containsString:@"TabBar"] &&
           [view respondsToSelector:NSSelectorFromString(@"items")] &&
           [view respondsToSelector:NSSelectorFromString(@"selectedItem")];
}

static void wqm_collect_tab_bars(UIView *root, int depth, NSMutableArray<UIView *> *out) {
    if (!root || depth > 12) return;
    if (wqm_view_looks_like_tab_bar(root)) [out addObject:root];
    for (UIView *subview in root.subviews) {
        wqm_collect_tab_bars(subview, depth + 1, out);
    }
}

/*
 * 一个 App 里可能同时存在多个 tab bar（例如内嵌的业务页）。
 * 主 tab bar 一定挂在 MMTabBarController 上，优先按这个判断，避免装错。
 */
static NSInteger wqm_score_tab_bar(UIView *bar) {
    NSInteger score = 0;

    NSString *className = NSStringFromClass(bar.class);
    if ([className isEqualToString:@"MMTabBar"]) score += 20;

    UIResponder *responder = bar;
    int guard = 0;
    while (responder && guard++ < 24) {
        if ([responder isKindOfClass:[UITabBarController class]]) {
            score += 10;
            if ([NSStringFromClass([responder class]) isEqualToString:@"MMTabBarController"]) score += 20;
            break;
        }
        responder = responder.nextResponder;
    }

    id items = nil;
    @try {
        items = [bar valueForKey:@"items"];
    } @catch (NSException *exception) {
        return NSIntegerMin;
    }
    if (![items isKindOfClass:[NSArray class]]) return NSIntegerMin;

    NSArray *array = (NSArray *)items;
    if (array.count == 0) return NSIntegerMin;

    if (array.count >= 3) score += 1;
    if (array.count == 4) score += 2;
    if (CGRectGetWidth(bar.bounds) > 0) score += 1;
    if (bar.window) score += 5;

    for (id item in array) {
        NSString *title = nil;
        @try {
            title = [item valueForKey:@"title"];
        } @catch (NSException *exception) {
            continue;
        }
        if ([title isEqualToString:kWQMDiscoverTitle]) score += 6;
        if ([title isEqualToString:kWQMMessageTitle]) score += 3;
    }
    return score;
}

/* MMTabBar 的每个格子是一个 MMTabBarItemView，高亮由它的 isSelected 决定。 */
static NSArray *wqm_item_views(UITabBar *bar) {
    if (!bar) return nil;
    id views = nil;
    @try {
        views = [bar valueForKey:@"tabBarItemViews"];
    } @catch (NSException *exception) {
        return nil;
    }
    return [views isKindOfClass:[NSArray class]] ? (NSArray *)views : nil;
}

@implementation WQMTabBarBridge

+ (instancetype)shared {
    static WQMTabBarBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _discoverIndex = NSUIntegerMax;
        _messageIndex = 0;
    }
    return self;
}

#pragma mark - 定位

- (void)refresh {
    UITabBar *bar = self.tabBar;
    if (!bar || !bar.window) {
        NSMutableArray<UIView *> *candidates = [NSMutableArray array];
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            wqm_collect_tab_bars(window, 0, candidates);
        }
        UIView *best = nil;
        NSInteger bestScore = NSIntegerMin;
        for (UIView *candidate in candidates) {
            NSInteger score = wqm_score_tab_bar(candidate);
            if (score > bestScore) {
                bestScore = score;
                best = candidate;
            }
        }
        bar = (UITabBar *)best;
        self.tabBar = bar;
    }

    if (!bar) {
        self.tabBarController = nil;
        self.discoverItem = nil;
        self.discoverIndex = NSUIntegerMax;
        return;
    }

    UITabBarController *controller = [self controllerForTabBar:bar];
    self.tabBarController = controller;

    NSArray<UITabBarItem *> *items = bar.items;
    if (items.count == 0) {
        self.discoverItem = nil;
        self.discoverIndex = NSUIntegerMax;
        return;
    }

    NSUInteger discover = [self indexOfDiscoverInController:controller];
    if (discover == NSUIntegerMax) {
        discover = [self resolveIndexForTitle:kWQMDiscoverTitle
                                      inItems:items
                                   controller:controller
                                 fallbackSlot:kWQMDiscoverFallbackIndex];
    }
    self.discoverIndex = discover;
    self.discoverItem = (discover < items.count) ? items[discover] : nil;

    NSUInteger message = [self indexOfMainFrameInController:controller];
    if (message == NSUIntegerMax) {
        message = [self resolveIndexForTitle:kWQMMessageTitle
                                     inItems:items
                                  controller:controller
                                fallbackSlot:0];
    }
    self.messageIndex = message;
}

- (UITabBarController *)controllerForTabBar:(UITabBar *)bar {
    UIResponder *responder = bar;
    int guard = 0;
    while (responder && guard++ < 24) {
        if ([responder isKindOfClass:[UITabBarController class]]) {
            return (UITabBarController *)responder;
        }
        responder = responder.nextResponder;
    }
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIViewController *root = window.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            return (UITabBarController *)root;
        }
    }
    return nil;
}

- (BOOL)controllerLooksLikeDiscover:(UIViewController *)viewController {
    if (!viewController) return NO;
    NSString *className = NSStringFromClass(viewController.class);
    if ([className containsString:kWQMDiscoverClassName]) return YES;
    if ([className containsString:@"Discover"]) return YES;
    return NO;
}

/* 逐层拆开每个 tab 的导航栈，找发现页；返回的是 tab 槽位。 */
- (NSUInteger)indexOfClass:(NSString *)className inController:(UITabBarController *)controller {
    if (!controller) return NSUIntegerMax;
    NSArray<UIViewController *> *children = controller.viewControllers;
    for (NSUInteger index = 0; index < children.count; index++) {
        UIViewController *child = children[index];
        if ([NSStringFromClass(child.class) containsString:className]) return index;
        if ([child isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *inner in ((UINavigationController *)child).viewControllers) {
                if ([NSStringFromClass(inner.class) containsString:className]) return index;
            }
            if ([NSStringFromClass([((UINavigationController *)child).viewControllers.firstObject class])
                    containsString:className]) {
                return index;
            }
        }
    }
    return NSUIntegerMax;
}

- (NSUInteger)indexOfDiscoverInController:(UITabBarController *)controller {
    if (!controller) return NSUIntegerMax;
    NSArray<UIViewController *> *children = controller.viewControllers;
    for (NSUInteger index = 0; index < children.count; index++) {
        UIViewController *child = children[index];
        if ([self controllerLooksLikeDiscover:child]) return index;
        if ([child isKindOfClass:[UINavigationController class]]) {
            NSArray<UIViewController *> *stack = ((UINavigationController *)child).viewControllers;
            for (UIViewController *inner in stack) {
                if ([self controllerLooksLikeDiscover:inner]) return index;
            }
        }
    }
    return NSUIntegerMax;
}

- (NSUInteger)indexOfMainFrameInController:(UITabBarController *)controller {
    return [self indexOfClass:kWQMMainFrameClassName inController:controller];
}

- (UIViewController *)discoverController {
    UITabBarController *controller = self.tabBarController;
    NSUInteger index = self.discoverIndex;
    if (!controller || index == NSUIntegerMax) return nil;
    NSArray<UIViewController *> *children = controller.viewControllers;
    if (index >= children.count) return nil;

    UIViewController *child = children[index];
    if ([self controllerLooksLikeDiscover:child]) return child;
    if ([child isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)child;
        for (UIViewController *inner in nav.viewControllers) {
            if ([self controllerLooksLikeDiscover:inner]) return inner;
        }
        return nav.viewControllers.firstObject;
    }
    return child;
}

- (NSUInteger)resolveIndexForTitle:(NSString *)title
                           inItems:(NSArray<UITabBarItem *> *)items
                        controller:(UITabBarController *)controller
                      fallbackSlot:(NSUInteger)fallbackSlot {
    for (NSUInteger index = 0; index < items.count; index++) {
        if ([items[index].title isEqualToString:title]) return index;
    }

    NSArray<UIViewController *> *children = controller.viewControllers;
    for (NSUInteger index = 0; index < children.count && index < items.count; index++) {
        if ([children[index].tabBarItem.title isEqualToString:title]) return index;
    }

    return (fallbackSlot < items.count) ? fallbackSlot : NSUIntegerMax;
}

#pragma mark - 手势

- (void)installRecognizerIfNeeded {
    [self refresh];

    UITabBar *bar = self.tabBar;
    if (!bar) return;

    if (self.recognizer && self.recognizer.view == bar) {
        [self attachFailureRequirement];
        return;
    }

    if (self.recognizer) {
        [self.recognizer.view removeGestureRecognizer:self.recognizer];
        self.recognizer = nil;
    }

    WQMDiscoverPressRecognizer *recognizer =
        [[WQMDiscoverPressRecognizer alloc] initWithTarget:nil action:nil];
    /* 长按 0.4s 触发，短于这个时间归单击。 */
    recognizer.holdDelay = 0.4;

    __weak typeof(self) weakSelf = self;
    recognizer.isInDiscoverSlot = ^BOOL(CGPoint point) {
        return [weakSelf pointIsInDiscoverSlot:point];
    };
    recognizer.onArmed = ^{
        UIImpactFeedbackGenerator *generator =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [generator prepare];
        [generator impactOccurred];
    };
    recognizer.onTap = ^{
        [[WQMMomentsRouter shared] handleDiscoverTap];
    };
    recognizer.onLongPress = ^{
        [weakSelf openDiscoverPage];
    };

    [bar addGestureRecognizer:recognizer];
    self.recognizer = recognizer;

    [self attachFailureRequirement];

    WQMLog(@"recognizer installed on %@ (hold %.0fms, discover slot %ld)",
           NSStringFromClass(bar.class), recognizer.holdDelay * 1000.0,
           (long)(self.discoverIndex == NSUIntegerMax ? -1 : (NSInteger)self.discoverIndex));
}

/*
 * 关键：微信的 MMTabBarController 自带 singleTapGesture 处理底栏点击。
 * 手势之间不会因为"我们成功了"就自动让另一个失败，必须显式建立
 * "微信的 tap 必须等我们失败"的依赖，否则点发现会同时触发
 * 进朋友圈 + 切发现页，返回时就落在发现页上。
 */
- (void)attachFailureRequirement {
    WQMDiscoverPressRecognizer *recognizer = self.recognizer;
    UITabBarController *controller = self.tabBarController;
    if (!recognizer || !controller) return;

    id gesture = nil;
    @try {
        gesture = [controller valueForKey:@"singleTapGesture"];
    } @catch (NSException *exception) {
        gesture = nil;
    }
    if (![gesture isKindOfClass:[UIGestureRecognizer class]]) return;
    if (gesture == recognizer) return;

    if (self.observedSingleTap == gesture) {
        [gesture requireGestureRecognizerToFail:recognizer];
        return;
    }
    self.observedSingleTap = gesture;
    [gesture requireGestureRecognizerToFail:recognizer];
    WQMLog(@"linked %@.singleTapGesture to our recognizer",
           NSStringFromClass(controller.class));
}

- (void)layoutDidChange {
    if (self.tabBarHidden) {
        [self applyTabBarHidden];
    }
    if (self.forcingHighlight) {
        [self applyItemViewSelection];
    }
    if (!self.recognizer) {
        [self refresh];
        [self installRecognizerIfNeeded];
    } else {
        [self attachFailureRequirement];
    }
}

- (CGRect)slotRectForIndex:(NSUInteger)index {
    UITabBar *bar = self.tabBar;
    if (!bar || index == NSUIntegerMax) return CGRectZero;
    NSUInteger count = bar.items.count;
    if (count == 0 || index >= count) return CGRectZero;

    CGFloat slotWidth = CGRectGetWidth(bar.bounds) / (CGFloat)count;
    return CGRectMake(slotWidth * (CGFloat)index, 0, slotWidth, CGRectGetHeight(bar.bounds));
}

- (BOOL)pointIsInDiscoverSlot:(CGPoint)point {
    if (self.discoverIndex == NSUIntegerMax) return NO;
    CGRect slot = [self slotRectForIndex:self.discoverIndex];
    return !CGRectIsEmpty(slot) && CGRectContainsPoint(slot, point);
}

#pragma mark - 切换

- (void)selectTabAtIndex:(NSUInteger)index {
    UITabBarController *controller = self.tabBarController;
    if (!controller) return;
    if (index == NSUIntegerMax || index >= controller.viewControllers.count) return;

    SEL selectByItem = NSSelectorFromString(@"setTabBarItemSelectedIndex:");
    if ([controller respondsToSelector:selectByItem]) {
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(controller, selectByItem,
                                                            (unsigned long long)index);
    }

    /* 微信的实现若只更新了视图没有改 selectedIndex，这里补一次。 */
    if (controller.selectedIndex != index) {
        controller.selectedIndex = index;
    }
}

- (void)openDiscoverPage {
    if (self.discoverIndex == NSUIntegerMax) return;

    /* 页面出现前先吞掉可能的残留触摸，避免抬手落到九宫格某一项上。 */
    [WQMTouchShield installForDuration:0.30];
    [self selectTabAtIndex:self.discoverIndex];

    WQMLog(@"long press -> discover page (index %lu)", (unsigned long)self.discoverIndex);
}

#pragma mark - 底栏选中态

- (void)forceDiscoverHighlight:(BOOL)on {
    self.forcingHighlight = on;
    [self applyItemViewSelection];
}

#pragma mark - 底栏显隐

- (void)setTabBarHidden:(BOOL)hidden {
    _tabBarHidden = hidden;
    [self applyTabBarHidden];
}

#pragma mark - 红点状态

- (UIView *)discoverItemView {
    NSArray *views = wqm_item_views(self.tabBar);
    NSUInteger index = self.discoverIndex;
    if (!views || index == NSUIntegerMax || index >= views.count) return nil;
    id view = views[index];
    return [view isKindOfClass:[UIView class]] ? view : nil;
}

- (long long)discoverUnreadCount {
    UIView *itemView = [self discoverItemView];
    if (itemView) {
        long long count = 0;
        @try {
            count = [[itemView valueForKey:@"unreadCount"] longLongValue];
        } @catch (NSException *exception) {
            count = 0;
        }
        if (count > 0) return count;

        NSString *badge = nil;
        @try {
            badge = [itemView valueForKey:@"badgeString"];
        } @catch (NSException *exception) {
            badge = nil;
        }
        if ([badge isKindOfClass:[NSString class]] && badge.length) {
            return [badge longLongValue];
        }
    }
    return self.discoverItem.badgeValue.integerValue;
}

- (NSString *)discoverBadgeString {
    UIView *itemView = [self discoverItemView];
    if (itemView) {
        NSString *badge = nil;
        @try {
            badge = [itemView valueForKey:@"badgeString"];
        } @catch (NSException *exception) {
            badge = nil;
        }
        if ([badge isKindOfClass:[NSString class]] && badge.length) return badge;
    }
    return self.discoverItem.badgeValue;
}

- (BOOL)discoverBadgeVisible {
    UIView *itemView = [self discoverItemView];
    if (!itemView) return self.discoverItem.badgeValue.length > 0;
    if ([self discoverUnreadCount] > 0) return YES;

    /*
     * 没有数字的小红点：unreadCount / badgeString 都可能是空的，
     * 真正的可见性在 badgeView 上。
     */
    UIView *badgeView = nil;
    @try {
        badgeView = [itemView valueForKey:@"badgeView"];
    } @catch (NSException *exception) {
        badgeView = nil;
    }
    if ([badgeView isKindOfClass:[UIView class]]) {
        /*
         * 不能用 badgeView.window 判断：进入朋友圈时我们把整条底栏藏了，
         * badgeView 会随之脱离 window，但"红点是否存在"这个状态没变。
         */
        if (badgeView.superview && !badgeView.hidden && badgeView.alpha > 0.01f) return YES;
    }
    return NO;
}

/*
 * 只靠 hidden 不够：微信会在自己的 layout 里把底栏复位。
 * 同时把 alpha 和交互关掉，等于给底栏加了一个"隐形"状态，
 * 这样即使它中途 layout 一次也不会闪出来、更不会接走那次触摸。
 */
- (void)applyTabBarHidden {
    UITabBar *bar = self.tabBar;
    if (!bar) return;

    if (self.tabBarHidden) {
        bar.hidden = YES;
        bar.alpha = 0.0;
        bar.userInteractionEnabled = NO;
    } else {
        bar.hidden = NO;
        bar.alpha = 1.0;
        bar.userInteractionEnabled = YES;
    }
}

- (void)applyItemViewSelection {
    UITabBar *bar = self.tabBar;
    if (!bar) return;

    NSArray *views = wqm_item_views(bar);
    NSUInteger target = NSUIntegerMax;
    if (self.forcingHighlight) {
        target = self.discoverIndex;
    } else if (self.tabBarController) {
        target = self.tabBarController.selectedIndex;
    }
    if (target == NSUIntegerMax) return;

    if (views.count == 0) {
        /* 不是 MMTabBar 的机型：退回系统接口，至少别让高亮丢掉。 */
        if (target < bar.items.count) {
            bar.selectedItem = bar.items[target];
        }
        return;
    }

    for (NSUInteger index = 0; index < views.count; index++) {
        UIView *itemView = views[index];
        BOOL selected = (index == target);
        if ([itemView respondsToSelector:@selector(setSelected:)]) {
            [(id)itemView setSelected:selected];
        } else {
            @try {
                [itemView setValue:@(selected) forKey:@"isSelected"];
            } @catch (NSException *exception) {
                /* 什么都不做 */
            }
        }
    }
}

@end
