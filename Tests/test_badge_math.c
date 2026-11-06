#include <stdio.h>
#include "../Sources/WQMBadgeMath.h"

static int g_pass = 0;
static int g_fail = 0;

static void check(const char *name, long actual, long expected) {
    if (actual == expected) {
        g_pass++;
    } else {
        g_fail++;
        printf("  FAIL  %-56s actual=%ld expected=%ld\n", name, actual, expected);
    }
}

int main(void) {
    printf("[badge] 解析\n");
    check("nil -> 0", wqm_badge_parse_text(NULL), 0);
    check("empty (dot) -> 1", wqm_badge_parse_text(""), 1);
    check("\"3\" -> 3", wqm_badge_parse_text("3"), 3);
    check("\"12\" -> 12", wqm_badge_parse_text("12"), 12);
    check("\"99+\" -> 99", wqm_badge_parse_text("99+"), 99);
    check("\" 2 \" -> 2", wqm_badge_parse_text(" 2 "), 2);
    check("\"abc\" -> 1", wqm_badge_parse_text("abc"), 1);
    check("\"0\" -> 0", wqm_badge_parse_text("0"), 0);
    check("overflow clamps to 9999", wqm_badge_parse_text("99999"), 9999);

    printf("[badge] 陈旧回灌拦截\n");
    WQMBadgeLedger ledger;
    wqm_badge_ledger_open(&ledger, 3, 0.0, 5.0);
    check("stale 3 at t=1 dropped", wqm_badge_ledger_should_drop(&ledger, 3, 1.0), 1);
    check("bigger 4 at t=1 allowed", wqm_badge_ledger_should_drop(&ledger, 4, 1.0), 0);
    check("smaller 2 at t=1 allowed (remaining sub-items)", wqm_badge_ledger_should_drop(&ledger, 2, 1.0), 0);
    check("zero always allowed", wqm_badge_ledger_should_drop(&ledger, 0, 1.0), 0);
    check("stale 3 at t=6.5 expired", wqm_badge_ledger_should_drop(&ledger, 3, 6.5), 0);
    check("ledger deactivated after expiry", ledger.active, 0);

    printf("[badge] 小圆点场景（ceiling=1）\n");
    WQMBadgeLedger dot;
    wqm_badge_ledger_open(&dot, 1, 0.0, 5.0);
    check("dot ledger active", dot.active, 1);
    check("stale 1 at t=1 dropped", wqm_badge_ledger_should_drop(&dot, 1, 1.0), 1);
    check("stale 1 at t=6.5 expired", wqm_badge_ledger_should_drop(&dot, 1, 6.5), 0);

    printf("[badge] 窗口不因命中而续期\n");
    WQMBadgeLedger repeated;
    wqm_badge_ledger_open(&repeated, 3, 0.0, 5.0);
    check("first hit dropped", wqm_badge_ledger_should_drop(&repeated, 3, 1.0), 1);
    check("second hit dropped", wqm_badge_ledger_should_drop(&repeated, 3, 2.0), 1);
    check("t=6.5 expired despite hits", wqm_badge_ledger_should_drop(&repeated, 3, 6.5), 0);

    WQMBadgeLedger empty;
    wqm_badge_ledger_open(&empty, 0, 0.0, 5.0);
    check("nothing to protect when total was 0", wqm_badge_ledger_should_drop(&empty, 2, 0.5), 0);

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
