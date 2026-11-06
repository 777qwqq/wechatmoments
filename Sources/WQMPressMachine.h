#pragma once

#include <stddef.h>

/**
 * 单击 / 长按 仲裁状态机（与 UIKit 无关，便于在宿主机上跑真值表测试）。
 *
 * 生命周期：
 *   down -> (hold_elapsed 成立) -> 调用方立即触发长按导航，本轮结束
 *        \-> up（未到阈值）      -> tap
 *        \-> drag(out of slop) / 多指 / 系统取消 -> abort
 *
 * 语义约定：
 *   - down 落在"发现"槽位之外时立刻 abort，识别器直接 fail，其它 tab 行为完全不变；
 *   - hold_elapsed 返回 1 表示长按已成立，识别器立刻转 Ended 并跳转，不等抬手
 *     （这次触摸在 touchesBegan 时已落给底栏，UIKit 不会对进行中的触摸重新 hit-test）；
 *   - up 是定时器被主线程卡住时的兜底：此时 phase 仍是 Pending，按真实按住时长判定；
 *   - Held -> LongPress 分支只为纯函数完整性保留，正常路径不会走到（识别器已提前消费本轮）。
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    WQMPressPhaseIdle = 0,
    WQMPressPhasePending,   /* 手指按下，等待判定 */
    WQMPressPhaseHeld,      /* 长按已成立；识别器立即触发导航，保留供 up 兜底 */
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
} WQMPressMachine;

void wqm_press_init(WQMPressMachine *machine, double holdDelay);

/* 手指按下；insideSlot 表示触点是否落在"发现"槽位内。 */
WQMPressOutcome wqm_press_down(WQMPressMachine *machine, int insideSlot, double now);

/* 定时器到期时调用；返回 1 表示长按成立，调用方应立即触发导航。 */
int wqm_press_hold_elapsed(WQMPressMachine *machine, double now);

/* 手指移动；insideSlop 为 0 时放弃整轮手势。 */
WQMPressOutcome wqm_press_drag(WQMPressMachine *machine, int insideSlop, double now);

/* 手指抬起：产出 Tap / LongPress（定时器未跑时的兜底路径）。 */
WQMPressOutcome wqm_press_up(WQMPressMachine *machine, double now);

/* 系统取消（来电、手势竞争失败等）。 */
WQMPressOutcome wqm_press_cancel(WQMPressMachine *machine);

void wqm_press_reset(WQMPressMachine *machine);

#ifdef __cplusplus
}
#endif
