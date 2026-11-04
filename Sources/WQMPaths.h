#pragma once

#import <Foundation/Foundation.h>

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <rootless.h>
#endif

static inline NSString *wqm_resourcePath(NSString *rootfsPath) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(rootfsPath);
#else
    return ROOT_PATH_NS_VAR(rootfsPath);
#endif
}

static inline NSString *wqm_preferencesPath(void) {
    NSString *path = @"/var/mobile/Library/Preferences/cn.qwq.wechatmoments.plist";
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    /* 用户偏好不跟随 rootless 安装前缀。 */
    return path;
#endif
}
