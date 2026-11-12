// SPDX-License-Identifier: GPL-3.0-only
#import "GXCacheDirectory.h"
#include <sys/stat.h>
#include <errno.h>

static NSError *GXCacheError(int code, NSURL *url) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                           userInfo:@{NSFilePathErrorKey: url.path}];
}

BOOL GXWithTemporaryCacheLink(NSURL *caches, NSString *target,
                              int64_t (^operation)(void), int64_t *result,
                              NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    struct stat original;
    BOOL existed = lstat(caches.fileSystemRepresentation, &original) == 0;
    if (!existed && errno != ENOENT) {
        if (error) *error = GXCacheError(errno, caches);
        return NO;
    }
    NSURL *backup = [caches.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                     [NSString stringWithFormat:@".GestaltX-Caches-%@.backup", NSUUID.UUID.UUIDString]];
    if (existed && ![files moveItemAtURL:caches toURL:backup error:error]) return NO;

    NSError *setupError = nil;
    BOOL installed = [files createSymbolicLinkAtPath:caches.path withDestinationPath:target error:&setupError];
    struct stat installedLink;
    BOOL identified = NO;
    if (installed) {
        if (lstat(caches.fileSystemRepresentation, &installedLink) != 0) {
            setupError = GXCacheError(errno, caches);
        } else if (!S_ISLNK(installedLink.st_mode)) {
            setupError = GXCacheError(EBUSY, caches);
        } else {
            identified = YES;
        }
    }
    NSError *restoreError = nil;
    @try {
        if (identified) *result = operation();
    } @finally {
        // Do not remove a replacement created by another process. If cleanup
        // cannot finish, leave the saved original in place for recovery.
        BOOL canRestore = YES;
        if (installed) {
            struct stat current;
            if (lstat(caches.fileSystemRepresentation, &current) == 0) {
                if (!identified || !S_ISLNK(current.st_mode) ||
                    current.st_dev != installedLink.st_dev || current.st_ino != installedLink.st_ino) {
                    restoreError = GXCacheError(EBUSY, backup);
                    canRestore = NO;
                } else {
                    canRestore = [files removeItemAtURL:caches error:&restoreError];
                }
            } else if (errno != ENOENT) {
                restoreError = GXCacheError(errno, caches);
                canRestore = NO;
            }
        }
        if (canRestore && existed) {
            [files moveItemAtURL:backup toURL:caches error:&restoreError];
        } else if (canRestore && installed) {
            [files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:&restoreError];
        }
    }
    if (error) *error = restoreError ?: setupError;
    return identified && restoreError == nil;
}
