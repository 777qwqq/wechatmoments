#import "WQMLog.h"
#import <os/lock.h>

static BOOL g_logEnabled = NO;
static os_unfair_lock g_logLock = OS_UNFAIR_LOCK_INIT;

BOOL wqm_log_enabled(void) {
    os_unfair_lock_lock(&g_logLock);
    BOOL enabled = g_logEnabled;
    os_unfair_lock_unlock(&g_logLock);
    return enabled;
}

void wqm_log_set_enabled(BOOL enabled) {
    os_unfair_lock_lock(&g_logLock);
    g_logEnabled = enabled;
    os_unfair_lock_unlock(&g_logLock);
}

void wqm_log_write(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[WeChatMoments] %@", message);
}
