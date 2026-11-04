#include "WQMBadgeMath.h"
#include <ctype.h>

int wqm_badge_parse_text(const char *text) {
    if (!text) return 0;
    while (*text && isspace((unsigned char)*text)) text++;
    if (*text == '\0') return 1;  /* 空串在 iOS 上是"小红点"，代表至少一条 */

    int value = 0;
    int digits = 0;
    while (*text >= '0' && *text <= '9') {
        value = value * 10 + (*text - '0');
        if (value > 9999) { value = 9999; break; }
        text++;
        digits++;
    }
    if (digits == 0) return 1;    /* "..." 之类的非数字标记 */
    return value;
}

int wqm_badge_total_after_moments_read(WQMBadgeInput input) {
    if (input.currentTotal <= 0) return 0;

    if (input.momentsUnread > 0) {
        int remaining = input.currentTotal - input.momentsUnread;
        return remaining > 0 ? remaining : 0;
    }

    if (input.momentsUnread == 0) {
        /* 本来就没有朋友圈未读，别动汇总点。 */
        return input.currentTotal;
    }

    /* 未知子项分解：保守策略，绝不整体清零。 */
    if (input.currentTotal == 1) {
        /* 只有一个未读时，它几乎必然来自朋友圈（本次进入的唯一触发源）。 */
        return 0;
    }
    return input.currentTotal - 1;
}

void wqm_badge_ledger_open(WQMBadgeLedger *ledger, int totalBefore, double now, double window) {
    if (!ledger) return;
    ledger->active = (totalBefore > 0) ? 1 : 0;
    ledger->clearedAt = now;
    ledger->window = (window > 0.0) ? window : 5.0;
    ledger->ceiling = totalBefore > 0 ? totalBefore : 0;
}

int wqm_badge_ledger_should_drop(WQMBadgeLedger *ledger, int incomingTotal, double now) {
    if (!ledger || !ledger->active) return 0;
    if (incomingTotal <= 0) return 0;

    if (now - ledger->clearedAt > ledger->window) {
        ledger->active = 0;
        return 0;
    }

    /* 比清除前的汇总还大，说明是新的聚合结果，必须放行。 */
    if (incomingTotal > ledger->ceiling) return 0;

    /*
     * 只有"和清除前一模一样"的那份汇总才是回灌的陈旧值。
     * 比它小的值是微信按剩余子项重算后的结果（比如 5 -> 3，视频号还有 3 条），
     * 必须放行，否则会连带把别的子项也标成已读。
     */
    if (incomingTotal < ledger->ceiling) return 0;

    ledger->clearedAt = now;
    return 1;
}
