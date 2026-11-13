// SPDX-License-Identifier: GPL-3.0-only
#import "GXDeviceIdentity.h"
#import <dlfcn.h>
#import <TargetConditionals.h>
#import <sys/sysctl.h>

NSDictionary<NSString *, NSString *> *GXCopyPhysicalHardwareIdentity(void) {
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"hw.machine", @"hw.model"]) {
        char value[128] = {0};
        size_t size = sizeof(value);
        if (sysctlbyname(key.UTF8String, value, &size, NULL, 0) == 0 &&
            size > 1 && size <= sizeof(value) && value[size - 1] == '\0') {
            NSString *text = [NSString stringWithUTF8String:value];
            if (text.length > 0) identity[key] = text;
        }
    }
    return identity;
}

NSDictionary<NSString *, id> *GXCopyCurrentDeviceIdentity(void) {
#if TARGET_OS_SIMULATOR
    return @{};
#else
    typedef CFPropertyListRef (*CopyAnswer)(CFStringRef);
    void *library = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL);
    CopyAnswer copy = library ? (CopyAnswer)dlsym(library, "MGCopyAnswer") : NULL;
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    if (copy) {
        for (NSString *key in @[@"UniqueDeviceID", @"SerialNumber", @"UniqueChipID"]) {
            CFPropertyListRef answer = copy((__bridge CFStringRef)key);
            if (answer) {
                id value = CFBridgingRelease(answer);
                if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) identity[key] = value;
            }
        }
    }
    if (library) dlclose(library);
    return identity;
#endif
}
