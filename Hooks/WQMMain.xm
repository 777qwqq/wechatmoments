#import <UIKit/UIKit.h>

#import "WQMBadgeCoordinator.h"
#import "WQMConfig.h"
#import "WQMLog.h"
#import "WQMMomentsRouter.h"
#import "WQMTabBarBridge.h"

/*
 * 只 Hook 通用类 + 两个可选的微信类，不依赖稳定性差的私有实现。
 */

/* 微信自己的底栏控制器；头文件确认它是 UITabBarController 子类。 */
@interface MMTabBarController : UITabBarController
@end

/* 微信自己的导航控制器，朋友圈内部可能用它退出。 */
@interface MMUINavigationController : UINavigationController
- (void)disMissSelf;
@end

/* 返回 YES 表示这次选中已被我们处理，调用方不要再执行 %orig。 */
static BOOL wqm_intercept_selection(NSUInteger index) {
    WQMTabBarBridge *bridge = [WQMTabBarBridge shared];
    [bridge refresh];
    [[WQMMomentsRouter shared] handleTabSwitchToIndex:index];
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

%hook MMTabBarController

/* 用户在朋友圈里点了别的底栏 tab：微信走这里，不走 setSelectedIndex:。 */
- (void)setTabBarItemSelectedIndex:(unsigned long long)index {
    if ([[WQMMomentsRouter shared] isShowing]) {
        [[WQMMomentsRouter shared] handleTabSwitchToIndex:(NSUInteger)index];
    }
    %orig;
}

/* 发现 tab 的红点是子项汇总，只拦"陈旧值回灌"，不改语义。 */
- (void)setTabBarBadgeString:(id)value forIndex:(unsigned long long)index {
    NSString *adjusted = [[WQMBadgeCoordinator shared] adjustedBadgeString:value
                                                                   forIndex:(NSUInteger)index];
    %orig(adjusted, index);
}

- (void)setTabBarBadgeValue:(unsigned long long)value forIndex:(unsigned long long)index {
    if (![[WQMBadgeCoordinator shared] shouldAcceptBadgeValue:(long long)value
                                                      forIndex:(NSUInteger)index]) {
        return;
    }
    %orig;
}

%end

%hook MMUINavigationController

- (void)disMissSelf {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    if ([router ownsNavigationController:self] && self.viewControllers.count <= 1) {
        [router exitAnimated:YES reason:@"dismiss-self"];
        return;
    }
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
        wqm_log_set_enabled([config wqm_boolForKey:@"verboseLog" defaultValue:YES]);
        WQMLog(@"loaded (enabled=%d), WCTimeLineViewController %@",
               [config wqm_isEnabled],
               NSClassFromString(@"WCTimeLineViewController") ? @"found" : @"MISSING");
    }
}
