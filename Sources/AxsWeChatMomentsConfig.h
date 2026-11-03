#pragma once

#import <Foundation/Foundation.h>

@interface AxsWeChatMomentsConfig : NSObject
+ (instancetype)axs_wechatmoments_shared;
- (BOOL)axs_wechatmoments_isEnabled;
- (id)axs_wechatmoments_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_wechatmoments_reload;
@end
