// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface GXCustomizationAccess : NSObject
+ (nullable NSString *)containerForIdentifier:(NSString *)identifier NS_SWIFT_NAME(container(for:));
+ (int64_t)acquirePath:(NSString *)path;
+ (BOOL)openApplication:(NSString *)identifier;
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)launchApplications;
+ (nullable NSString *)launchContainerForIdentifier:(NSString *)identifier NS_SWIFT_NAME(launchContainer(for:));
+ (NSDictionary<NSString *, id> *)launchApplicationInventory:(BOOL)discover;
+ (NSDictionary<NSString *, id> *)verifyLaunchApplication:(NSDictionary<NSString *, id> *)metadata;
+ (nullable NSString *)applicationContainerForIdentifier:(NSString *)identifier hint:(nullable NSString *)hint NS_SWIFT_NAME(applicationContainer(for:hint:));
+ (NSDictionary<NSString *,NSString *> *)applicationGroupContainersForIdentifier:(NSString *)identifier NS_SWIFT_NAME(applicationGroupContainers(for:));
@end
NS_ASSUME_NONNULL_END
