#pragma once

#import <UIKit/UIKit.h>

/**
 * 一次性的触摸盾。
 *
 * 长按判定成立到页面真正出现在屏幕上有一段动画时间。若此时手指仍未抬起，
 * 或用户紧接着又点了一下，触摸可能落到新页面九宫格的某一项上。
 * 这里在窗口上盖一层透明、可命中但不做任何事的视图，短时间内吞掉这些触摸。
 */
@interface WQMTouchShield : NSObject

+ (void)installForDuration:(NSTimeInterval)duration;

@end
