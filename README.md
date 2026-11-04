# 微信朋友圈入口 · WeChatMoments

把底栏「发现」从一个**入口页**改造成**朋友圈的快捷入口**：单击直达时间线，长按才进原来的九宫格，
返回时绕过发现页直接落回消息主页。

- 包标识：`can.qwq.wechatmoments`
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

1. **让微信自己算**（首选）：调用时间线的"标记已读"入口（`markAllAsRead` / `clearUnread` 等，
   可用 `sourceClearSelectors` 配置），再触发它自己的汇总重算（`updateBadge` / `refreshRedDot` 等）。
   这样汇总点会按"是否还有其他未读"自然收敛，视频号、直播的未读一条都不会丢。
2. **保守扣减**（拿不到子项信息时）：用 `WQMBadgeMath` 只减去朋友圈那部分；
   完全不知道数量时，**最多减 1**，绝不整体清零。
   > 单个未读时直接归零，多个未读时只减一 —— 宁可少清一点，也不误清别的子项。
3. **拦截回灌**（`WQMBadgeLedger`）：本地清完之后，服务端同步或本地缓存可能把同一份旧汇总刷回来。
   清除时开一个 5s 窗口（`badgeWindow` 可调），窗口内 `incoming <= 清除前的值` 的更新被丢弃；
   比旧值更大的更新一律放行（那是真的来了新消息）。

数值全部走纯函数，`Tests/test_badge_math.c` 覆盖了解析、扣减、窗口过期的真值表。

### 3. 返回栈：不压发现页，也不 hook 返回键

```
UITabBarController
  ├─ 消息 / 通讯录 / 我      ← selectedIndex 从头到尾没被改过
  └─ WQMMomentsHost (UINavigationController)   ← 朋友圈只活在这一层
        └─ 时间线 → 详情 / 图片 / 评论 …
```

朋友圈没有进任何一个 tab 的导航栈，而是作为 tab 容器的 child 插在**内容区之上、底栏之下**：

- 出去时不存在"发现页"这个东西，所以返回天然落在用户原来的 tab 上，再统一切回消息主页；
- 不需要 hook 返回键，也不会和微信自己的返回逻辑打架；
- 时间线内部仍然是一个正常的 `UINavigationController`，二级页面照常 `push/pop`。

只有一种情况需要拦截：**栈里只剩时间线自己时的 `pop`**。
`popViewControllerAnimated:` / `popToRootViewControllerAnimated:` / `dismissViewControllerAnimated:` 三个入口
都做了 `viewControllers.count <= 1` 判断，二级页面的返回完全不经过这段逻辑。

**底栏选中态**：微信的底栏是 `MMTabBar : UITabBar`，高亮由每个 `MMTabBarItemView.isSelected` 决定，
不是 `selectedItem`。所以进入时直接改 item view 的选中态（不动 `selectedIndex`，
底下的 tab 内容不会被切换、发现页也不会被加载），退出时按当前 `selectedIndex` 还原；
`layoutSubviews` 之后重钉一次，避免被 `relayoutTabBarItems` 打回去。

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

写入 `/var/mobile/Library/Preferences/can.qwq.wechatmoments.plist`（改完发 Darwin 通知即生效）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关，关闭后所有 Hook 直通 |
| `holdDelayMs` | `400` | 长按阈值，200–800ms 之间 |
| `badgeWindow` | `5.0` | 拦截陈旧回灌的窗口（秒） |
| `hideHostNavBar` | `true` | 朋友圈宿主导航栏是否隐藏（交给微信用自己的导航栏） |
| `momentsClass` | — | 手动指定朋友圈控制器类名 |
| `extraMomentsClasses` | — | 追加候选，逗号分隔 |
| `sourceClearSelectors` | — | 自定义"标记朋友圈已读"的选择器，逗号分隔 |
| `verboseLog` | `true` | `log stream --predicate 'eventMessage CONTAINS "WeChatMoments"'` 可见 |

## 排查

装好后日志里应该依次出现这几行（`verboseLog` 默认开）：

```
[WeChatMoments] loaded (enabled=1), WCTimeLineViewController found
[WeChatMoments] recognizer installed on MMTabBar (hold 400ms, discover slot 2)
[WeChatMoments] linked MMTabBarController.singleTapGesture to our recognizer
[WeChatMoments] using moments class WCTimeLineViewController
[WeChatMoments] enter moments via WCTimeLineViewController (nav MMUINavigationController, ...)
[WeChatMoments] exit moments (pop-timeline-root)
```

- 只有前两行 → 手势装了但没进路由器：检查点击是否落在「发现」槽位；
- `WCTimeLineViewController MISSING` → 类名随版本变了，用 `momentsClass` 覆盖；
- 有 `enter moments` 但 0.6s 后跟一条 `not in window, aborting` → 实例化方式在该版本不可用，
  请把这两行日志发我；
- 完全没有 `loaded` → 插件没注入，检查 `WeChatMoments.plist` 的 filter 是否为 `com.tencent.xin`。

## 验证清单

装好后按顺序过一遍：

1. 单击「发现」→ 直接进时间线，底栏「发现」高亮，**没有**出现九宫格；
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
