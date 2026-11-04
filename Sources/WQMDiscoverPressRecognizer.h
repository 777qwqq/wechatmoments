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
 *   - 判定长按后立刻进入 Began（视图收到 touchesCancelled，底栏不会选中"发现"），
 *     但真正的导航推迟到抬手，避免手指抬起时落到发现页九宫格的某一项上；
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
