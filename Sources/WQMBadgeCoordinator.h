#pragma once

#import <UIKit/UIKit.h>

/**
 * "发现" tab 红点。
 *
 * 走微信原生链路：
 *   1. 进入朋友圈时把 timeline.delegate 接回发现页、置 m_inTimeline = YES，
 *      让朋友圈自己回调 onMarkWCObjectAsRead: 完成已读落库（冷启动不会再回来）；
 *   2. 我们只负责催一次发现页的 onTimeLineViewReturn，让它按剩余子项重算汇总，
 *      绝不动视频号 / 直播 / 看一看的未读；
 *   3. 开一个短时窗口，拦住服务端/本地缓存把旧汇总重新刷回来。
 */
@interface WQMBadgeCoordinator : NSObject

+ (instancetype)shared;

/* 时间线首屏出现时调用（同一轮进入只调一次）。 */
- (void)momentsTimelineDidAppear:(UIViewController *)timelineController;

/* 退出朋友圈前调用：给微信最后一次结算已读的机会。 */
- (void)momentsTimelineWillDisappear;

/* 由 UITabBarItem setBadgeValue: 的钩子调用，返回真正要写入的值。 */
- (NSString *)adjustedBadgeValue:(NSString *)value forItem:(UITabBarItem *)item;

/* 微信真实底栏走 MMTabBarController，按槽位过滤；返回 nil 表示丢弃这次写入。 */
- (NSString *)adjustedBadgeString:(id)value forIndex:(NSUInteger)index;
- (BOOL)shouldAcceptBadgeValue:(long long)value forIndex:(NSUInteger)index;

@end
