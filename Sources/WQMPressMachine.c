#include "WQMPressMachine.h"

#define WQM_PRESS_DEFAULT_HOLD 0.40
#define WQM_PRESS_EPSILON 1e-9

void wqm_press_reset(WQMPressMachine *m) {
    if (!m) return;
    m->phase = WQMPressPhaseIdle;
    m->startedAt = 0.0;
    m->touchCount = 0;
}

void wqm_press_init(WQMPressMachine *m, double holdDelay) {
    if (!m) return;
    m->phase = WQMPressPhaseIdle;
    m->startedAt = 0.0;
    m->holdDelay = (holdDelay > 0.0) ? holdDelay : WQM_PRESS_DEFAULT_HOLD;
    m->touchCount = 0;
}

WQMPressOutcome wqm_press_down(WQMPressMachine *m, int insideSlot, double now) {
    if (!m) return WQMPressOutcomeAbort;

    /* 点在其它的 tab 上：本轮与插件无关，立刻失败，交给 UIKit 原生处理。 */
    if (!insideSlot) {
        wqm_press_reset(m);
        return WQMPressOutcomeAbort;
    }

    /* 第二根手指落下：不再猜用户意图。 */
    if (m->phase == WQMPressPhasePending || m->phase == WQMPressPhaseHeld) {
        wqm_press_reset(m);
        return WQMPressOutcomeAbort;
    }

    m->phase = WQMPressPhasePending;
    m->startedAt = now;
    m->touchCount = 1;
    return WQMPressOutcomeNone;
}

int wqm_press_hold_elapsed(WQMPressMachine *m, double now) {
    if (!m || m->phase != WQMPressPhasePending) return 0;
    if (now - m->startedAt + WQM_PRESS_EPSILON < m->holdDelay) return 0;
    m->phase = WQMPressPhaseHeld;
    return 1;
}

WQMPressOutcome wqm_press_drag(WQMPressMachine *m, int insideSlop, double now) {
    (void)now;
    if (!m) return WQMPressOutcomeNone;
    if (insideSlop) return WQMPressOutcomeNone;

    if (m->phase == WQMPressPhasePending || m->phase == WQMPressPhaseHeld) {
        wqm_press_reset(m);
        return WQMPressOutcomeAbort;
    }
    return WQMPressOutcomeNone;
}

WQMPressOutcome wqm_press_up(WQMPressMachine *m, double now) {
    if (!m) return WQMPressOutcomeNone;

    WQMPressOutcome outcome = WQMPressOutcomeNone;
    if (m->phase == WQMPressPhasePending) {
        /* 定时器可能被主线程卡住，以真实按住时长兜底，避免把长按误判成单击。 */
        if (now - m->startedAt + WQM_PRESS_EPSILON >= m->holdDelay) {
            outcome = WQMPressOutcomeLongPress;
        } else {
            outcome = WQMPressOutcomeTap;
        }
    } else if (m->phase == WQMPressPhaseHeld) {
        outcome = WQMPressOutcomeLongPress;
    }

    m->phase = (m->phase == WQMPressPhaseIdle) ? WQMPressPhaseIdle : WQMPressPhaseDone;
    return outcome;
}

WQMPressOutcome wqm_press_cancel(WQMPressMachine *m) {
    if (!m) return WQMPressOutcomeNone;
    WQMPressPhase previous = m->phase;
    wqm_press_reset(m);
    return (previous == WQMPressPhaseIdle) ? WQMPressOutcomeNone : WQMPressOutcomeAbort;
}
