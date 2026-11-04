#import "WQMMomentsRouter.h"
#import "WQMBadgeCoordinator.h"
#import "WQMConfig.h"
#import "WQMLog.h"
#import "WQMPreferences.h"
#import "WQMTabBarBridge.h"
#import "WQMTouchShield.h"

static NSString * const kKeyLearnedMomentsClass = @"learnedMomentsClass";
static NSString * const kKeyMomentsClass = @"momentsClass";
static NSString * const kKeyExtraClasses = @"extraMomentsClasses";

@interface WQMMomentsRouter ()
@property (nonatomic, readwrite, getter=isShowing) BOOL showing;
@property (nonatomic) BOOL exiting;
@property (nonatomic) BOOL badgeClearedForSession;
@property (nonatomic) BOOL learningArmed;
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
        /*
         * 还没有可用的类名：这次退回微信原本的行为，同时进入"学习"状态。
         * 用户从发现页点进朋友圈时，把那个控制器类名记下来，下次就能直达。
         */
        [self armLearning];
        WQMLog(@"moments class unresolved, falling back to Discover page");
        [bridge openDiscoverPage];
        return;
    }

    [self presentMomentsController:controller];
}

- (void)presentMomentsController:(UIViewController *)controller {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    UITabBarController *host = bridge.tabBarController;
    if (!host || !host.view) return;

    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:controller];
    navigationController.view.frame = host.view.bounds;
    navigationController.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    navigationController.navigationBarHidden =
        [[WQMConfig wqm_shared] wqm_boolForKey:@"hideHostNavBar" defaultValue:YES];

    [host addChildViewController:navigationController];

    UITabBar *tabBar = bridge.tabBar;
    if (tabBar && tabBar.superview == host.view) {
        /* 盖住内容区但留在底栏下面，底栏保持可见、可点。 */
        [host.view insertSubview:navigationController.view belowSubview:tabBar];
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

    WQMLog(@"enter moments via %@", NSStringFromClass(controller.class));
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
    if (!viewController) return;

    if (self.showing) {
        BOOL isTimelineRoot = (viewController == self.momentsController) ||
            (self.hostNavigation && viewController == self.hostNavigation.viewControllers.firstObject);
        if (isTimelineRoot && !self.badgeClearedForSession) {
            self.badgeClearedForSession = YES;
            [[WQMBadgeCoordinator shared] momentsTimelineDidAppear:self.momentsController];
        }
        return;
    }

    /* 学习模式的第二条通路：有些版本用 present 而不是 push。 */
    if (self.learningArmed) {
        NSString *className = NSStringFromClass(viewController.class);
        if ([className containsString:@"Moment"] || [className containsString:@"Sns"]) {
            [self learnClassNamed:className source:@"appear"];
        }
    }
}

- (void)notePushedController:(UIViewController *)viewController
      navigationController:(UINavigationController *)navigationController {
    if (!self.learningArmed || !viewController || !navigationController) return;
    if (navigationController == self.hostNavigation) return;

    UIViewController *currentTop = navigationController.topViewController;
    if (![self looksLikeDiscoverPage:currentTop]) return;

    [self learnClassNamed:NSStringFromClass(viewController.class) source:@"push"];
}

- (BOOL)looksLikeDiscoverPage:(UIViewController *)viewController {
    if (!viewController) return NO;
    if ([viewController.title containsString:@"发现"]) return YES;
    NSString *className = NSStringFromClass(viewController.class);
    return [className containsString:@"Find"] || [className containsString:@"Discover"];
}

#pragma mark - 类名解析

- (void)armLearning {
    self.learningArmed = YES;
    WQMLog(@"learning armed: open 朋友圈 once from 发现页, class name will be cached");
}

- (void)learnClassNamed:(NSString *)className source:(NSString *)source {
    if (className.length == 0) return;
    self.learningArmed = NO;

    NSError *error = nil;
    if (wqm_writePreference(kKeyLearnedMomentsClass, className, &error)) {
        WQMLog(@"learned moments class %@ (via %@)", className, source);
    } else {
        WQMLog(@"failed to cache moments class: %@", error.localizedDescription);
    }
}

- (Class)resolvedMomentsClass {
    if (self.resolvedClass) return self.resolvedClass;

    WQMConfig *config = [WQMConfig wqm_shared];

    NSArray<NSString *> *configured = @[
        [config wqm_stringForKey:kKeyMomentsClass defaultValue:@""],
        [config wqm_stringForKey:kKeyLearnedMomentsClass defaultValue:@""]
    ];
    for (NSString *name in configured) {
        Class candidate = [self validClassNamed:name];
        if (candidate) {
            self.resolvedClass = candidate;
            return candidate;
        }
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *extra = [config wqm_stringForKey:kKeyExtraClasses defaultValue:@""];
    if (extra.length) {
        for (NSString *piece in [extra componentsSeparatedByString:@","]) {
            NSString *trimmed = [piece stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length) [names addObject:trimmed];
        }
    }
    /*
     * 内置候选只是提示，不同微信版本差异很大；
     * 真正可靠的是 learnedMomentsClass（运行时学到的那一个）。
     */
    [names addObjectsFromArray:@[
        @"WCMomentsTimelineViewController",
        @"MomentsTimelineViewController",
        @"WCMomentsViewController",
        @"WCNewMomentsViewController",
        @"MMMomentsViewController",
        @"SnsTimeLineViewController",
        @"MomentsViewController"
    ]];

    for (NSString *name in names) {
        Class candidate = [self validClassNamed:name];
        if (candidate) {
            WQMLog(@"using built-in candidate %@", name);
            self.resolvedClass = candidate;
            return candidate;
        }
    }
    return Nil;
}

- (Class)validClassNamed:(NSString *)name {
    if (name.length == 0) return Nil;
    Class candidate = NSClassFromString(name);
    if (!candidate) return Nil;
    if (![candidate isSubclassOfClass:[UIViewController class]]) return Nil;
    return candidate;
}

- (UIViewController *)instantiateMomentsController {
    Class controllerClass = [self resolvedMomentsClass];
    if (!controllerClass) return nil;

    UIViewController *controller = nil;
    @try {
        controller = [[controllerClass alloc] initWithNibName:nil bundle:nil];
    } @catch (NSException *exception) {
        WQMLog(@"initWithNibName failed: %@", exception.reason);
    }

    if (![controller isKindOfClass:[UIViewController class]]) {
        controller = nil;
        @try {
            controller = [[controllerClass alloc] init];
        } @catch (NSException *exception) {
            WQMLog(@"init failed: %@", exception.reason);
        }
    }

    if (![controller isKindOfClass:[UIViewController class]]) return nil;

    /* 触发一次 view 加载，避免首帧尺寸为 0 时布局错乱。 */
    (void)controller.view;
    return controller;
}

@end
