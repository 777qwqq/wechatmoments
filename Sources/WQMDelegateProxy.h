#pragma once

#import <Foundation/Foundation.h>

/*
 * 朋友圈 delegate 的中间人。
 *
 * 为什么要它：
 * 微信 8.0.80 的 timeline 在 cell 配置阶段会直接向 delegate 发协议方法，
 * 因此不能把 delegate 整个换成发现页（发现页没实现新方法 → 崩）。
 * 但红点的已读结算又确实需要发现页收到 onMarkWCObjectAsRead: 这类回调。
 *
 * 做法：delegate 指向本 proxy，其余方法原样转发给微信原本的 delegate，
 * 只有「已读 / 返回 / 红点」这几类选择器额外喂一份给发现页。
 */
@interface WQMDelegateProxy : NSProxy

@property (nonatomic, weak) id target;    /* 微信原本的 delegate，可能为 nil */
@property (nonatomic, weak) id observer;  /* 发现页 */

+ (instancetype)proxyWithTarget:(id)target observer:(id)observer;

@end
