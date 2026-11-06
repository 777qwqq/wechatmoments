# 微信朋友圈入口 · WeChatMoments

把底栏「发现」从入口页改造成朋友圈快捷入口：单击直达时间线，长按进原九宫格，返回落回消息主页。自用插件，无配置、无日志。

- 包标识：`cn.qwq.wechatmoments`
- 作用进程：`com.tencent.xin`（主 App，不含扩展）
- 环境：iOS 15+ / 越狱（rootless、rootful、roothide）

## 交互契约

| 操作 | 结果 |
| --- | --- |
| 单击「发现」 | 直接打开朋友圈时间线首屏，不经过发现页 |
| 长按「发现」 | 打开原发现页（九宫格），行为与改动前一致 |
| 从朋友圈返回 | 落到「微信」消息主页 |
| 朋友圈二级页面返回 | 逐级返回，退到时间线首屏再返回才跳出 |
| 单击发生时 | 只清朋友圈那部分红点，不动其它子项 |

## 编译

```bash
export THEOS=/opt/theos
sh build.sh rootless          # 或 rootful / roothide / all
```

产物在 `packages/`。纯逻辑单测不需要 Theos 和真机：

```bash
make -C Tests test
```

## 已知限制

- 若某版本改变朋友圈实例化方式，present 后 0.6s 自检会发现「视图没挂到窗口」，自动退出并回退到原生发现页；
- 红点回灌拦截依赖 `MMTabBarController` 的 badge 写入接口，版本改了会退化成「不拦截」；
- 类名随微信版本变化时，改 `WQMMomentsRouter.m` 里 `resolvedMomentsClass` 的候选数组后重新编译；
- 本插件只处理底栏交互，不改动朋友圈内部逻辑。
