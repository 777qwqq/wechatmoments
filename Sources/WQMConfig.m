#import "WQMConfig.h"
#import "WQMPreferences.h"

@interface WQMConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void wqm_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object, CFDictionaryRef info) {
    WQMConfig *config = (__bridge WQMConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config wqm_reload];
    });
}

@implementation WQMConfig

+ (instancetype)wqm_shared {
    static WQMConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("can.qwq.wechatmoments.config", DISPATCH_QUEUE_SERIAL);
        [self wqm_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, wqm_preferencesDidChange,
            (__bridge CFStringRef)WQMConfigChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        /* 补一次读取，覆盖"首次读取"与"注册观察者"之间的窗口。 */
        dispatch_async(_reloadQueue, ^{ [self wqm_reload]; });
    }
    return self;
}

- (void)wqm_reload {
    self.snapshot = wqm_readPreferences();
}

- (id)wqm_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    if (key.length == 0) return defaultValue;
    id value = self.snapshot[key];
    return value ?: defaultValue;
}

- (BOOL)wqm_boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id value = [self wqm_valueForKey:key defaultValue:nil];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : defaultValue;
}

- (double)wqm_doubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    id value = [self wqm_valueForKey:key defaultValue:nil];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : defaultValue;
}

- (NSString *)wqm_stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue {
    id value = [self wqm_valueForKey:key defaultValue:nil];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return defaultValue;
}

- (BOOL)wqm_isEnabled {
    return [self wqm_boolForKey:@"enabled" defaultValue:YES];
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
