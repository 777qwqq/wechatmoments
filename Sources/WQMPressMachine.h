#pragma once

#include <stddef.h>

/**
 * 单击 / 长按 仲裁状态机（与 UIKit 无关，便于在宿主机上跑真值表测试）。
 *
 * 生命周期：
 *   down -> (hold_elapsed) -> up
 *            \-> drag(out of slop) -> abort
 *
 * 语义约定：
 *   - down 落在"发现"槽位之外时立刻 abort，识别器直接 fail，其它 tab 行为完全不变；
 *   - hold_elapsed 只表示"长按已成立/已上膛"，用于给触感反馈，**不触发导航**；
 *   - up 才产出最终结论，这样导航发生时手指已经抬起，九宫格的 cell 不可能接管这次 UP；
 *   - up 时若时钟已越过阈值但定时器被主线程卡住没跑，仍判定为长按（以真实按住时长为准）。
 */

typedef enum {
    WQMPressPhaseIdle = 0,
    WQMPressPhasePending,   /* 手指按下，等待判定 */
    WQMPressPhaseHeld,      /* 已判定长按并吞掉视图的触摸，等待抬手 */
    WQMPressPhaseDone       /* 本次手势已消费 */
} WQMPressPhase;

typedef enum {
    WQMPressOutcomeNone = 0,
    WQMPressOutcomeTap,        /* 单击：跳朋友圈 */
    WQMPressOutcomeLongPress,  /* 长按：打开原发现页 */
    WQMPressOutcomeAbort       /* 放弃：把这次触摸还给系统 */
} WQMPressOutcome;

typedef struct {
    WQMPressPhase phase;
    double startedAt;
    double holdDelay;
    int touchCount;
} WQMPressMachine;

void wqm_press_init(WQMPressMachine *machine, double holdDelay);

/* 手指按下；insideSlot 表示触点是否落在"发现"槽位内。 */
WQMPressOutcome wqm_press_down(WQMPressMachine *machine, int insideSlot, double now);

/* 定时器到期时调用；返回 1 表示"本轮刚上膛"，只用于触感反馈。 */
int wqm_press_hold_elapsed(WQMPressMachine *machine, double now);

/* 手指移动；insideSlop 为 0 时放弃整轮手势。 */
WQMPressOutcome wqm_press_drag(WQMPressMachine *machine, int insideSlop, double now);

/* 手指抬起：产出 Tap / LongPress。 */
WQMPressOutcome wqm_press_up(WQMPressMachine *machine, double now);

/* 系统取消（来电、手势竞争失败等）。 */
WQMPressOutcome wqm_press_cancel(WQMPressMachine *machine);

void wqm_press_reset(WQMPressMachine *machine);
