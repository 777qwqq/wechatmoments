#import <UIKit/UIKit.h>
#import "AxsWeChatMomentsConfig.h"
#import "AxsWeChatMomentsPrivate.h"

// 微信的 TabBar Item 标题
static NSString * const kWeChatTabDiscoverTitle = @"发现";
static NSString * const kWeChatTabMomentsTitle = @"朋友圈";
static NSString * const kWeChatTabMessageTitle = @"微信";

// 保存发现 tab 和消息 tab 的 UITabBarItem 引用
static UITabBarItem *g_momentsTabItem = nil;
static UITabBarItem *g_messageTabItem = nil;

%hook UITabBarController

- (NSArray<UITabBarItem *> *)tabBar {
    NSArray *originalItems = %orig;
    // 找到发现 tab 和消息 tab
    if (originalItems.count > 0) {
        // 消息 tab 通常在索引 0
        g_messageTabItem = originalItems[0];
        // 发现 tab 通常在索引 2
        if (originalItems.count > 2) {
            UITabBarItem *discoverItem = originalItems[2];
            // 检查是否是发现 tab
            if ([discoverItem.title isEqualToString:kWeChatTabDiscoverTitle]) {
                g_momentsTabItem = discoverItem;
            }
        }
    }
    return originalItems;
}

- (NSString *)titleForTabBarItem:(UITabBarItem *)tabItem {
    NSString *originalTitle = %orig;
    // 替换发现 tab 的标题为 朋友圈
    if ([originalTitle isEqualToString:kWeChatTabDiscoverTitle]) {
        return kWeChatTabMomentsTitle;
    }
    return originalTitle;
}

- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    %orig;
    
    // 当从朋友圈返回时，强制切换到消息 tab
    NSString *title = viewController.title ?: @"";
    NSString *className = NSStringFromClass([viewController class]);
    
    // 判断是否是从朋友圈返回（视图控制器的父 tab bar controller 是当前 tab bar controller）
    if ([title containsString:@"朋友圈"] ||
        [className containsString:@"Moments"] ||
        [className containsString:@"MomentsList"]) {
        // 强制切换到消息 tab（索引 0）
        if (tabBarController.selectedIndex != 0) {
            [tabBarController setSelectedIndex:0];
        }
    }
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 当进入朋友圈页面时，清除红点
    NSString *title = self.title ?: @"";
    NSString *className = NSStringFromClass([self class]);

    // 判断是否进入了朋友圈页面
    if ([title containsString:@"朋友圈"] ||
        [className containsString:@"Moments"] ||
        [className containsString:@"MomentsList"]) {
        // 获取 tab bar controller 并清除红点
        UITabBarController *tabBarController = (id)[UIApplication sharedApplication].keyWindow.rootViewController;
        if ([tabBarController isKindOfClass:[UITabBarController class]]) {
            NSArray *items = [tabBarController tabBar].items;
            if (items.count > 2) {
                [items[2] setBadgeValue:nil];
            }
        }
    }
}

%end

%hook UIApplication

- (void)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    // 监听点击事件，当点击发现 tab 时清除红点
    if (action == @selector(tabBarController:didSelectViewController:)) {
        if ([sender isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tabBarController = (UITabBarController *)sender;
            NSArray *items = [tabBarController tabBar].items;
            if (items.count > 2) {
                [items[2] setBadgeValue:nil];
            }
        }
    }
    %orig;
}

%end

%hook UITabBarItem

- (void)setBadgeValue:(NSString *)badgeValue {
    // 如果是发现 tab 的红点，保持显示
    if (g_momentsTabItem == self) {
        %orig;
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsWeChatMomentsConfig axs_wechatmoments_shared];
    }
}
