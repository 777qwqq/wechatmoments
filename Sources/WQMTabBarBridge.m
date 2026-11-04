#import <math.h>
#import <QuartzCore/QuartzCore.h>
#import "WQMTabBarBridge.h"
#import "WQMConfig.h"
#import "WQMDiscoverPressRecognizer.h"
#import "WQMLog.h"
#import "WQMMomentsRouter.h"
#import "WQMTouchShield.h"

static NSString * const kWQMDiscoverTitle = @"发现";
static NSString * const kWQMMessageTitle = @"微信";
static const NSUInteger kWQMDiscoverFallbackIndex = 2;

@interface WQMTabBarBridge ()
@property (nonatomic, readwrite, weak) UITabBar *tabBar;
@property (nonatomic, readwrite, weak) UITabBarController *tabBarController;
@property (nonatomic, readwrite, weak) UITabBarItem *discoverItem;
@property (nonatomic, readwrite) NSUInteger discoverIndex;
@property (nonatomic, readwrite) NSUInteger messageIndex;
@property (nonatomic, weak) WQMDiscoverPressRecognizer *recognizer;
@property (nonatomic, strong) UITabBarItem *savedSelectedItem;
@property (nonatomic, readwrite) BOOL forcingHighlight;
@property (nonatomic, readwrite) BOOL allowsDiscoverSelection;
@property (nonatomic) BOOL assertingHighlight;
@property (nonatomic) NSTimeInterval redemptionDeadline;
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
 * 这里按"标题里有 发现/微信"给候选打分，避免把识别器装到错误的 bar 上。
 */
static NSInteger wqm_score_tab_bar(UIView *bar) {
    id items = nil;
    @try {
        items = [bar valueForKey:@"items"];
    } @catch (NSException *exception) {
        return NSIntegerMin;
    }
    if (![items isKindOfClass:[NSArray class]]) return NSIntegerMin;

    NSArray *array = (NSArray *)items;
    if (array.count == 0) return NSIntegerMin;

    NSInteger score = 0;
    if (array.count >= 3) score += 1;
    if (array.count == 4) score += 1;
    if (CGRectGetWidth(bar.bounds) > 0) score += 1;

    for (id item in array) {
        NSString *title = nil;
        @try {
            title = [item valueForKey:@"title"];
        } @catch (NSException *exception) {
            continue;
        }
        if ([title isEqualToString:@"发现"]) score += 4;
        if ([title isEqualToString:@"微信"]) score += 2;
    }
    return score;
}

static void wqm_collect_subviews(UIView *root, NSMutableArray<UIView *> *out) {
    for (UIView *subview in root.subviews) {
        [out addObject:subview];
        wqm_collect_subviews(subview, out);
    }
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

    NSUInteger discover = [self resolveIndexForTitle:kWQMDiscoverTitle
                                             inItems:items
                                          controller:controller
                                        fallbackSlot:kWQMDiscoverFallbackIndex];
    self.discoverIndex = discover;
    self.discoverItem = (discover < items.count) ? items[discover] : nil;

    self.messageIndex = [self resolveIndexForTitle:kWQMMessageTitle
                                           inItems:items
                                        controller:controller
                                      fallbackSlot:0];
}

- (UITabBarController *)controllerForTabBar:(UITabBar *)bar {
    UIResponder *responder = bar;
    while (responder) {
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

    /* 标题拿不到时，用底栏上那个文字标签的实际位置反推槽位。 */
    NSUInteger byLabel = [self indexForLabelWithTitle:title itemCount:items.count];
    if (byLabel != NSUIntegerMax) return byLabel;

    return (fallbackSlot < items.count) ? fallbackSlot : NSUIntegerMax;
}

- (NSUInteger)indexForLabelWithTitle:(NSString *)title itemCount:(NSUInteger)count {
    UITabBar *bar = self.tabBar;
    if (!bar || count == 0) return NSUIntegerMax;

    CGFloat slotWidth = CGRectGetWidth(bar.bounds) / (CGFloat)count;
    if (slotWidth <= 0) return NSUIntegerMax;

    NSMutableArray<UIView *> *subviews = [NSMutableArray array];
    wqm_collect_subviews(bar, subviews);

    for (UIView *view in subviews) {
        if (![view isKindOfClass:[UILabel class]]) continue;
        UILabel *label = (UILabel *)view;
        if (![label.text isEqualToString:title]) continue;

        CGPoint center = [label.superview convertPoint:label.center toView:bar];
        NSInteger index = (NSInteger)floor(center.x / slotWidth);
        if (index >= 0 && index < (NSInteger)count) return (NSUInteger)index;
    }
    return NSUIntegerMax;
}

#pragma mark - 手势

- (void)installRecognizerIfNeeded {
    if (![[WQMConfig wqm_shared] wqm_isEnabled]) return;

    [self refresh];

    UITabBar *bar = self.tabBar;
    if (!bar) return;
    if (self.recognizer && self.recognizer.view == bar) return;

    if (self.recognizer) {
        [self.recognizer.view removeGestureRecognizer:self.recognizer];
        self.recognizer = nil;
    }

    double holdMilliseconds = [[WQMConfig wqm_shared] wqm_doubleForKey:@"holdDelayMs" defaultValue:400.0];
    WQMDiscoverPressRecognizer *recognizer =
        [[WQMDiscoverPressRecognizer alloc] initWithTarget:nil action:nil];
    recognizer.holdDelay = MAX(0.2, MIN(0.8, holdMilliseconds / 1000.0));

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
        [weakSelf markTapForRedemption];
        [[WQMMomentsRouter shared] handleDiscoverTap];
    };
    recognizer.onLongPress = ^{
        [weakSelf openDiscoverPage];
    };

    [bar addGestureRecognizer:recognizer];
    self.recognizer = recognizer;
    WQMLog(@"recognizer installed on %@ (hold %.0fms)", NSStringFromClass(bar.class), recognizer.holdDelay * 1000.0);
}

- (void)layoutDidChange {
    /* layoutSubviews 触发很频繁，这里只做最便宜的检查。 */
    if (self.forcingHighlight) {
        [self assertDiscoverHighlight];
    }
    if (!self.recognizer) {
        [self refresh];
        [self installRecognizerIfNeeded];
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

#pragma mark - 长按：打开原发现页

- (void)openDiscoverPage {
    UITabBarController *controller = self.tabBarController;
    if (!controller || self.discoverIndex == NSUIntegerMax) return;

    /* 页面出现前先吞掉可能的残留触摸，避免抬手落到九宫格某一项上。 */
    [WQMTouchShield installForDuration:0.30];

    self.allowsDiscoverSelection = YES;
    controller.selectedIndex = self.discoverIndex;
    self.allowsDiscoverSelection = NO;

    WQMLog(@"long press -> discover page (index %lu)", (unsigned long)self.discoverIndex);
}

#pragma mark - 底栏选中态

- (void)forceDiscoverHighlight:(BOOL)on {
    UITabBar *bar = self.tabBar;
    UITabBarItem *item = self.discoverItem;
    if (!bar || !item) return;

    if (on) {
        if (!self.forcingHighlight) {
            self.savedSelectedItem = bar.selectedItem;
        }
        self.forcingHighlight = YES;
        [self assertDiscoverHighlight];
    } else {
        self.forcingHighlight = NO;
        /*
         * 以"当前 selectedIndex"为准还原：进入朋友圈期间可能被切过 tab
         * （例如退出时统一回消息主页），此时 savedSelectedItem 已经过时。
         */
        UITabBarItem *restore = nil;
        if (self.tabBarController) {
            NSInteger index = (NSInteger)self.tabBarController.selectedIndex;
            if (index >= 0 && index < (NSInteger)bar.items.count) {
                restore = bar.items[(NSUInteger)index];
            }
        }
        if (!restore) restore = self.savedSelectedItem;
        self.savedSelectedItem = nil;
        if (restore && bar.selectedItem != restore) {
            [self setSelectedItemWithoutReassert:restore];
        }
    }
}

- (void)assertDiscoverHighlight {
    UITabBar *bar = self.tabBar;
    UITabBarItem *item = self.discoverItem;
    if (!bar || !item || self.assertingHighlight) return;
    if (bar.selectedItem == item) return;

    [self setSelectedItemWithoutReassert:item];
}

- (void)setSelectedItemWithoutReassert:(UITabBarItem *)item {
    if (self.assertingHighlight) return;
    /* 兜底找到的"类 TabBar 视图"不一定实现了 setter，没实现就放弃钉选。 */
    if (![self.tabBar respondsToSelector:@selector(setSelectedItem:)]) return;
    self.assertingHighlight = YES;
    self.tabBar.selectedItem = item;
    self.assertingHighlight = NO;
}

#pragma mark - 误选认领

- (void)markTapForRedemption {
    self.redemptionDeadline = CACurrentMediaTime() + 1.0;
}

- (BOOL)consumeTapRedemption {
    if (self.redemptionDeadline <= 0) return NO;
    BOOL valid = CACurrentMediaTime() <= self.redemptionDeadline;
    self.redemptionDeadline = 0;
    return valid;
}

@end
