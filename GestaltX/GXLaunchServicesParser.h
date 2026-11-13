// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface GXLaunchServicesSnapshot : NSObject
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *displayNames;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *names;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *containers;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *bundles;
@property(nonatomic,copy) NSDictionary<NSString *,NSData *> *records;
@property(nonatomic,copy) NSDictionary<NSString *,NSDictionary<NSString *,NSString *> *> *groupContainers;
@end
@interface GXLaunchServicesParser : NSObject
+ (nullable GXLaunchServicesSnapshot *)decode:(NSData *)data;
@end
NS_ASSUME_NONNULL_END
