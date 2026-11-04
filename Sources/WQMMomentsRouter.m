#import <objc/runtime.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>

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

@interface WQMMomentsRouter () <UIGestureRecognizerDelegate>
@property (nonatomic, readwrite, getter=isShowing) BOOL showing;
/* 进入时刻，用来给"朋友圈返回信号"加一个短暂的防误触窗口。 */
@property (nonatomic) NSTimeInterval presentedAt;
@property (nonatomic) BOOL exiting;
@property (nonatomic) BOOL badgeClearedForSession;
@property (nonatomic) BOOL edgeSwipeTriggered;
@property (nonatomic, strong) UINavigationController *hostNavigation;
@property (nonatomic, weak) UITabBarController *hostParent;
@property (nonatomic, strong) UIViewController *momentsController;
@property (nonatomic, strong) Class resolvedClass;
@property (nonatomic, strong) UIScreenEdgePanGestureRecognizer *edgePan;
/* 进入前发现页的原始状态，退出时原样还回去。 */
@property (nonatomic) BOOL discoverInTimelineBefore;
@property (nonatomic) BOOL hasDiscoverInTimelineSnapshot;
@property (nonatomic, weak) id previousMomentsDelegate;
/* 已经被我们挂过手势的原生返回视图，避免重复添加。 */
@property (nonatomic, weak) UIView *hijackedBackView;
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
    self.presentedAt = CACurrentMediaTime();

    /*
     * 关键：先把朋友圈接回发现页。
     * 微信判断"朋友圈已读 / 该不该清发现页红点"看两样东西：
     *   1. timeline.delegate 是不是发现页（发现页实现了 onMarkWCObjectAsRead: 等回调）
     *   2. 发现页的 m_inTimeline 是否为 YES
     * 我们自己 alloc 出来的实例两者都是空的，微信的已读结算整条链路就被跳过了，
     * 表现就是"红点当场压下去、冷启动又回来"。这里补上，后续全交给微信自己。
     */
    [self attachMomentsToDiscoverPage];

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
 *
 * 导航栏被朋友圈藏掉时不补任何东西：原生朋友圈没有可见返回键，
 * 返回交给左缘侧滑，多一个悬浮箭头反而和原生不一致。
 */
/*
 * 朋友圈自己是全屏沉浸式的，左上角那颗返回是它设在 navigationItem 上的。
 * 那颗按钮的 action 是朋友圈内部逻辑：它会去 pop "发现页那条导航栈"，
 * 而我们是把朋友圈挂在独立的 hostNavigation 上，它 pop 不到任何东西 ——
 * 表现就是点了完全没反应（连我们的 pop hook 都进不去）。
 *
 * 所以这里把它接到我们自己的退出逻辑上：不改外观、不加新控件。
 */
- (void)hijackBackItem:(UIBarButtonItem *)item {
    if (!item) return;

    UIView *custom = item.customView;
    if (custom) {
        if (self.hijackedBackView == custom) return;
        custom.userInteractionEnabled = YES;
        /*
         * cancelsTouchesInView = NO：朋友圈原来的点击逻辑照常走，
         * 我们只是"顺便"接管一次退出，避免破坏它的埋点。
         */
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handleBackButton)];
        tap.cancelsTouchesInView = NO;
        [custom addGestureRecognizer:tap];
        self.hijackedBackView = custom;
        WQMLog(@"hijacked native back view %@", NSStringFromClass(custom.class));
        return;
    }

    if (item.target != self || item.action != @selector(handleBackButton)) {
        item.target = self;
        item.action = @selector(handleBackButton);
        WQMLog(@"hijacked native back item -> router");
    }
}

- (void)ensureBackButton {
    UIViewController *timeline = self.momentsController;
    UINavigationController *navigation = self.hostNavigation;
    if (!timeline || !navigation) return;
    if (![[WQMConfig wqm_shared] wqm_boolForKey:@"showBackButton" defaultValue:YES]) return;

    if (navigation.navigationBarHidden) return;

    /*
     * 朋友圈已经放了自己的返回按钮：接管它的点击，而不是再叠一个。
     * 这是之前的坑 —— 看到一个 leftBarButtonItem 就 return，
     * 结果那颗按钮的 action 在独立导航栈里是空操作。
     */
    UIBarButtonItem *existing = timeline.navigationItem.leftBarButtonItem;
    if (!existing && timeline.navigationItem.leftBarButtonItems.count > 0) {
        /* 有些版本把返回塞在数组里。 */
        existing = timeline.navigationItem.leftBarButtonItems.firstObject;
    }
    if (existing) {
        [self hijackBackItem:existing];
        return;
    }

    UIBarButtonItem *back =
        [[UIBarButtonItem alloc] initWithImage:wqm_chevron_image(24.0, 2.2)
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(handleBackButton)];
    back.accessibilityLabel = @"返回";
    timeline.navigationItem.leftBarButtonItem = back;
}

#pragma mark - 接回发现页（原生红点链路）

/*
 * m_inTimeline 是发现页的私有 ivar（_Bool）。用 runtime 直接读写，
 * 不走 KVC，避免微信哪天改了属性可见性抛异常。
 */
static BOOL *wqm_in_timeline_slot(id discover) {
    if (!discover) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(discover), "m_inTimeline");
    if (!ivar) return NULL;
    return (BOOL *)((char *)(__bridge void *)discover + ivar_getOffset(ivar));
}

- (void)attachMomentsToDiscoverPage {
    UIViewController *discover = [[WQMTabBarBridge shared] discoverController];
    if (!discover) {
        WQMLog(@"discover page unavailable; moments runs standalone, badge stays native");
        return;
    }

    /* delegate 是 weak，发现页活着就不会出事。先记住原值，退出时还原。 */
    @try {
        self.previousMomentsDelegate = [self.momentsController valueForKey:@"delegate"];
    } @catch (NSException *exception) {
        self.previousMomentsDelegate = nil;
    }
    @try {
        [self.momentsController setValue:discover forKey:@"delegate"];
        WQMLog(@"moments delegate -> %@ (was %@)", NSStringFromClass(discover.class),
               self.previousMomentsDelegate ? NSStringFromClass([self.previousMomentsDelegate class]) : @"nil");
    } @catch (NSException *exception) {
        WQMLog(@"bind moments delegate failed: %@", exception.reason);
    }

    BOOL *slot = wqm_in_timeline_slot(discover);
    if (slot) {
        self.discoverInTimelineBefore = *slot;
        self.hasDiscoverInTimelineSnapshot = YES;
        *slot = YES;
        WQMLog(@"discover m_inTimeline %d -> 1", self.discoverInTimelineBefore);
    } else {
        self.hasDiscoverInTimelineSnapshot = NO;
        WQMLog(@"discover has no m_inTimeline ivar");
    }
}

- (void)detachMomentsFromDiscoverPage {
    UIViewController *discover = [[WQMTabBarBridge shared] discoverController];

    @try {
        [self.momentsController setValue:self.previousMomentsDelegate forKey:@"delegate"];
    } @catch (NSException *exception) {
        /* 已经销毁就算了 */
    }
    self.previousMomentsDelegate = nil;

    if (discover && self.hasDiscoverInTimelineSnapshot) {
        BOOL *slot = wqm_in_timeline_slot(discover);
        if (slot) *slot = self.discoverInTimelineBefore;
    }
    self.hasDiscoverInTimelineSnapshot = NO;
}

/* 微信改过导航栏可见性之后，重新确认一次返回项（导航栏可见时才有）。 */
- (void)refreshChrome {
    if (!self.showing) return;
    [self ensureBackButton];
}

- (void)installBackSwipeOn:(UIView *)view {
    if (!view) return;
    UIScreenEdgePanGestureRecognizer *pan =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(handleEdgePan:)];
    pan.edges = UIRectEdgeLeft;
    pan.maximumNumberOfTouches = 1;
    /* 不抢触摸：朋友圈里的滚动、点击都照常，我们只是"顺便"看到这次滑动。 */
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delegate = self;
    [view addGestureRecognizer:pan];
    self.edgePan = pan;
    self.edgeSwipeTriggered = NO;
}

/*
 * 微信自己的侧滑返回是 MMUINavigationController 里一套自定义转场，
 * 而且栈里只剩一个页面时 shouldInteractivePop 会返回 NO，手势直接被关掉。
 * 所以这里自己判：跟手过 60pt 就退，不要求用户"滑到底再松手"。
 */
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.edgeSwipeTriggered = NO;
        return;
    }
    if (pan.state != UIGestureRecognizerStateChanged) return;
    if (self.edgeSwipeTriggered || !self.showing) return;

    CGPoint translation = [pan translationInView:pan.view];
    if (translation.x < 60.0) return;

    self.edgeSwipeTriggered = YES;
    if (self.isAtTimelineRoot) {
        [self exitAnimated:YES reason:@"edge-swipe"];
        return;
    }
    /*
     * 二级页面：交给导航栈自己 pop。正在做转场时不插手，
     * 否则会和微信的交互式转场抢状态。
     */
    if (self.hostNavigation.transitionCoordinator) return;
    [self.hostNavigation popViewControllerAnimated:YES];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.edgePan) return YES;
    if (!self.showing) return NO;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    /* 只认"向右"的滑动，竖向滚动不参与。 */
    return velocity.x > 0 && fabs(velocity.x) > fabs(velocity.y);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return gestureRecognizer == self.edgePan || other == self.edgePan;
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

/*
 * 朋友圈顶栏按钮的兜底通道。
 * 刚进来的半秒内忽略：有些版本会在 viewDidAppear 里也走一遍这个方法。
 */
- (void)handleNativeReturnSignal {
    if (!self.showing) return;
    if (CACurrentMediaTime() - self.presentedAt < 0.5) {
        WQMLog(@"ignored return signal during entry window");
        return;
    }
    if (!self.isAtTimelineRoot) {
        [self.hostNavigation popViewControllerAnimated:YES];
        return;
    }
    [self exitAnimated:YES reason:@"timeline-return"];
}

#pragma mark - 红点

- (void)scheduleBadgeClear {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self.showing || !self.hostNavigation) return;
        WQMLog(@"post-entry chrome: navBarHidden=%d stack=%lu",
               self.hostNavigation.navigationBarHidden,
               (unsigned long)self.hostNavigation.viewControllers.count);
        [self refreshChrome];
        [self clearBadgeIfNeeded];
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
     * 先让微信把这一轮"已读到哪"结算掉，再断开 delegate。
     * 顺序反了的话，onTimeLineViewReturn 会因为 m_inTimeline 已复位而空转。
     */
    [[WQMBadgeCoordinator shared] momentsTimelineWillDisappear];
    [self detachMomentsFromDiscoverPage];

    /*
     * 真正撤视图、还把底栏还原：只在动画结束后做。
     * 提前做的话，底栏会在朋友圈还在往右滑的时候先冒出来。
     */
    void (^teardown)(void) = ^{
        [navigation willMoveToParentViewController:nil];
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
    };

    [navigation beginAppearanceTransition:NO animated:animated];

    if (animated && navigation.view.superview) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            navigation.view.transform =
                CGAffineTransformMakeTranslation(CGRectGetWidth(navigation.view.bounds), 0);
        } completion:^(BOOL finished) {
            teardown();
        }];
        return;
    }

    teardown();
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

        /*
         * 朋友圈的 navigationItem 是它自己在 viewDidLoad / viewWillAppear 里拼的，
         * 有时我们第一次看的时候还没挂上去。晚一点再接管一次。
         */
        __weak typeof(self) weakSelf = self;
        for (NSNumber *delay in @[@0.3, @1.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self.showing) return;
                [self ensureBackButton];
            });
        }
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
