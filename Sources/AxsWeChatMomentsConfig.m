#import "AxsWeChatMomentsConfig.h"
#import "AxsWeChatMomentsPreferences.h"

@interface AxsWeChatMomentsConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_wechatmoments_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsWeChatMomentsConfig *config = (__bridge AxsWeChatMomentsConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_wechatmoments_reload];
    });
}

@implementation AxsWeChatMomentsConfig

+ (instancetype)axs_wechatmoments_shared {
    static AxsWeChatMomentsConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.yourname.wechatmoments.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_wechatmoments_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_wechatmoments_preferencesDidChange,
            (__bridge CFStringRef)AxsWeChatMomentsPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_wechatmoments_reload]; });
    }
    return self;
}

- (void)axs_wechatmoments_reload {
    self.snapshot = axs_wechatmoments_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsWeChatMomentsPreferencesChanged object:self];
    });
}

- (id)axs_wechatmoments_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_wechatmoments_isEnabled {
    id value = [self axs_wechatmoments_valueForKey:@"enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
