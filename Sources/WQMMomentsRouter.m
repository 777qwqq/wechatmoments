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
static const char kWQMMomentsCachedIvar[] = "m_timelineViewController";

/* 手绘一个返回箭头，避免依赖 SF Symbols（theos 的 SDK 版本不一定有）。 */
static UIImage *wqm_chevron_image(CGFloat size, CGFloat lineWidth) {
    if (size <= 0) return nil;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(context, lineWidth);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextMoveToPoint(context, size * 0.62, size * 0.20);
    CGContextAddLineToPoint(context, size * 0.36, size * 0.50);
    CGContextAddLineToPoint(context, size * 0.62, size * 0.80);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@interface WQMMomentsRouter ()
@property (nonatomic, readwrite, getter=isShowing) BOOL showing;
@property (nonatomic) BOOL exiting;
@property (nonatomic) BOOL badgeClearedForSession;
@property (nonatomic, strong) UINavigationController *hostNavigation;
@property (nonatomic, weak) UITabBarController *hostParent;
@property (nonatomic, strong) UIViewController *momentsController;
@property (nonatomic, strong) Class resolvedClass;
@property (nonatomic, strong) UIScreenEdgePanGestureRecognizer *edgePan;
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

    /*
     * 原生朋友圈是整屏的：占满 tab 容器，底栏稍后整条收起。
     * 不再按底栏上沿截断内容区。
     */
    navigationController.view.frame = host.view.bounds;
    navigationController.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    /*
     * 状态先落定，再挂视图：viewDidAppear 是同步派发的，
     * 如果那时 showing 还是 NO，微信自己的"已读上报 + 红点重算"会被我们挡掉。
     */
    self.hostNavigation = navigationController;
    self.hostParent = host;
    self.momentsController = controller;
    self.showing = YES;
    self.badgeClearedForSession = NO;

    [self configureNavigationBarOf:navigationController];
    [self installBackSwipeOn:navigationController.view];
    [bridge setTabBarHidden:YES];

    /*
     * 手动 addChild 不会自动走 appearance 生命周期，
     * 必须显式 begin/end 一次，viewWillAppear / viewDidAppear 才会真的派发到朋友圈。
     */
    [host addChildViewController:navigationController];
    [navigationController beginAppearanceTransition:YES animated:NO];
    [host.view addSubview:navigationController.view];
    [navigationController endAppearanceTransition];
    [navigationController didMoveToParentViewController:host];

    [WQMTouchShield installForDuration:0.25];

    WQMLog(@"enter moments via %@ (nav %@, frame %@)",
           NSStringFromClass(controller.class), NSStringFromClass(navClass),
           NSStringFromCGRect(navigationController.view.frame));

    [self scheduleBadgeClear];
    [self verifyPresentation];
}

#pragma mark - 顶栏与返回

/*
 * 原生朋友圈的顶栏是透明的：封面图透到状态栏下面，左上角一个白色返回箭头，
 * 右上角相机。这里只补"返回"这一半，其余交给朋友圈自己画。
 */
- (void)configureNavigationBarOf:(UINavigationController *)navigationController {
    BOOL hideBar = [[WQMConfig wqm_shared] wqm_boolForKey:@"hideHostNavBar" defaultValue:NO];
    navigationController.navigationBarHidden = hideBar;
    if (hideBar) {
        WQMLog(@"host nav bar hidden by config; back is edge-swipe only");
        return;
    }

    UINavigationBar *bar = navigationController.navigationBar;
    [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    [bar setShadowImage:[UIImage new]];
    bar.translucent = YES;
    bar.tintColor = [UIColor whiteColor];

    if (![[WQMConfig wqm_shared] wqm_boolForKey:@"showBackButton" defaultValue:YES]) return;
    [self ensureBackButton];
}

/*
 * 朋友圈自己会在 viewDidLoad / viewWillAppear 里整理 navigationItem，
 * 我们提前塞的返回箭头可能被它清掉，所以出现之后再补一次（已有就不覆盖）。
 */
- (void)ensureBackButton {
    UIViewController *timeline = self.momentsController;
    UINavigationController *navigation = self.hostNavigation;
    if (!timeline || !navigation || navigation.navigationBarHidden) return;
    if (![[WQMConfig wqm_shared] wqm_boolForKey:@"showBackButton" defaultValue:YES]) return;
    if (timeline.navigationItem.leftBarButtonItem) return;

    UIBarButtonItem *back =
        [[UIBarButtonItem alloc] initWithImage:wqm_chevron_image(24.0, 2.2)
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(handleBackButton)];
    back.accessibilityLabel = @"返回";
    timeline.navigationItem.leftBarButtonItem = back;
}

- (void)installBackSwipeOn:(UIView *)view {
    if (!view) return;
    UIScreenEdgePanGestureRecognizer *pan =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(handleEdgePan:)];
    pan.edges = UIRectEdgeLeft;
    pan.maximumNumberOfTouches = 1;
    [view addGestureRecognizer:pan];
    self.edgePan = pan;
}

/* 栈里只有时间线首屏时，系统侧滑是禁用的，这里补一条左缘手势。 */
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateEnded) return;
    if (!self.showing || !self.isAtTimelineRoot) return;

    CGPoint translation = [pan translationInView:pan.view];
    CGPoint velocity = [pan velocityInView:pan.view];
    if (translation.x > 50.0 || velocity.x > 400.0) {
        [self exitAnimated:YES reason:@"edge-swipe"];
    }
}

- (void)handleBackButton {
    if (!self.showing) return;
    /* 二级页面（详情 / 图片 / 评论）逐级返回，只有首屏才跳出朋友圈。 */
    if (!self.isAtTimelineRoot) {
        [self.hostNavigation popViewControllerAnimated:YES];
        return;
    }
    [self exitAnimated:YES reason:@"back-button"];
}

#pragma mark - 红点

- (void)scheduleBadgeClear {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf ensureBackButton];
        [weakSelf clearBadgeIfNeeded];
    });
}

- (void)clearBadgeIfNeeded {
    if (!self.showing || !self.momentsController) return;
    if (self.badgeClearedForSession) return;
    self.badgeClearedForSession = YES;
    [[WQMBadgeCoordinator shared] momentsTimelineDidAppear:self.momentsController];
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
            /* 至少让用户能按老路径进朋友圈，而不是点了没反应。 */
            [[WQMTabBarBridge shared] openDiscoverPage];
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

    if (self.edgePan) {
        [self.edgePan.view removeGestureRecognizer:self.edgePan];
        self.edgePan = nil;
    }

    /*
     * 顺序：先撤整屏视图（它盖着底栏），再把底栏放回来、把选中态切到"微信"。
     * 用户看到的是朋友圈直接消失、回到消息主页，中间不会闪一下发现页。
     */
    [navigation willMoveToParentViewController:nil];
    [navigation beginAppearanceTransition:NO animated:animated];
    [navigation.view removeFromSuperview];
    [navigation endAppearanceTransition];
    [navigation removeFromParentViewController];

    [bridge setTabBarHidden:NO];
    [bridge forceDiscoverHighlight:NO];

    if (host && host.selectedIndex != bridge.messageIndex) {
        host.selectedIndex = bridge.messageIndex;
    }

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
    if (isTimelineRoot) {
        [self ensureBackButton];
        [self clearBadgeIfNeeded];
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
