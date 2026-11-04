# 微信朋友圈入口 · WeChatMoments

把底栏「发现」从一个**入口页**改造成**朋友圈的快捷入口**：单击直达时间线，长按才进原来的九宫格，
返回时绕过发现页直接落回消息主页。

- 包标识：`cn.qwq.wechatmoments`
- 作用进程：`com.tencent.xin`（主 App，不含扩展）
- 环境：iOS 15+ / 越狱（rootless、rootful、roothide 均可）

## 交互契约

| 操作 | 结果 |
| --- | --- |
| 单击「发现」 | 直接打开朋友圈时间线首屏，**不经过**发现页 |
| 长按「发现」 | 打开原发现页（九宫格），行为与改动前完全一致 |
| 从朋友圈返回 | 落到「微信」消息主页，底栏高亮回到「微信」 |
| 单击发生时 | 清除「发现」tab 上的红点（只清朋友圈那部分） |
| 朋友圈二级页面返回 | 逐级正常返回，只有退到时间线首屏再返回才跳出 |

## 三个技术要点是怎么落地的

### 1. 手势互斥：同一根手指，两条路径

单击和长按共用一个 `UIGestureRecognizer`，判定逻辑抽成了一个**与 UIKit 无关的纯 C 状态机**
（`Sources/WQMPressMachine.c`），因此可以脱离真机跑真值表测试。

```
down ──► pending ──(计时到)──► held ──(抬手)──► long press
            │
            └──(抬手，未超时)──► tap
            └──(移出 slop / 多指 / 系统取消)──► abort
```

除了状态机本身，真正决定"会不会误触"的是三件 UIKit 侧的事：

- **`delaysTouchesEnded = YES`**：把底栏自己的 `touchesEnded` 扣住。抬手瞬间本识别器先转 `Began`
  再转 `Ended`，底栏收到的是 `touchesCancelled` 而不是 `touchesEnded` —— 这就是"吞掉 UP"。
- **长按成立时先不导航**：计时到点只进入 `Began`（视图的触摸被取消）+ 一次触感反馈，
  真正的跳转推迟到**手指抬起**。这样页面出现时手指已经离开屏幕，
  抬起位置即使正好落在九宫格某一项上也不会被接管。
- **`WQMTouchShield`**：页面切换动画期间的兜底。在窗口上盖 0.25–0.3s 的透明视图，
  吞掉残留触摸（例如长按后立刻又补了一下）。

只有触点落在「发现」槽位内识别器才参与竞争，其它槽位在 `touchesBegan` 里直接 `Failed`，
「微信 / 通讯录 / 我」的手感不受任何影响。

**还要处理微信自己的那个 tap。** 底栏点击并不是系统的 `setSelectedIndex:`，
而是 `MMTabBarController` 自带的 `singleTapGesture` + `setTabBarItemSelectedIndex:`。
两个手势默认互不排斥：我们识别成功的同一帧，微信也会把 tab 切到「发现」。
结果就是"朋友圈进去了，但返回落在发现页"。

所以安装识别器时会建立一条失败依赖：

```objc
[singleTapGesture requireGestureRecognizerToFail:ourRecognizer];
```

我们成功 → 微信的 tap 必然失败 → 不会切 tab；我们失败（点到别的槽位）→ 微信照常处理。

### 2. 红点：只清朋友圈，汇总点自己重算

底栏那个点是**子项汇总**（朋友圈 / 视频号 / 直播 / 看一看…）。整体置 `nil` 等于把别人的未读也标记成已读，
这是本插件明确要避免的行为。所以采用三级策略：

> 先要认清一件事：微信底栏的「发现」红点绝大多数时候是**没有数字的小圆点**。
> `badgeString` 和 `badgeValue` 都是空的，但 `MMTabBarItemView.badgeView` 显示着。
> 只读前两个字段，会得出"本来就没红点"的结论——这正是早期版本"点了没反应"的直接原因。
> 现在按 `unreadCount > 0 || badgeString.length || badgeView 可见` 三者取或来判断。

1. **让微信自己算**（首选）：调用发现页的 `onTimeLineViewReturn`——这是微信"从朋友圈返回"的官方回调，
   它会清掉朋友圈这一项、再按剩余子项重算汇总。这样视频号、直播的未读一条都不会丢。
2. **只关朋友圈那一个开关**（微信没走通时）：发现页把朋友圈红点记在 `isShowingMomentsRedDot`
   和 `m_timelineRedDotView` 上，只清这两个，再用 `noteTabBarBadge:andTotalCount:` / `updateTabBarBadge`
   请微信重算汇总，其它子项一概不碰。
3. **显示层清除**（前两级都没动静时）：
   - 带数字的红点 → 用 `WQMBadgeMath` 保守扣减，只减朋友圈那部分，拿不到数量时**最多减 1**；
   - 纯小圆点 → 调 `MMTabBarController.removeRedDotOnTabBarItemAtIndex:`，配合
     `MMTabBarItemView.removeSmallRedDot` / `setBadgeViewHidden:`。没有数量可分，就没有"误减别人"的问题。
4. **拦截回灌**（`WQMBadgeLedger`）：本地清完之后，服务端同步或本地缓存可能把同一份旧汇总刷回来。
   清除时开一个 5s 窗口（`badgeWindow` 可调），窗口内**只有和清除前一模一样**的汇总被丢弃；
   更小的值（微信按剩余子项重算的结果，比如 5→3）和更大的值都放行——否则会连带把别人的未读也吃掉。
5. **重试**：朋友圈的"已读上报"是网络请求，落库有延迟。清除失败会在 1.2s 后再来一轮，最多 3 轮，
   一读到"没有红点"就立刻停。

数值全部走纯函数，`Tests/test_badge_math.c` 覆盖了解析、扣减、窗口过期的真值表。

### 3. 返回栈：不压发现页，也不 hook 返回键

```
UITabBarController
  ├─ 消息 / 通讯录 / 我      ← selectedIndex 从头到尾没被改过
  └─ WQMMomentsHost (UINavigationController)   ← 朋友圈只活在这一层
        └─ 时间线 → 详情 / 图片 / 评论 …
```

朋友圈没有进任何一个 tab 的导航栈，而是作为 tab 容器的 child **铺满整个容器**（原生朋友圈没有底栏）：

- 进页面时把底栏整条收起（`hidden + alpha 0 + 关掉交互`），退出时还原，中间不会露出 tab 内容；
- 出去时不存在"发现页"这个东西，所以返回天然落在用户原来的 tab 上，再统一切回消息主页；
- 不需要 hook 返回键，也不会和微信自己的返回逻辑打架；
- 时间线内部仍然是一个正常的 `UINavigationController`，二级页面照常 `push/pop`。

只有一种情况需要拦截：**栈里只剩时间线自己时的 `pop`**。
`popViewControllerAnimated:` / `popToRootViewControllerAnimated:` / `dismissViewControllerAnimated:` 三个入口
都做了 `viewControllers.count <= 1` 判断，二级页面的返回完全不经过这段逻辑。

**返回入口**：原生朋友圈靠导航栏左上角的返回箭头。宿主导航栏默认为**透明**（封面图透到状态栏下面），
我们在时间线的 `navigationItem` 上补一个白色返回箭头；栈里只有一层时系统侧滑是禁用的，
所以另外挂了一条左缘 `UIScreenEdgePanGestureRecognizer` 兜底。二级页面走系统自己的返回，不吃这条逻辑。

**底栏选中态**：因为整条底栏在朋友圈期间是隐藏的，不再需要"钉高亮"。
退出时只做一件事——把 `selectedIndex` 归到「微信」，底栏重新出现时就是消息主页。

## 目录结构

```
Hooks/WQMMain.xm                    通用类 + MMTabBarController / MMUINavigationController 的钩子
Sources/WQMPressMachine.{h,c}       单击/长按 状态机（纯 C，可测）
Sources/WQMBadgeMath.{h,c}          红点扣减与回灌窗口（纯 C，可测）
Sources/WQMDiscoverPressRecognizer  把状态机接到 UIKit 的识别器
Sources/WQMTabBarBridge             底栏/发现槽位定位、MMTabBarItemView 高亮、识别器与 tap 依赖
Sources/WQMMomentsRouter            朋友圈的定向进入/退出、类名解析
Sources/WQMBadgeCoordinator         红点三级策略
Sources/WQMTouchShield              切换动画期间的触摸兜底
Sources/WQMConfig / WQMPreferences  配置快照与唯一写入入口
Tests/                              纯逻辑单元测试
```

## 编译

```bash
export THEOS=/opt/theos
sh build.sh rootless          # 或 rootful / roothide / all
```

产物在 `packages/`。推送到 `main` 会触发 GitHub Actions 自动编译并发布 Release。

## 类名与版本适配

朋友圈控制器是 **`WCTimeLineViewController`**，底栏是 **`MMTabBarController` / `MMTabBar`**，
发现页是 **`FindFriendEntryViewController`**。前两个已在 class-dump 的微信 8.0.54 与 8.0.55
头文件里确认一致（[Huangbai233/WeChatHeaders](https://github.com/Huangbai233/WeChatHeaders)）。

进入时优先复用发现页自己缓存的那份朋友圈实例（`m_timelineViewController`，session / 数据源 /
已读状态都是微信初始化好的），拿不到才 `alloc init`。升级微信后若类名变了，可用
`momentsClass` 手动指定，不必重新编译。

## 配置项

写入 `/var/mobile/Library/Preferences/cn.qwq.wechatmoments.plist`（改完发 Darwin 通知即生效）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关，关闭后所有 Hook 直通 |
| `holdDelayMs` | `400` | 长按阈值，200–800ms 之间 |
| `badgeWindow` | `5.0` | 拦截陈旧回灌的窗口（秒） |
| `hideHostNavBar` | `false` | 隐藏宿主导航栏（隐藏后只剩左缘侧滑可以返回） |
| `showBackButton` | `true` | 在朋友圈顶栏补一个白色返回箭头 |
| `momentsClass` | — | 手动指定朋友圈控制器类名 |
| `extraMomentsClasses` | — | 追加候选，逗号分隔 |
| `sourceClearSelectors` | — | 自定义"标记朋友圈已读"的选择器，逗号分隔 |
| `verboseLog` | `true` | `log stream --predicate 'eventMessage CONTAINS "WeChatMoments"'` 可见 |

## 排查

### 日志在哪

插件同时写两份：系统统一日志（`NSLog`）和**微信沙盒**里的文件：

```
/var/mobile/Containers/Data/Application/<UUID>/tmp/WeChatMoments.log
```

UUID 每次重装微信都会变，直接用它找：

```bash
ls -t /var/mobile/Containers/Data/Application/*/tmp/WeChatMoments.log | head -1
```

文件上限 30KB，写满后自动丢弃最旧的一半（保留最新 15KB），并留一行 `--- rotated ---` 分隔。
`verboseLog` 关掉后不再写文件。

### 正常应该看到的顺序

装好后日志里应该依次出现这几行（`verboseLog` 默认开）：

```
[22:41:03.120] loaded (enabled=1), WCTimeLineViewController found
[22:41:03.121] log file: /var/mobile/.../tmp/WeChatMoments.log
[22:41:03.640] recognizer installed on MMTabBar (hold 400ms, discover slot 2)
[22:41:03.641] linked MMTabBarController.singleTapGesture to our recognizer
[22:41:05.882] using moments class WCTimeLineViewController
[22:41:05.905] enter moments via WCTimeLineViewController (nav MMUINavigationController, ...)
[22:41:06.612] discover badge visible (unread 0), attempt 1
[22:41:06.613] asked WeChat to settle moments return (1), discover page FindFriendEntryViewController
[22:41:06.980] badge cleared by WeChat itself
[22:41:09.117] exit moments (back-button)
```

- 只有前两行 → 手势装了但没进路由器：检查点击是否落在「发现」槽位；
- `WCTimeLineViewController MISSING` → 类名随版本变了，用 `momentsClass` 覆盖；
- 有 `enter moments` 但 0.6s 后跟一条 `not in window, aborting` → 实例化方式在该版本不可用，
  请把这两行日志发我；
- 完全没有 `loaded` → 插件没注入，检查 `WeChatMoments.plist` 的 filter 是否为 `com.tencent.xin`。

## 验证清单

装好后按顺序过一遍：

1. 单击「发现」→ 直接进时间线，**整条底栏收起**（原生朋友圈就没有底栏），左上角有返回箭头，九宫格不出现；
2. 时间线里点开一条动态 → 返回，回到时间线（不是消息主页）；
3. 再返回 → 落到消息主页，底栏高亮「微信」；
4. 长按「发现」约 0.4s（有触感）→ 抬手后进入九宫格，随手点一项不会误开；
5. 把「发现」红点造出来（视频号 + 朋友圈各有未读）→ 进一次朋友圈 →
   **视频号的未读仍然在**，只少了朋友圈那一份；
6. 冷启动 / 收到推送后观察 5s 内红点是否被旧值刷回来（应被 `WQMBadgeLedger` 拦掉）。

## 已知限制

- 若某版本改变朋友圈实例化方式，present 后 0.6s 的自检会发现"视图没挂到窗口"，
  此时自动退回原生发现页并在日志里记一条 `not in window, aborting presentation`；
- 红点回灌拦截依赖 `MMTabBarController` 的 badge 写入接口，版本改了会退化成"不拦截"，
  但扣减逻辑本身仍然生效；
- 本插件只处理底栏交互，不改动朋友圈内部任何逻辑。
