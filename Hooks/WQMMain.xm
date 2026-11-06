#import <UIKit/UIKit.h>

#import "WQMBadgeCoordinator.h"
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
- (id)popViewControllerAnimated:(BOOL)animated;
- (id)DispatchPopViewControllerAnimated:(BOOL)animated;
@end

/* 只做通知，不改选中结果：朋友圈显示期间点了别的 tab 就先收起这一层。 */
static void wqm_notify_selection(NSUInteger index) {
    [[WQMMomentsRouter shared] handleTabSwitchToIndex:index];
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
    wqm_notify_selection(selectedIndex);
    %orig;
}

- (void)setSelectedViewController:(UIViewController *)selectedViewController {
    NSUInteger index = [self.viewControllers indexOfObject:selectedViewController];
    if (index != NSNotFound) wqm_notify_selection(index);
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
    /* 微信主动清除（value 为 nil）要放行；被 ledger 判定为陈旧的写入才丢弃。 */
    if (!value) {
        %orig;
        return;
    }
    NSString *adjusted = [[WQMBadgeCoordinator shared] adjustedBadgeString:value
                                                                   forIndex:(NSUInteger)index];
    if (!adjusted) return;
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

/*
 * 关键：MMUINavigationController **自己实现了** popViewControllerAnimated:，
 * 所以 %hook UINavigationController 的那份对朋友圈完全无效 ——
 * 朋友圈顶栏自带的返回箭头调的就是这里，之前点了没反应就是这个原因。
 * 栈里只剩时间线时把这次 pop 转成"退出朋友圈"。
 */
- (id)popViewControllerAnimated:(BOOL)animated {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    if ([router ownsNavigationController:self] && self.viewControllers.count <= 1) {
        [router exitAnimated:animated reason:@"pop-timeline-root(wechat)"];
        return nil;
    }
    return %orig;
}

- (id)DispatchPopViewControllerAnimated:(BOOL)animated {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    if ([router ownsNavigationController:self] && self.viewControllers.count <= 1) {
        [router exitAnimated:animated reason:@"dispatch-pop-timeline-root"];
        return nil;
    }
    return %orig;
}

/* 朋友圈常用这一手把自己的导航栏藏掉：藏了之后 navigationItem 就没人画了。 */
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    if (![router ownsNavigationController:self]) return;
    WQMLog(@"wechat setNavigationBarHidden:%d", hidden);
    [router refreshChrome];
}

%end

/*
 * 朋友圈顶栏那颗返回按钮，点下去走的是它自己的 onTimeLineViewReturn：
 * 原生场景下它靠"发现页那条导航栈"来 pop，我们挂在独立导航栈上就 pop 不到东西。
 * 这里补一条通道，让它的返回信号直接落到我们的退出逻辑。
 */
@interface WCTimeLineViewController : UIViewController
- (void)onTimeLineViewReturn;
@end

%hook WCTimeLineViewController

- (void)onTimeLineViewReturn {
    WQMMomentsRouter *router = [WQMMomentsRouter shared];
    WQMLog(@"timeline -onTimeLineViewReturn (showing=%d atRoot=%d)",
           router.isShowing, router.isAtTimelineRoot);
    %orig;
    if ([router ownsViewController:self]) {
        [router handleNativeReturnSignal];
    }
}

%end

%hook UITabBarItem

- (void)setBadgeValue:(NSString *)badgeValue {
    /* nil 是微信自己清红点，放行；非 nil 但被 ledger 丢弃的才是陈旧回灌。 */
    if (!badgeValue) {
        %orig;
        return;
    }
    NSString *adjusted = [[WQMBadgeCoordinator shared] adjustedBadgeValue:badgeValue forItem:self];
    if (!adjusted) return;
    %orig(adjusted);
}

%end

%hook UINavigationController

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
        return nil;
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
