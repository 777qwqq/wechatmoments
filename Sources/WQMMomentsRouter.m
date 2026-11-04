#import <objc/runtime.h>

#import "WQMMomentsRouter.h"
#import "WQMBadgeCoordinator.h"
#import "WQMConfig.h"
#import "WQMLog.h"
#import "WQMTabBarBridge.h"
#import "WQMTouchShield.h"

static NSString * const kKeyLearnedMomentsClass = @"learnedMomentsClass";
static NSString * const kKeyMomentsClass = @"momentsClass";
static NSString * const kKeyExtraClasses = @"extraMomentsClasses";

/* 微信 8.0.5x 的真实类名（来自 class-dump 头文件，8.0.54 / 8.0.55 一致）。 */
static NSString * const kWQMMomentsControllerClass = @"WCTimeLineViewController";
static NSString * const kWQMMomentsCachedIvar = "m_timelineViewController";

@interface WQMMomentsRouter ()
@property (nonatomic, readwrite, getter=isShowing) BOOL showing;
@property (nonatomic) BOOL exiting;
@property (nonatomic) BOOL badgeClearedForSession;
@property (nonatomic, strong) UINavigationController *hostNavigation;
@property (nonatomic, weak) UITabBarController *hostParent;
@property (nonatomic, strong) UIViewController *momentsController;
@property (nonatomic, strong) Class resolvedClass;
@end

@implementation WQMMomentsRouter

+ (instancetype)shared {
    static WQMMomentsRouter *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - 入口

- (void)handleDiscoverTap {
    if (![[WQMConfig wqm_shared] wqm_isEnabled]) return;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];

    if (self.showing) {
        /* 已经在朋友圈：再点一次"发现"就当作退出，避免出现两个时间线。 */
        [self exitAnimated:NO reason:@"tap-again"];
        return;
    }

    UIViewController *controller = [self instantiateMomentsController];
    if (!controller) {
        WQMLog(@"moments class unresolved (%@ missing), fallback to discover page",
               kWQMMomentsControllerClass);
        [bridge openDiscoverPage];
        return;
    }

    [self presentMomentsController:controller];
}

- (void)presentMomentsController:(UIViewController *)controller {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    UITabBarController *host = bridge.tabBarController;
    if (!host || !host.view) {
        WQMLog(@"no tab controller to host moments");
        return;
    }

    /*
     * 用微信自己的导航控制器类型：朋友圈内部会按 MMUINavigationController
     * 判断一些返回/转场行为，普通 UINavigationController 可能走到异常分支。
     */
    Class navClass = NSClassFromString(@"MMUINavigationController");
    if (!navClass || ![navClass isSubclassOfClass:[UINavigationController class]]) {
        navClass = [UINavigationController class];
    }
    UINavigationController *navigationController =
        [[navClass alloc] initWithRootViewController:controller];

    /* 内容区高度截到底栏上沿：朋友圈的列表不会藏到底栏后面。 */
    CGRect contentFrame = host.view.bounds;
    UITabBar *tabBar = bridge.tabBar;
    if (tabBar && tabBar.window == host.view.window) {
        CGRect barRect = [tabBar convertRect:tabBar.bounds toView:host.view];
        if (barRect.size.height > 0 &&
            barRect.origin.y > 0 &&
            CGRectGetMinY(barRect) < CGRectGetMaxY(contentFrame)) {
            contentFrame.size.height = CGRectGetMinY(barRect);
        }
    }
    navigationController.view.frame = contentFrame;
    navigationController.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    navigationController.navigationBarHidden =
        [[WQMConfig wqm_shared] wqm_boolForKey:@"hideHostNavBar" defaultValue:YES];

    [host addChildViewController:navigationController];

    /* 底栏可能被套在一层容器里，往上找到 tab 容器的直接子视图再插到它下面。 */
    UIView *anchor = nil;
    if (tabBar) {
        UIView *walker = tabBar;
        while (walker.superview && walker.superview != host.view) {
            walker = walker.superview;
        }
        if (walker.superview == host.view) anchor = walker;
    }

    if (anchor) {
        [host.view insertSubview:navigationController.view belowSubview:anchor];
    } else {
        [host.view addSubview:navigationController.view];
    }
    [navigationController didMoveToParentViewController:host];

    self.hostNavigation = navigationController;
    self.hostParent = host;
    self.momentsController = controller;
    self.showing = YES;
    self.badgeClearedForSession = NO;

    [bridge forceDiscoverHighlight:YES];
    [WQMTouchShield installForDuration:0.25];

    WQMLog(@"enter moments via %@ (nav %@, frame %@)",
           NSStringFromClass(controller.class), NSStringFromClass(navClass),
           NSStringFromCGRect(contentFrame));

    [self verifyPresentation];
}

/* 自检：VC 起来了却没挂到窗口上，说明这类实例化方式在真机上不可用，及时退出。 */
- (void)verifyPresentation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf.showing || !strongSelf.momentsController) return;
        UIView *view = strongSelf.momentsController.view;
        if (!view.window) {
            WQMLog(@"moments view not in window, aborting presentation");
            [strongSelf exitAnimated:NO reason:@"not-visible"];
        }
    });
}

#pragma mark - 退出

- (void)exitAnimated:(BOOL)animated reason:(NSString *)reason {
    if (!self.showing || self.exiting) return;
    self.exiting = YES;
    self.showing = NO;

    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    UITabBarController *host = self.hostParent;
    UINavigationController *navigation = self.hostNavigation;

    /*
     * 顺序很重要：先把底栏切回"微信"，此时朋友圈的视图还盖在上面，
     * 用户看不到底下的内容跳变；再撤视图；最后还原选中态。
     */
    if (host && host.selectedIndex != bridge.messageIndex) {
        host.selectedIndex = bridge.messageIndex;
    }

    [navigation willMoveToParentViewController:nil];
    [navigation.view removeFromSuperview];
    [navigation removeFromParentViewController];

    [bridge forceDiscoverHighlight:NO];

    self.hostNavigation = nil;
    self.hostParent = nil;
    self.momentsController = nil;
    self.exiting = NO;

    WQMLog(@"exit moments (%@)", reason);
}

- (BOOL)ownsNavigationController:(UINavigationController *)navigationController {
    return self.showing && navigationController != nil && navigationController == self.hostNavigation;
}

- (BOOL)isAtTimelineRoot {
    if (!self.showing || !self.hostNavigation) return NO;
    return self.hostNavigation.viewControllers.count <= 1;
}

- (BOOL)ownsViewController:(UIViewController *)viewController {
    if (!self.showing || !viewController) return NO;
    if (viewController == self.momentsController) return YES;
    if (self.hostNavigation && viewController == self.hostNavigation.topViewController) return YES;
    return NO;
}

- (void)handleTabSwitchToIndex:(NSUInteger)index {
    if (!self.showing) return;
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    if (index == bridge.discoverIndex) return;
    [self exitAnimated:NO reason:@"tab-switch"];
}

#pragma mark - 生命周期回调

- (void)noteViewControllerAppeared:(UIViewController *)viewController {
    if (!viewController || !self.showing) return;

    BOOL isTimelineRoot = (viewController == self.momentsController) ||
        (self.hostNavigation && viewController == self.hostNavigation.viewControllers.firstObject);
    if (isTimelineRoot && !self.badgeClearedForSession) {
        self.badgeClearedForSession = YES;
        [[WQMBadgeCoordinator shared] momentsTimelineDidAppear:self.momentsController];
    }
}

- (void)notePushedController:(UIViewController *)viewController
      navigationController:(UINavigationController *)navigationController {
    /* 保留接口：真机诊断时可以用来观察朋友圈内部的导航行为。 */
    if (!self.showing || navigationController != self.hostNavigation) return;
    if (!viewController) return;
    WQMLog(@"moments push -> %@ (stack %lu)",
           NSStringFromClass(viewController.class),
           (unsigned long)navigationController.viewControllers.count);
}

#pragma mark - 类名解析

- (Class)resolvedMomentsClass {
    if (self.resolvedClass) return self.resolvedClass;

    WQMConfig *config = [WQMConfig wqm_shared];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *extra = [config wqm_stringForKey:kKeyExtraClasses defaultValue:@""];
    if (extra.length) {
        for (NSString *piece in [extra componentsSeparatedByString:@","]) {
            NSString *trimmed = [piece stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length) [names addObject:trimmed];
        }
    }
    [names addObject:[config wqm_stringForKey:kKeyMomentsClass defaultValue:@""]];
    [names addObject:[config wqm_stringForKey:kKeyLearnedMomentsClass defaultValue:@""]];

    [names addObject:kWQMMomentsControllerClass];
    /* 旧版本 / 改版后的兜底名，命中即用。 */
    [names addObjectsFromArray:@[
        @"WCTimeLineViewController",
        @"WCMomentsTimelineViewController",
        @"MMMomentsViewController"
    ]];

    for (NSString *name in names) {
        Class candidate = [self validClassNamed:name];
        if (candidate) {
            WQMLog(@"using moments class %@", name);
            self.resolvedClass = candidate;
            return candidate;
        }
    }

    WQMLog(@"no moments class found in runtime");
    return Nil;
}

- (Class)validClassNamed:(NSString *)name {
    if (name.length == 0) return Nil;
    Class candidate = NSClassFromString(name);
    if (!candidate) return Nil;
    if (![candidate isSubclassOfClass:[UIViewController class]]) return Nil;
    return candidate;
}

/*
 * 发现页自己缓存了一份朋友圈实例（m_timelineViewController）。
 * 复用它是成功率最高的做法：session、数据源、已读状态都是微信自己初始化好的。
 * 只接受"当前没有父控制器"的实例，避免把一个正在别的导航栈里的页面抢过来。
 */
- (UIViewController *)cachedTimelineFromDiscoverPage {
    UIViewController *discover = [[WQMTabBarBridge shared] discoverController];
    if (!discover) return nil;

    Ivar ivar = class_getInstanceVariable(object_getClass(discover), kWQMMomentsCachedIvar);
    if (!ivar) return nil;

    id value = nil;
    @try {
        value = object_getIvar(discover, ivar);
    } @catch (NSException *exception) {
        return nil;
    }
    if (![value isKindOfClass:[UIViewController class]]) return nil;

    UIViewController *candidate = (UIViewController *)value;
    if (candidate.parentViewController != nil) return nil;
    if (candidate.isViewLoaded && candidate.view.window) return nil;

    WQMLog(@"reusing cached timeline from discover page");
    return candidate;
}

- (UIViewController *)instantiateMomentsController {
    Class controllerClass = [self resolvedMomentsClass];
    if (!controllerClass) return nil;

    UIViewController *cached = [self cachedTimelineFromDiscoverPage];
    if (cached) return cached;

    UIViewController *controller = nil;
    @try {
        controller = [[controllerClass alloc] init];
    } @catch (NSException *exception) {
        WQMLog(@"init failed: %@", exception.reason);
    }

    if (![controller isKindOfClass:[UIViewController class]]) {
        @try {
            controller = [[controllerClass alloc] initWithNibName:nil bundle:nil];
        } @catch (NSException *exception) {
            WQMLog(@"initWithNibName failed: %@", exception.reason);
        }
    }

    if (![controller isKindOfClass:[UIViewController class]]) return nil;

    /* 触发一次 view 加载，避免首帧尺寸为 0 时布局错乱。 */
    (void)controller.view;
    return controller;
}

@end
