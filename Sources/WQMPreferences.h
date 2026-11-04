#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "WQMPaths.h"

static NSString * const WQMConfigDomain = @"cn.qwq.wechatmoments";
static NSString * const WQMConfigChanged = @"cn.qwq.wechatmoments.preferences-changed";

static inline NSDictionary *wqm_readPreferences(void) {
    NSString *path = wqm_preferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    /* 兼容回退读取，不构成第二个可写位置。 */
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:WQMConfigDomain];
    [defaults synchronize];
    return [defaults persistentDomainForName:WQMConfigDomain] ?: @{};
}

/*
 * 唯一的写入入口。
 * 除了设置面板，插件自身也会用它记录"学习到的朋友圈控制器类名"（learnedMomentsClass）。
 */
static inline BOOL wqm_writePreference(NSString *key, id value, NSError **error) {
    NSString *path = wqm_preferencesPath();
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:WQMConfigDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference path or key"}];
        }
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values;
    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
        id decoded = existing ? [NSPropertyListSerialization propertyListWithData:existing
                         options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:WQMConfigDomain code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Preferences are not a dictionary"}];
            }
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [wqm_readPreferences() mutableCopy];
    }
    if (value) values[key] = value;
    else [values removeObjectForKey:key];
    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:WQMConfigDomain];
    /* 整份镜像写回，避免 cfprefsd 把无关的旧键刷回来。 */
    [defaults setPersistentDomain:values forName:WQMConfigDomain];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)WQMConfigChanged, NULL, NULL, true);
    return YES;
}
