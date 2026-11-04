#import "WQMLog.h"

#import <os/lock.h>
#import <stdio.h>
#import <sys/time.h>

/* 微信沙盒 tmp 下的日志；超过上限时只保留最新的一段，避免无限增长。 */
static const unsigned long long kWQMLogFileLimitBytes = 30ULL * 1024ULL;
static const unsigned long long kWQMLogFileKeepBytes = 15ULL * 1024ULL;
static NSString * const kWQMLogFileName = @"WeChatMoments.log";
static const NSUInteger kWQMLogMaxMessageLength = 2000;

static BOOL g_logEnabled = NO;
static os_unfair_lock g_logLock = OS_UNFAIR_LOCK_INIT;
static dispatch_queue_t g_logQueue;
static dispatch_once_t g_logQueueOnce;

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

NSString *wqm_log_file_path(void) {
    /* 进程内就是微信自己的沙盒，NSTemporaryDirectory() 即微信 tmp。 */
    return [NSTemporaryDirectory() stringByAppendingPathComponent:kWQMLogFileName];
}

/* 不用 NSDateFormatter：它非线程安全，而日志可能从任意线程进来。 */
static void wqm_log_stamp(char *buffer, size_t length) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm local;
    localtime_r(&tv.tv_sec, &local);
    snprintf(buffer, length, "%02d:%02d:%02d.%03d",
             local.tm_hour, local.tm_min, local.tm_sec, (int)(tv.tv_usec / 1000));
}

static void wqm_log_write_file(NSString *line) {
    dispatch_once(&g_logQueueOnce, ^{
        g_logQueue = dispatch_queue_create("cn.qwq.wechatmoments.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(g_logQueue, ^{
        @autoreleasepool {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length == 0) return;

            NSString *path = wqm_log_file_path();
            NSFileManager *manager = [NSFileManager defaultManager];
            NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
            unsigned long long size = [attributes fileSize];

            if (size + data.length > kWQMLogFileLimitBytes) {
                NSData *existing = [NSData dataWithContentsOfFile:path];
                NSUInteger keep = (NSUInteger)MIN((unsigned long long)existing.length,
                                                 kWQMLogFileKeepBytes);
                NSMutableData *fresh = [NSMutableData data];
                [fresh appendData:[@"--- rotated ---\n" dataUsingEncoding:NSUTF8StringEncoding]];
                if (keep > 0) {
                    [fresh appendData:[existing subdataWithRange:
                                          NSMakeRange(existing.length - keep, keep)]];
                }
                [fresh appendData:data];
                [fresh writeToFile:path atomically:YES];
                return;
            }

            if (![manager fileExistsAtPath:path]) {
                [data writeToFile:path atomically:YES];
                return;
            }

            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!handle) {
                [data writeToFile:path atomically:YES];
                return;
            }

            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (NSException *exception) {
                /* 写盘失败不影响主流程，丢弃这条即可。 */
            } @finally {
                [handle closeFile];
            }
        }
    });
}

void wqm_log_write(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (message.length > kWQMLogMaxMessageLength) {
        message = [[message substringToIndex:kWQMLogMaxMessageLength]
                   stringByAppendingString:@"…(truncated)"];
    }

    NSLog(@"[WeChatMoments] %@", message);

    char stamp[32] = {0};
    wqm_log_stamp(stamp, sizeof(stamp));
    wqm_log_write_file([NSString stringWithFormat:@"[%s] %@\n", stamp, message]);
}
