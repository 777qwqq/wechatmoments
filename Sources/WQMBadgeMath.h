#pragma once

/**
 * "发现" tab 红点的纯逻辑部分。
 *
 * 前提：iOS 上 `UITabBarItem.badgeValue` 只有一整个 tab 的汇总值，读不到子项分解。
 * 因此这里的策略是：
 *   1) 优先走微信自己的"朋友圈已读 + 汇总重算"，让汇总点按"是否还有其他未读"自然收敛；
 *   2) 拿不到子项计数时，保守扣减（宁可少清，也不把视频号/直播的未读一起抹掉）；
 *   3) 用短时窗口拦住服务端回灌的陈旧汇总值。
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int currentTotal;   /* 当前 tab 汇总未读，>= 0 */
    int momentsUnread;  /* 朋友圈未读；未知时传 -1 */
} WQMBadgeInput;

/* 读过朋友圈之后，汇总点应该变成多少。 */
int wqm_badge_total_after_moments_read(WQMBadgeInput input);

/* 解析 badgeValue：nil/空串（小红点）/非数字 都按"至少 1 条"处理。 */
int wqm_badge_parse_text(const char *text);

typedef struct {
    int active;
    double clearedAt;
    double window;
    int ceiling;   /* 清除前看到的汇总值 */
} WQMBadgeLedger;

/* 清理完成后打开窗口，用于拦截"同一份旧汇总"被服务端/本地缓存重新刷回来。 */
void wqm_badge_ledger_open(WQMBadgeLedger *ledger, int totalBefore, double now, double window);

/* 返回 1 表示这条 badge 更新属于陈旧回灌，应丢弃。 */
int wqm_badge_ledger_should_drop(WQMBadgeLedger *ledger, int incomingTotal, double now);

#ifdef __cplusplus
}
#endif
