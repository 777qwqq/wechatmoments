#include <stdio.h>
#include "../Sources/WQMPressMachine.h"

static int g_pass = 0;
static int g_fail = 0;

static void check(const char *name, long actual, long expected) {
    if (actual == expected) {
        g_pass++;
    } else {
        g_fail++;
        printf("  FAIL  %-52s actual=%ld expected=%ld\n", name, actual, expected);
    }
}

int main(void) {
    WQMPressMachine m;

    printf("[press] 单击\n");
    wqm_press_init(&m, 0.40);
    check("down inside slot", wqm_press_down(&m, 1, 0.000), WQMPressOutcomeNone);
    check("timer not yet elapsed", wqm_press_hold_elapsed(&m, 0.200), 0);
    check("up at 0.12s -> tap", wqm_press_up(&m, 0.120), WQMPressOutcomeTap);
    check("up twice does nothing", wqm_press_up(&m, 0.130), WQMPressOutcomeNone);

    printf("[press] 长按\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    check("armed at 0.41s", wqm_press_hold_elapsed(&m, 0.410), 1);
    check("armed only once", wqm_press_hold_elapsed(&m, 0.500), 0);
    check("up after arm -> long press", wqm_press_up(&m, 0.900), WQMPressOutcomeLongPress);

    printf("[press] 长按后拖走\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    wqm_press_hold_elapsed(&m, 0.410);
    check("drag out aborts", wqm_press_drag(&m, 0, 0.500), WQMPressOutcomeAbort);
    check("no action on up", wqm_press_up(&m, 0.600), WQMPressOutcomeNone);

    printf("[press] 定时器被主线程卡住\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    check("held 0.60s w/o timer -> long press", wqm_press_up(&m, 0.600), WQMPressOutcomeLongPress);

    printf("[press] 边界\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    check("exactly at threshold -> long press", wqm_press_up(&m, 0.400), WQMPressOutcomeLongPress);

    printf("[press] 非发现槽位\n");
    wqm_press_init(&m, 0.40);
    check("down outside -> abort", wqm_press_down(&m, 0, 0.000), WQMPressOutcomeAbort);
    check("no tap on up", wqm_press_up(&m, 0.100), WQMPressOutcomeNone);

    printf("[press] 单击过程中滑走\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    check("drag out aborts", wqm_press_drag(&m, 0, 0.100), WQMPressOutcomeAbort);
    check("no tap on up", wqm_press_up(&m, 0.150), WQMPressOutcomeNone);

    printf("[press] 多指\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    check("second finger aborts", wqm_press_down(&m, 1, 0.050), WQMPressOutcomeAbort);
    check("no action on up", wqm_press_up(&m, 0.100), WQMPressOutcomeNone);

    printf("[press] 系统取消\n");
    wqm_press_init(&m, 0.40);
    wqm_press_down(&m, 1, 0.000);
    check("cancel -> abort", wqm_press_cancel(&m), WQMPressOutcomeAbort);
    check("no action on up", wqm_press_up(&m, 0.100), WQMPressOutcomeNone);

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
