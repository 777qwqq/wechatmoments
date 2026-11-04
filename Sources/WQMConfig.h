#pragma once

#import <Foundation/Foundation.h>

/**
 * 只读配置快照。写入见 WQMPreferences.h；跨进程通过 Darwin 通知刷新。
 */
@interface WQMConfig : NSObject

+ (instancetype)wqm_shared;

- (BOOL)wqm_isEnabled;
- (BOOL)wqm_boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (double)wqm_doubleForKey:(NSString *)key defaultValue:(double)defaultValue;
- (NSString *)wqm_stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue;

- (id)wqm_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)wqm_reload;

@end
