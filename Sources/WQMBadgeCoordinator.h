#pragma once

#import <UIKit/UIKit.h>

/**
 * "发现" tab 红点。
 *
 * 底栏那一个点是子项汇总（朋友圈 / 视频号 / 直播 / 看一看…），
 * 所以这里绝不整体清零，只做三件事：
 *   1. 先尝试让微信自己把朋友圈标记为已读，并触发它自己的汇总重算；
 *   2. 拿不到子项信息时，按"只扣朋友圈那部分"保守扣减；
 *   3. 开一个短时窗口，拦住服务端/本地缓存把旧汇总重新刷回来。
 */
@interface WQMBadgeCoordinator : NSObject

+ (instancetype)shared;

/* 时间线首屏出现时调用（同一轮进入只调一次）。 */
- (void)momentsTimelineDidAppear:(UIViewController *)timelineController;

/* 由 UITabBarItem setBadgeValue: 的钩子调用，返回真正要写入的值。 */
- (NSString *)adjustedBadgeValue:(NSString *)value forItem:(UITabBarItem *)item;

@end
