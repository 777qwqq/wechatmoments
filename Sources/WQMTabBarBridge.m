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

static UIView *wqm_find_tab_bar_view(UIView *root, int depth) {
    if (!root || depth > 12) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return root;

    NSString *className = NSStringFromClass(root.class);
    if ([className containsString:@"TabBar"] &&
        [root respondsToSelector:NSSelectorFromString(@"items")] &&
        [root respondsToSelector:NSSelectorFromString(@"selectedItem")]) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = wqm_find_tab_bar_view(subview, depth + 1);
        if (found) return found;
    }
    return nil;
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
        bar = nil;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            UIView *found = wqm_find_tab_bar_view(window, 0);
            if (found) {
                bar = (UITabBar *)found;
                break;
            }
        }
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
        UITabBarItem *restore = self.savedSelectedItem;
        if (!restore && self.tabBarController) {
            NSInteger index = (NSInteger)self.tabBarController.selectedIndex;
            if (index >= 0 && index < (NSInteger)bar.items.count) {
                restore = bar.items[(NSUInteger)index];
            }
        }
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
