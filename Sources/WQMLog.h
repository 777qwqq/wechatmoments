#pragma once

#import <Foundation/Foundation.h>

BOOL wqm_log_enabled(void);
void wqm_log_set_enabled(BOOL enabled);
void wqm_log_write(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#define WQMLog(...) do { if (wqm_log_enabled()) wqm_log_write(__VA_ARGS__); } while (0)
