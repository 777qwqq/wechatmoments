#pragma once

#import <UIKit/UIKit.h>
#import "WQMPressMachine.h"

/**
 * 挂在底栏上的"单击 / 长按"仲裁识别器。
 *
 * 关键行为：
 *   - 只有触点落在"发现"槽位内才参与竞争，其余位置立刻 fail，其它 tab 完全不受影响；
 *   - delaysTouchesEnded = YES：把底栏自己的 touchesEnded 扣下来，
 *     等本识别器出结论后再决定是"取消给底栏"还是"还给它"；
 *   - 判定长按后立刻进入 Ended 并回调（不等抬手）：这次触摸在 touchesBegan 时
 *     就已经落给底栏，UIKit 不会对进行中的触摸重新 hit-test，
 *     所以抬手位置就算压在发现页九宫格的某一项上也不会误触；
 *   - 单击在抬手瞬间转 Began -> Ended，底栏收到的是 touchesCancelled，不会自己切 tab。
 */
@interface WQMDiscoverPressRecognizer : UIGestureRecognizer

@property (nonatomic) NSTimeInterval holdDelay;
@property (nonatomic, copy) BOOL (^isInDiscoverSlot)(CGPoint pointInView);
@property (nonatomic, copy) void (^onArmed)(void);
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);

- (void)cancelCurrentGesture;

@end
