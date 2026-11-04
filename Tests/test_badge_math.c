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

static int after(int total, int moments) {
    WQMBadgeInput in = { total, moments };
    return wqm_badge_total_after_moments_read(in);
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

    printf("[badge] 只扣朋友圈那部分\n");
    check("5 unread, 2 from moments -> 3", after(5, 2), 3);
    check("2 unread, 2 from moments -> 0", after(2, 2), 0);
    check("2 unread, 5 from moments -> 0 (clamp)", after(2, 5), 0);
    check("5 unread, moments=0 -> untouched", after(5, 0), 5);
    check("5 unread, moments unknown -> 4", after(5, -1), 4);
    check("1 unread, moments unknown -> 0", after(1, -1), 0);
    check("0 unread -> 0", after(0, 3), 0);

    printf("[badge] 陈旧回灌拦截\n");
    WQMBadgeLedger ledger;
    wqm_badge_ledger_open(&ledger, 3, 0.0, 5.0);
    check("stale 3 at t=1 dropped", wqm_badge_ledger_should_drop(&ledger, 3, 1.0), 1);
    check("bigger 4 at t=1 allowed", wqm_badge_ledger_should_drop(&ledger, 4, 1.0), 0);
    check("zero always allowed", wqm_badge_ledger_should_drop(&ledger, 0, 1.0), 0);
    check("stale 3 at t=6.5 expired", wqm_badge_ledger_should_drop(&ledger, 3, 6.5), 0);
    check("ledger deactivated after expiry", ledger.active, 0);

    WQMBadgeLedger empty;
    wqm_badge_ledger_open(&empty, 0, 0.0, 5.0);
    check("nothing to protect when total was 0", wqm_badge_ledger_should_drop(&empty, 2, 0.5), 0);

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
