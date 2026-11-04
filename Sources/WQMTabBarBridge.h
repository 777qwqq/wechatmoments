#pragma once

#import <UIKit/UIKit.h>

/**
 * 底栏定位与外观代理。
 *
 * 微信的底栏可能是 UITabBar 的子类，也可能只保留 items/selectedItem 这套接口，
 * 所以这里不绑定具体类名：先按 isKindOfClass 找，再按"类名含 TabBar 且响应 items"兜底，
 * 都找不到就整个功能静默关闭，绝不影响微信本身。
 */
@interface WQMTabBarBridge : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, weak) UITabBar *tabBar;
@property (nonatomic, readonly, weak) UITabBarController *tabBarController;
@property (nonatomic, readonly, weak) UITabBarItem *discoverItem;
@property (nonatomic, readonly) NSUInteger discoverIndex;
@property (nonatomic, readonly) NSUInteger messageIndex;
@property (nonatomic, readonly) BOOL forcingHighlight;
@property (nonatomic, readonly) BOOL allowsDiscoverSelection;

- (void)refresh;
- (void)installRecognizerIfNeeded;
- (void)layoutDidChange;
- (BOOL)pointIsInDiscoverSlot:(CGPoint)point;

/* 长按路径：走微信原本的"选中发现 tab"，行为与改动前一致。 */
- (void)openDiscoverPage;

/* 进入朋友圈期间把底栏高亮钉在"发现"上，返回时立刻还原。 */
- (void)forceDiscoverHighlight:(BOOL)on;

/*
 * 安全网：若识别器没能吞掉 UP，微信自己把"发现"选中了，
 * 用这个标记在 setSelectedIndex: 里认领这次误选，改走朋友圈。
 */
- (void)markTapForRedemption;
- (BOOL)consumeTapRedemption;

@end
