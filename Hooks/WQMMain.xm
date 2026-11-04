#import <UIKit/UIKit.h>

#import "WQMBadgeCoordinator.h"
#import "WQMConfig.h"
#import "WQMLog.h"
#import "WQMMomentsRouter.h"
#import "WQMTabBarBridge.h"

/*
 * 只 Hook 通用类，不依赖微信的私有类名，避免随版本失效后把整个 App 带崩。
 */

/* 返回 YES 表示这次选中已被我们改写成"直接进朋友圈"，调用方不要再执行 %orig。 */
static BOOL wqm_intercept_selection(NSUInteger index) {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];

    WQMMomentsRouter *router = [WQMMomentsRouter shared];

    /*
     * 安全网：识别器理论上已经吞掉了 UP；万一微信还是把"发现"选中了，
     * 这里认领这次误选并改走朋友圈，用户不会看到发现页闪一下。
     */
    if (index == bridge.discoverIndex &&
        !bridge.allowsDiscoverSelection &&
        !router.isShowing &&
        [bridge consumeTapRedemption]) {
        [router handleDiscoverTap];
        return YES;
    }

    [router handleTabSwitchToIndex:index];
    return NO;
}

%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    [[WQMTabBarBridge shared] refresh];
    [[WQMTabBarBridge shared] installRecognizerIfNeeded];
}

- (void)layoutSubviews {
    %orig;
    [[WQMTabBarBridge shared] layoutDidChange];
}

%end

%hook UITabBarController

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    if (wqm_intercept_selection(selectedIndex)) return;
    %orig;
}

- (void)setSelectedViewController:(UIViewController *)selectedViewController {
    NSUInteger index = [self.viewControllers indexOfObject:selectedViewController];
    if (index != NSNotFound && wqm_intercept_selection(index)) return;
    %orig;
}

%end

%hook UITabBarItem

- (void)setBadgeValue:(NSString *)badgeValue {
    if (![[WQMConfig wqm_shared] wqm_isEnabled]) {
        %orig;
        return;
    }
    NSString *adjusted = [[WQMBadgeCoordinator shared] adjustedBadgeValue:badgeValue forItem:self];
    %orig(adjusted);
}

%end

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    [[WQMMomentsRouter shared] notePushedController:viewController navigationController:self];
    %orig;
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    /* 只有退到时间线首屏（栈里只剩它自己）才跳出到消息主页，二级页面照常逐级返回。 */
    if ([router ownsNavigationController:self] && self.viewControllers.count <= 1) {
        [router exitAnimated:animated reason:@"pop-timeline-root"];
        return nil;
    }
    return %orig;
}

- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    if ([router ownsNavigationController:self] && self.viewControllers.count <= 1) {
        [router exitAnimated:animated reason:@"pop-to-root"];
        return @[];
    }
    return %orig;
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[WQMMomentsRouter shared] noteViewControllerAppeared:self];
}

- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    if (router.isShowing && router.isAtTimelineRoot && [router ownsViewController:self]) {
        [router exitAnimated:flag reason:@"dismiss"];
        if (completion) completion();
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        WQMConfig *config = [WQMConfig wqm_shared];
        wqm_log_set_enabled([config wqm_boolForKey:@"verboseLog" defaultValue:NO]);
        WQMLog(@"loaded (enabled=%d)", [config wqm_isEnabled]);
    }
}
