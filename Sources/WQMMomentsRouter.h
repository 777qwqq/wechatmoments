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
 * 因为朋友圈挂在 tab 容器上而不是任何一个 tab 的导航栈里，"返回"天然只会退出这一层，
 * 落到用户原来的消息主页；而时间线内部的二级页面仍然由 UINavigationController 逐级 pop。
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
- (void)notePushedController:(UIViewController *)viewController
      navigationController:(UINavigationController *)navigationController;
- (void)handleTabSwitchToIndex:(NSUInteger)index;

/* 微信改动了导航栏可见性之后重新确认一次返回项。 */
- (void)refreshChrome;

@end
