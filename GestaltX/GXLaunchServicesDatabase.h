// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface GXLaunchServicesDatabase : NSObject
+ (NSDictionary<NSString *, NSDictionary *> *)applications:(BOOL)discover;
+ (NSDictionary<NSString *, NSNumber *> *)sizesCalibratedWith:(NSDictionary<NSString *, NSNumber *> *)known;
@end
NS_ASSUME_NONNULL_END
