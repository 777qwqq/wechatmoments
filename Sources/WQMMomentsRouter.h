#pragma once

#import <UIKit/UIKit.h>

/**
 * 朋友圈的"定向进入 + 定向退出"。
 *
 * 栈结构（不经过发现页）：
 *     UITabBarController
 *       ├─ 消息/通讯录/... 各 tab 原样不动，selectedIndex 始终没被改过
 *       └─ WQMMomentsHost(UINavigationController)  ← 只在这一层里压栈
 *             └─ 朋友圈时间线 → 详情/图片/评论 ...
 *
 * 因为朋友圈挂在 tab 容器上而不是任何一个 tab 的导航栈里，"返回"天然只会退出这一层；
 * 退出时统一把 selectedIndex 归到「微信」消息主页，时间线内部的二级页面照常逐级 pop。
 */
@interface WQMMomentsRouter : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isShowing) BOOL showing;
/* 栈里只剩时间线首屏本身（没有二级页面）。 */
@property (nonatomic, readonly, getter=isAtTimelineRoot) BOOL atTimelineRoot;

- (void)handleDiscoverTap;
- (void)exitAnimated:(BOOL)animated reason:(NSString *)reason;

- (BOOL)ownsNavigationController:(UINavigationController *)navigationController;
- (BOOL)ownsViewController:(UIViewController *)viewController;

- (void)noteViewControllerAppeared:(UIViewController *)viewController;
- (void)handleTabSwitchToIndex:(NSUInteger)index;

/* 微信改动了导航栏可见性之后重新确认一次返回项。 */
- (void)refreshChrome;

/*
 * 朋友圈那一层此刻是否真的盖在屏幕上。
 * 底栏该不该继续隐藏只认这个，不认一个可能残留的布尔标志：
 * 上次会话若在朋友圈里被切后台/被杀，标志会留成 YES，
 * 冷启动重建出来的新底栏就会在第一帧被误藏。
 */
- (BOOL)momentsOverlayShouldHideTabBar;

/* 朋友圈自己发出的"要返回了"信号（它顶栏按钮会先走这里）。 */
- (void)handleNativeReturnSignal;

@end
