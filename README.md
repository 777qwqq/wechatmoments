# 微信朋友圈入口插件

## 功能

1. 将微信底栏的"发现"入口替换为"朋友圈"
2. 点击朋友圈后自动清除红点
3. 进入朋友圈页面后自动清除红点
4. 当有新动态时，红点会自动显示

## 工作原理

- Hook `UITabBarController` 的 `titleForTabBarItem:` 方法，将"发现"改为"朋友圈"
- Hook `UIViewController` 的 `viewDidAppear:` 方法，检测是否进入朋友圈页面并清除红点
- Hook `UIApplication` 的 `sendAction:` 方法，拦截点击事件并清除红点
- Hook `UITabBarItem` 的 `setBadgeValue:` 方法，保持发现 tab 的红点显示

## 编译安装

1. 确保设备已越狱
2. 在 Theos 环境中编译：
   ```bash
   make clean
   make package
   ```
3. 将生成的 `.deb` 文件安装到设备
4. 重启 SpringBoard 或重启微信

## 注意事项

- 需要越狱环境
- 适用于 iOS 14+
- 可能需要根据微信版本调整类名和方法名
