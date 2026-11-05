#import "WQMDelegateProxy.h"

/*
 * 只对这些选择器做"双份投递"：既有已读结算，也有返回/红点汇总。
 * 其余方法一律保持微信原本的调用链，避免把 8.0.80 的 cell 配置带偏。
 */
static BOOL wqm_proxy_is_observable_selector(SEL selector) {
    if (!selector) return NO;
    NSString *name = NSStringFromSelector(selector);
    return [name hasPrefix:@"onMarkWCObjectAsRead"] ||
           [name hasPrefix:@"onTimeLine"] ||
           [name hasPrefix:@"noteTabBarBadge"];
}

@implementation WQMDelegateProxy

+ (instancetype)proxyWithTarget:(id)target observer:(id)observer {
    WQMDelegateProxy *proxy = [WQMDelegateProxy alloc];
    proxy.target = target;
    proxy.observer = observer;
    return proxy;
}

#pragma mark - 消息转发

- (BOOL)respondsToSelector:(SEL)selector {
    if (wqm_proxy_is_observable_selector(selector)) {
        return [self.observer respondsToSelector:selector] ||
               [self.target respondsToSelector:selector];
    }
    return [self.target respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    /* 观察名单里的必须走 forwardInvocation，才能同时通知两方。 */
    if (wqm_proxy_is_observable_selector(selector)) return nil;
    if ([self.target respondsToSelector:selector]) return self.target;
    return nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSMethodSignature *signature = [self.target methodSignatureForSelector:selector];
    if (signature) return signature;

    signature = [self.observer methodSignatureForSelector:selector];
    if (signature) return signature;

    /* 两边都没有也要给一个合法签名，否则 runtime 会在 proxy 上抛 unrecognized selector。 */
    return [NSObject instanceMethodSignatureForSelector:@selector(description)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    SEL selector = invocation.selector;
    BOOL handled = NO;

    if (wqm_proxy_is_observable_selector(selector) &&
        [self.observer respondsToSelector:selector]) {
        [invocation invokeWithTarget:self.observer];
        handled = YES;
    }

    if ([self.target respondsToSelector:selector]) {
        [invocation invokeWithTarget:self.target];
        handled = YES;
    }

    if (!handled) {
        /* 谁都不认这条消息：吞掉，绝不让它冒到 proxy 自己身上。 */
        return;
    }
}

#pragma mark - 身份

/* 微信偶尔会拿 delegate 做类判断，这里一律回答 target 的答案。 */
- (BOOL)isKindOfClass:(Class)aClass {
    return [self.target isKindOfClass:aClass];
}

- (Class)class {
    return [self.target class];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    return [self.target conformsToProtocol:protocol];
}

@end
