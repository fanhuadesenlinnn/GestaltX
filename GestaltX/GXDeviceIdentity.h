// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

// Only available local answers are returned. No identifiers are logged.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nonnull GXCopyCurrentDeviceIdentity(void);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nonnull GXCopyPhysicalHardwareIdentity(void);
