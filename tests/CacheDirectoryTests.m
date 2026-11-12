// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import "GXCacheDirectory.h"
#include <sys/stat.h>

static void require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        require([files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil], @"Create test root");
        NSURL *caches = [root URLByAppendingPathComponent:@"Caches"];
        NSURL *target = [root URLByAppendingPathComponent:@"target"];
        require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil], @"Create target");
        NSData *sentinel = [@"keep the user's cache" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *targetSentinel = [target URLByAppendingPathComponent:@"outside"];
        require([sentinel writeToURL:targetSentinel atomically:YES], @"Write target sentinel");
        for (NSNumber *resultValue in @[@42, @-5, @-6]) {
            require([files createDirectoryAtURL:[caches URLByAppendingPathComponent:@"nested"] withIntermediateDirectories:YES attributes:nil error:nil], @"Create original cache");
            NSURL *saved = [caches URLByAppendingPathComponent:@"nested/value"];
            require([sentinel writeToURL:saved atomically:YES], @"Write cache sentinel");
            struct stat before, after;
            require(lstat(caches.fileSystemRepresentation, &before) == 0, @"Stat original");
            int64_t result = -4; NSError *error = nil;
            BOOL restored = GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
                require([[files destinationOfSymbolicLinkAtPath:caches.path error:nil] isEqualToString:target.path], @"Query sees the temporary link");
                return resultValue.longLongValue;
            }, &result, &error);
            require(restored && !error && result == resultValue.longLongValue, @"Keep success and failed query results");
            require([[NSData dataWithContentsOfURL:saved] isEqual:sentinel], @"Restore nested cache contents");
            require(lstat(caches.fileSystemRepresentation, &after) == 0 && before.st_ino == after.st_ino, @"Restore the original directory, not an empty replacement");
            require([files removeItemAtURL:caches error:nil], @"Reset original cache");
        }
        // Missing and dangling-link originals are handled without following them.
        int64_t result = -4; NSError *error = nil;
        require(GXWithTemporaryCacheLink(caches, target.path, ^int64_t { return 1; }, &result, &error), @"Handle an absent Caches directory");
        NSNumber *directory = nil;
        [caches getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        require(directory.boolValue, @"Recreate a cache directory when no original existed");
        require([files removeItemAtURL:caches error:nil], @"Remove new empty cache");
        NSString *missing = [root.path stringByAppendingPathComponent:@"missing"];
        require([files createSymbolicLinkAtPath:caches.path withDestinationPath:missing error:nil], @"Create dangling original");
        require(GXWithTemporaryCacheLink(caches, target.path, ^int64_t { return 2; }, &result, &error), @"Handle dangling original");
        require([[files destinationOfSymbolicLinkAtPath:caches.path error:nil] isEqualToString:missing], @"Restore dangling link itself");
        require([files removeItemAtURL:caches error:nil], @"Reset dangling link");

        require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil], @"Create cache for failed setup");
        require([sentinel writeToURL:[caches URLByAppendingPathComponent:@"value"] atomically:YES], @"Write setup-failure sentinel");
        __block BOOL invoked = NO;
        NSString *oversizedTarget = [@"x" stringByPaddingToLength:16384 withString:@"x" startingAtIndex:0];
        require(!GXWithTemporaryCacheLink(caches, oversizedTarget, ^int64_t { invoked = YES; return 3; }, &result, &error), @"Oversized link destination fails setup");
        require(!invoked && [[NSData dataWithContentsOfURL:[caches URLByAppendingPathComponent:@"value"]] isEqual:sentinel], @"Setup failure restores saved contents without invoking query");

        error = nil;
        require(!GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
            require([files removeItemAtURL:caches error:nil], @"Remove temporary link to simulate a concurrent replacement");
            require([@"concurrent content" writeToURL:caches atomically:YES encoding:NSUTF8StringEncoding error:nil], @"Create another process's item");
            return 4;
        }, &result, &error), @"Do not destroy a concurrent replacement");
        require([[NSString stringWithContentsOfURL:caches encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"concurrent content"], @"Retain concurrent content");
        NSArray<NSURL *> *children = [files contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil];
        NSArray<NSURL *> *backups = [children filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { return [url.lastPathComponent hasPrefix:@".GestaltX-Caches-"]; }]];
        require(backups.count == 1 && [[NSData dataWithContentsOfURL:[backups.firstObject URLByAppendingPathComponent:@"value"]] isEqual:sentinel], @"Keep original data in its recovery location after a cleanup conflict");
        require([[NSData dataWithContentsOfURL:targetSentinel] isEqual:sentinel], @"Never delete the symlink target's contents");
        [files removeItemAtURL:root error:nil];
        puts("PASS: cache contents and original inode survive successful and rejected queries, setup errors, dangling links and concurrent replacements.");
    }
    return 0;
}
