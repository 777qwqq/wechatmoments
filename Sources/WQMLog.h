#pragma once

#import <Foundation/Foundation.h>

/*
 * 这个头会被 .xm 引用，而 Logos 把 .xm 当 Objective-C++ 编译，
 * 没有 extern "C" 的话符号会被 mangle，链接时找不到 C 侧的实现。
 */
#ifdef __cplusplus
extern "C" {
#endif

BOOL wqm_log_enabled(void);
void wqm_log_set_enabled(BOOL enabled);
void wqm_log_write(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/* 微信沙盒 tmp/WeChatMoments.log（上限 30KB，超出后保留最新 15KB）。 */
NSString *wqm_log_file_path(void);

#ifdef __cplusplus
}
#endif

#define WQMLog(...) do { if (wqm_log_enabled()) wqm_log_write(__VA_ARGS__); } while (0)
