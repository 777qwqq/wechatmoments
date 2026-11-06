#pragma once

#import <UIKit/UIKit.h>

/**
 * 底栏定位与外观代理。
 *
 * 微信 8.0.5x 的底栏是 MMTabBar : UITabBar，但高亮并不是由 selectedItem 驱动的，
 * 而是每个 MMTabBarItemView 自己的 isSelected。切换 tab 也不走 setSelectedIndex:，
 * 走 MMTabBarController 的 setTabBarItemSelectedIndex:，点击则由它自带的
 * singleTapGesture 处理。
 *
 * 所以这里做三件事：
 *   1. 定位底栏与"发现"槽位（优先按 FindFriendEntryViewController 类名，其次标题）；
 *   2. 钉高亮时直接改 MMTabBarItemView.isSelected，不碰 selectedItem / selectedIndex；
 *   3. 让我们自己的识别器成为微信 singleTapGesture 的前置失败条件，
 *      避免"进朋友圈"和"切发现页"同时发生。
 */
@interface WQMTabBarBridge : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, weak) UITabBar *tabBar;
@property (nonatomic, readonly, weak) UITabBarController *tabBarController;
@property (nonatomic, readonly, weak) UITabBarItem *discoverItem;
@property (nonatomic, readonly) NSUInteger discoverIndex;
@property (nonatomic, readonly) NSUInteger messageIndex;
@property (nonatomic, readonly) BOOL forcingHighlight;

- (void)refresh;
/*
 * 底栏视图刚挂到窗口时用它：强制重新择优一次，避免冷启动早期绑到临时/内嵌实例后
 * "绑上就不重扫"，导致后续恢复显隐时作用到错误对象。
 */
- (void)refreshForcingRescan;
- (void)installRecognizerIfNeeded;
- (void)layoutDidChange;
- (BOOL)pointIsInDiscoverSlot:(CGPoint)point;

/* 发现页控制器（FindFriendEntryViewController），用于取朋友圈实例 / 判断槽位。 */
- (UIViewController *)discoverController;

/* 长按路径：走微信原本的"选中发现 tab"，行为与改动前一致。 */
- (void)openDiscoverPage;

/* 以微信自己的方式切换 tab（会同步 MMTabBarItemView）。 */
- (void)selectTabAtIndex:(NSUInteger)index;

/* 进入朋友圈期间把底栏高亮钉在"发现"上，返回时立刻还原。 */
- (void)forceDiscoverHighlight:(BOOL)on;

/* 原生朋友圈是整屏的：进页面把底栏整条收起来，退出再放回来。 */
- (void)setTabBarHidden:(BOOL)hidden;
@property (nonatomic, readonly) BOOL tabBarHidden;

/*
 * 发现 tab 的红点状态。
 *
 * 微信的 tab 红点平时是个没有数字的小圆点（badgeString 为空、unreadCount 保留），
 * 所以只读 badgeValue / badgeString 会误判成"本来就没红点"——
 * 这也是之前清红点"看起来什么都没发生"的原因。
 */
- (UIView *)discoverItemView;
- (BOOL)discoverBadgeVisible;
- (long long)discoverUnreadCount;

@end
