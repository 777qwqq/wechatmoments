#pragma once

/**
 * "发现" tab 红点的纯逻辑部分：badge 文本解析 + 陈旧汇总回灌的短时拦截。
 *
 * 数值结算一律交给微信自己的"朋友圈已读 + 汇总重算"，这里不替它算数字，
 * 只在清除后的短窗口内丢弃"和清除前一模一样"的旧汇总值；更小/更大的值都放行，
 * 避免把视频号、直播等其它子项的未读一起吃掉。
 */

#ifdef __cplusplus
extern "C" {
#endif

/* 解析 badgeValue：nil/空串（小红点）/非数字 都按"至少 1 条"处理。 */
int wqm_badge_parse_text(const char *text);

typedef struct {
    int active;
    double clearedAt;
    double window;
    int ceiling;   /* 清除前看到的汇总值 */
} WQMBadgeLedger;

/* 清理完成后打开窗口。纯小圆点没有计数，调用方传 totalBefore = 1 即可激活。 */
void wqm_badge_ledger_open(WQMBadgeLedger *ledger, int totalBefore, double now, double window);

/* 返回 1 表示这条 badge 更新属于陈旧回灌，应丢弃。 */
int wqm_badge_ledger_should_drop(WQMBadgeLedger *ledger, int incomingTotal, double now);

#ifdef __cplusplus
}
#endif
