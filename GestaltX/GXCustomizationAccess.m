// SPDX-License-Identifier: GPL-3.0-only
// Container identity discovery follows forcequitOS's fsgetpath research.
// PosterBoard targets follow Gester (MIT) and Erosion (GPL-3.0).
#import "GXCustomizationAccess.h"
#import "GXEntitlementsReader.h"
#import "GXLaunchServicesDatabase.h"
#import "worse_query.h"
#import <UIKit/UIKit.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/fsgetpath.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <dirent.h>
#include <string.h>
#include <stdarg.h>

static void GXAccessLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void GXAccessLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"[GXAccess] %@", message);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GestaltX.worse_query.log"
                                                      object:nil userInfo:@{@"message": message}];
}

// Snapshot of a container path's identity xattr for diagnostics. Called only at
// decision points (never inside the fsgetpath hot loop) to keep log volume low.
static NSString *GXContainerDiagnostic(NSString *path) {
    if (!path) return @"container=<nil>";
    NSMutableString *out = [NSMutableString stringWithString:@"container="];
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st)) {
        [out appendFormat:@"lstat errno=%d (%s)", errno, strerror(errno)];
        return out;
    }
    [out appendFormat:@"ino=%llu mode=%o", (unsigned long long)st.st_ino, st.st_mode & 07777];
    ssize_t size = listxattr(path.fileSystemRepresentation, NULL, 0, XATTR_NOFOLLOW);
    if (size < 0) {
        [out appendFormat:@" listxattr errno=%d (%s)", errno, strerror(errno)];
    } else {
        [out appendString:@" xattrs=["];
        if (size > 0) {
            char names[2048] = {0};
            ssize_t read = listxattr(path.fileSystemRepresentation, names, sizeof(names)-1, XATTR_NOFOLLOW);
            if (read > 0) {
                BOOL first = YES;
                char *cursor = names;
                ssize_t remaining = read;
                while (remaining > 0) {
                    size_t len = strlen(cursor);
                    [out appendFormat:@"%@%s", first ? @"" : @", ", cursor];
                    first = NO;
                    cursor += len + 1;
                    remaining -= (ssize_t)(len + 1);
                }
            } else {
                [out appendFormat:@"read errno=%d (%s)", errno, strerror(errno)];
            }
        }
        [out appendString:@"]"];
    }
    const char *keys[] = { "com.apple.containermanager.identity", "com.apple.containermanager.identifier" };
    for (NSUInteger i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        char attribute[1024] = {0};
        ssize_t length = getxattr(path.fileSystemRepresentation, keys[i],
                                 attribute, sizeof(attribute)-1, 0, XATTR_NOFOLLOW);
        if (length > 0) {
            NSString *value = [[NSString alloc] initWithBytes:attribute length:(size_t)length encoding:NSUTF8StringEncoding];
            if (value) {
                [out appendFormat:@" %s=%@", keys[i], value];
            } else {
                NSMutableString *hex = [NSMutableString string];
                for (ssize_t b = 0; b < length && b < 64; b++) [hex appendFormat:@"%02x", (unsigned char)attribute[b]];
                [out appendFormat:@" %s=<%zd bytes hex:%@>", keys[i], length, hex];
            }
        } else {
            [out appendFormat:@" %s errno=%d (%s)", keys[i], errno, strerror(errno)];
        }
    }
    return out;
}

@interface NSObject (GXCustomizationWorkspace)
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)identifier;
- (NSArray *)allApplications;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSURL *)dataContainerURL;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)bundleURL;
- (NSString *)bundleVersion;
- (NSString *)shortVersionString;
- (NSNumber *)staticDiskUsage;
- (NSNumber *)dynamicDiskUsage;
- (BOOL)isInstalled;
@end

static NSArray<NSString *> *GXAllowedApplications(void) {
    return @[@"com.apple.PosterBoard"];
}
static NSString *GXContainerIdentity(NSString *path) {
    // iOS 26/27 renamed this xattr from `.identifier` to `.identity`, and the
    // new value is a "key: value" document whose `identifier:` line holds the
    // owning bundle ID (see tester log 0101). The legacy `.identifier` value is
    // the bundle ID directly.
    const char *keys[] = { "com.apple.containermanager.identity", "com.apple.containermanager.identifier" };
    for (NSUInteger i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        char attribute[4096] = {0};
        ssize_t length = getxattr(path.fileSystemRepresentation, keys[i],
                                  attribute, sizeof(attribute)-1, 0, XATTR_NOFOLLOW);
        if (length <= 0) continue;
        NSString *value = [[NSString alloc] initWithBytes:attribute length:strnlen(attribute,(size_t)length)
                                                  encoding:NSUTF8StringEncoding];
        if (!value.length) continue;
        NSCharacterSet *trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        for (NSString *line in [value componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:trim];
            if ([trimmed hasPrefix:@"identifier:"]) {
                NSString *identifier = [[trimmed substringFromIndex:11] stringByTrimmingCharactersInSet:trim];
                if (identifier.length) return identifier;
            }
        }
        // Legacy flat value: the xattr itself is the bundle ID.
        return value;
    }
    return nil;
}
static BOOL GXApplicationPath(NSString *path) {
    NSString *prefix = @"/private/var/mobile/Containers/Data/Application/";
    if (![path hasPrefix:prefix]) {
        prefix = @"/var/mobile/Containers/Data/Application/";
        if (![path hasPrefix:prefix]) return NO;
    }
    NSString *tail = [path substringFromIndex:prefix.length];
    return tail.length == 36 && [[NSUUID alloc] initWithUUIDString:tail] != nil;
}

static BOOL GXLaunchIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || identifier.length < 3 || identifier.length > 255 ||
        ![identifier containsString:@"."] || [@[@".", @".."] containsObject:identifier]) return NO;
    NSCharacterSet *valid=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    return [identifier rangeOfCharacterFromSet:valid.invertedSet].location == NSNotFound;
}
static void *GXSpringBoardServices(void) {
    static void *library;static dispatch_once_t once;
    dispatch_once(&once,^{library=dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",RTLD_LAZY|RTLD_LOCAL);});
    return library;
}
static id GXCopySpringBoardValue(const char *symbol, NSString *identifier) {
    void *library=GXSpringBoardServices();if(!library)return nil;
    CFTypeRef (*copy)(CFStringRef)=(void *)dlsym(library,symbol);
    return copy?CFBridgingRelease(copy((__bridge CFStringRef)identifier)):nil;
}
static BOOL GXHasLaunchImages(NSString *container, NSString *identifier) {
    NSString *path=[container stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/SplashBoard/Snapshots/%@ - {DEFAULT GROUP}",identifier]];
    struct stat st;
    if(lstat(path.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode))return NO;
    int directory=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(directory<0)return NO;
    DIR *stream=fdopendir(directory);if(!stream){close(directory);return NO;}
    BOOL found=NO;NSUInteger count=0;struct dirent *entry;
    while((entry=readdir(stream))&&++count<=128){
        NSString *name=[NSString stringWithUTF8String:entry->d_name];
        if(!name||![@[@"ktx",@"png",@"jpg",@"jpeg"]containsObject:name.pathExtension.lowercaseString])continue;
        int fd=openat(directory,entry->d_name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(fd<0)continue;
        struct stat file;found=fstat(fd,&file)==0&&S_ISREG(file.st_mode)&&file.st_size>0&&file.st_size<=20*1024*1024;
        close(fd);if(found)break;
    }
    closedir(stream);return found;
}

static void GXDiscoverLaunchPaths(void) {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSMutableSet *known=NSMutableSet.new;
    for(NSString *key in defaults.dictionaryRepresentation)if([key hasPrefix:@"GestaltX.launch.container."]){
        id path=[defaults objectForKey:key];if([path isKindOfClass:NSString.class]&&GXApplicationPath(path))[known addObject:path];
    }
    NSString *probe=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int fd=open(probe.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
    struct stat info;struct statfs volume;
    BOOL valid=fd>=0&&fstat(fd,&info)==0&&fstatfs(fd,&volume)==0;
    if(fd>=0){close(fd);unlink(probe.fileSystemRepresentation);}
    if(!valid||(uint64_t)info.st_ino>UINT64_MAX-100000)return;
    uint64_t upper=(uint64_t)info.st_ino+100000;NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];char buffer[4096];
    for(uint64_t inode=1;inode<=upper;inode++){
        if(!(inode%4096)&&deadline.timeIntervalSinceNow<0)break;
        @autoreleasepool {
            if(fsgetpath(buffer,sizeof(buffer),&volume.f_fsid,inode)<=0)continue;
            NSString *path=[NSString stringWithUTF8String:buffer];if(!GXApplicationPath(path)||[known containsObject:path])continue;
            int64_t handle=[GXCustomizationAccess acquirePath:path];NSString *identifier=handle>=0?GXContainerIdentity(path):nil;
            if(handle>=0)worse_query_release(handle);
            if(GXLaunchIdentifier(identifier)){[known addObject:path];[defaults setObject:path forKey:[@"GestaltX.launch.container." stringByAppendingString:identifier]];}
        }
    }
}

@implementation GXCustomizationAccess
+ (NSDictionary<NSString *,NSString *> *)applicationGroupContainersForIdentifier:(NSString *)identifier {
    if(!GXLaunchIdentifier(identifier))return @{};
    id maps=[GXLaunchServicesDatabase applications:NO][identifier][@"groups"];
    if(![maps isKindOfClass:NSDictionary.class]||[maps count]>64)return @{};
    NSMutableDictionary *verified=NSMutableDictionary.new;
    NSString *prefix=@"/private/var/mobile/Containers/Shared/AppGroup/";
    for(id group in maps){
        id path=maps[group];
        if(![group isKindOfClass:NSString.class]||![path isKindOfClass:NSString.class]||
           ![path hasPrefix:prefix]||![[NSUUID alloc]initWithUUIDString:[path substringFromIndex:prefix.length]])continue;
        int64_t lease=[self acquirePath:path];if(lease<0)continue;
        @try {
            struct stat info;
            if(!lstat([path fileSystemRepresentation],&info)&&S_ISDIR(info.st_mode)&&[GXContainerIdentity(path)isEqualToString:group])verified[group]=path;
        } @finally {worse_query_release(lease);}
    }
    return verified;
}
+ (NSString *)applicationContainerForIdentifier:(NSString *)identifier hint:(NSString *)hint {
    if (!GXLaunchIdentifier(identifier)) return nil;
    if ([identifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return NSHomeDirectory();
    NSString *key = [@"GestaltX.launch.container." stringByAppendingString:identifier];
    NSString *path = GXApplicationPath(hint) ? hint : [NSUserDefaults.standardUserDefaults stringForKey:key];
    if (!GXApplicationPath(path)) return nil;
    int64_t handle = [self acquirePath:path];
    if (handle < 0) return nil;
    @try {
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) ||
            ![GXContainerIdentity(path) isEqualToString:identifier]) return nil;
        [NSUserDefaults.standardUserDefaults setObject:path forKey:key];
        return path;
    } @finally { worse_query_release(handle); }
}
+ (NSDictionary<NSString *,id> *)launchApplicationInventory:(BOOL)discover {
    NSDictionary *database=[GXLaunchServicesDatabase applications:discover];
    if(discover&&!database.count)GXDiscoverLaunchPaths();
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW|RTLD_LOCAL);
    Class workspace=NSClassFromString(@"LSApplicationWorkspace"),proxyClass=NSClassFromString(@"LSApplicationProxy");
    NSMutableDictionary<NSString *,id> *proxies=NSMutableDictionary.new;
    NSMutableSet<NSString *> *identifiers=NSMutableSet.new;
    [identifiers addObjectsFromArray:database.allKeys];
    NSArray *bulk=@[];
    @try {
        id service=[workspace respondsToSelector:@selector(defaultWorkspace)]?[workspace defaultWorkspace]:nil;
        if([service respondsToSelector:@selector(allApplications)])bulk=[service allApplications]?:@[];
        for(id proxy in bulk){NSString *identifier=[proxy bundleIdentifier];if(GXLaunchIdentifier(identifier)){proxies[identifier]=proxy;[identifiers addObject:identifier];}}
    }@catch(NSException *exception){bulk=@[];}
    if(bulk.count<=1){
        void *library=GXSpringBoardServices();CFArrayRef (*copy)(BOOL,BOOL)=library?(void *)dlsym(library,"SBSCopyApplicationDisplayIdentifiers"):NULL;
        NSArray *fallback=copy?CFBridgingRelease(copy(NO,NO)):nil;
        if([fallback isKindOfClass:NSArray.class])for(id identifier in fallback)if(GXLaunchIdentifier(identifier))[identifiers addObject:identifier];
    }
    NSString *own=NSBundle.mainBundle.bundleIdentifier,*prefix=@"GestaltX.launch.container.";
    if(own)[identifiers addObject:own];
    for(NSString *key in NSUserDefaults.standardUserDefaults.dictionaryRepresentation)if([key hasPrefix:prefix]){
        NSString *identifier=[key substringFromIndex:prefix.length];if(GXLaunchIdentifier(identifier))[identifiers addObject:identifier];
    }
    NSMutableArray *items=NSMutableArray.new;
    NSMutableDictionary *knownSizes=NSMutableDictionary.new;
    for(NSString *identifier in identifiers){
        @autoreleasepool {
            NSMutableDictionary *item=[@{@"identifier":identifier,@"name":identifier,@"size":@0,@"installed":@YES}mutableCopy];
            NSString *path=[NSUserDefaults.standardUserDefaults stringForKey:[prefix stringByAppendingString:identifier]];
            NSDictionary *record=database[identifier];
            if(GXApplicationPath(record[@"container"])){
                struct stat previous;
                if(!GXApplicationPath(path)||(lstat(path.fileSystemRepresentation,&previous)&&errno==ENOENT))path=record[@"container"];
            }
            if([record[@"name"]isKindOfClass:NSString.class])item[@"name"]=record[@"name"];
            NSString *bundle=record[@"bundle"]?:@"",*version=@"";uint64_t size=0;
            BOOL haveProxy=NO;
            @try {
                id proxy=proxies[identifier];
                if(!proxy&&[proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)])proxy=[proxyClass applicationProxyForIdentifier:identifier];
                haveProxy=proxy!=nil;
                if(!proxy&&bulk.count>1)item[@"installed"]=@NO;
                if(proxy){
                    NSString *name=[proxy respondsToSelector:@selector(localizedName)]?[proxy localizedName]:nil;
                    if(name.length&&![name isEqualToString:identifier])item[@"name"]=name;
                    // Restricted clients receive placeholder proxies with isInstalled=NO.
                    // Only a complete roster may be used to infer removal.
                    if(bulk.count>1&&[proxy respondsToSelector:@selector(isInstalled)])item[@"installed"]=@([proxy isInstalled]);
                    NSString *candidate=[proxy respondsToSelector:@selector(dataContainerURL)]?[[proxy dataContainerURL]path]:nil;
                    if(GXApplicationPath(candidate))path=candidate;
                    if([proxy respondsToSelector:@selector(bundleURL)])bundle=[[proxy bundleURL]path]?:bundle;
                    if([proxy respondsToSelector:@selector(bundleVersion)])version=[proxy bundleVersion]?:@"";
                    NSNumber *fixed=[proxy respondsToSelector:@selector(staticDiskUsage)]?[proxy staticDiskUsage]:nil;
                    NSNumber *dynamic=[proxy respondsToSelector:@selector(dynamicDiskUsage)]?[proxy dynamicDiskUsage]:nil;
                    if([fixed isKindOfClass:NSNumber.class])size=MIN(fixed.unsignedLongLongValue,(uint64_t)INT64_MAX);
                    if([fixed isKindOfClass:NSNumber.class]&&fixed.unsignedLongLongValue>0)knownSizes[identifier]=fixed;
                    if([dynamic isKindOfClass:NSNumber.class]&&dynamic.unsignedLongLongValue<=INT64_MAX-size)size+=dynamic.unsignedLongLongValue;
                }
            }@catch(NSException *exception){}
            if([item[@"name"]isEqualToString:identifier]){
                id name=GXCopySpringBoardValue("SBSCopyLocalizedApplicationNameForDisplayIdentifier",identifier);
                if([name isKindOfClass:NSString.class]&&[name length])item[@"name"]=name;
            }
            if(GXApplicationPath(path)){
                int64_t handle=haveProxy?-1:[self acquirePath:path];struct stat attributes;
                if(lstat(path.fileSystemRepresentation,&attributes)&&errno==ENOENT)item[@"installed"]=@NO;
                if(handle>=0)worse_query_release(handle);
            }
            if([identifier isEqualToString:own]){
                item[@"name"]=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]?:@"GestaltX";
                path=NSHomeDirectory();bundle=NSBundle.mainBundle.bundlePath;
                version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"";
                item[@"installed"]=@YES;
            }
            item[@"size"]=@(MIN(size,(uint64_t)INT64_MAX));
            if(GXApplicationPath(path))item[@"container"]=path;
            item[@"generation"]=[NSString stringWithFormat:@"%@|%@|%@",bundle,version,path?:@""];
            [items addObject:item];
        }
    }
    NSDictionary *sizes=[GXLaunchServicesDatabase sizesCalibratedWith:knownSizes];
    for(NSMutableDictionary *item in items)if([item[@"size"]longLongValue]<=0&&sizes[item[@"identifier"]])item[@"size"]=sizes[item[@"identifier"]];
    struct stat root;
    NSString *generation=@"";
    if(!lstat("/private/var/mobile/Containers/Data/Application",&root))generation=[NSString stringWithFormat:@"%llu:%lld:%ld",(unsigned long long)root.st_ino,(long long)root.st_mtimespec.tv_sec,root.st_mtimespec.tv_nsec];
    return @{@"complete":@(bulk.count>1),@"applications":items,@"containerGeneration":generation};
}
+ (NSDictionary<NSString *,id> *)verifyLaunchApplication:(NSDictionary<NSString *,id> *)metadata {
    NSString *identifier=metadata[@"identifier"],*path=metadata[@"container"];
    if(!GXLaunchIdentifier(identifier)){GXAccessLog(@"verifyLaunch: invalid identifier '%@'",identifier);return @{@"available":@NO,@"retryable":@NO};}
    BOOL own=[identifier isEqualToString:NSBundle.mainBundle.bundleIdentifier];
    if(own)path=NSHomeDirectory();
    if(!GXApplicationPath(path)){GXAccessLog(@"verifyLaunch[%@]: invalid container path '%@'",identifier,path?:@"<nil>");return @{@"available":@NO,@"retryable":@YES};}
    int64_t handle=own?-1:[self acquirePath:path];
    if(!own&&handle<0){GXAccessLog(@"verifyLaunch[%@]: acquirePath failed handle=%lld — %@",identifier,(long long)handle,GXContainerDiagnostic(path));return @{@"available":@NO,@"retryable":@YES};}
    @try {
        struct stat info;
        if(lstat(path.fileSystemRepresentation,&info)){
            GXAccessLog(@"verifyLaunch[%@]: lstat failed errno=%d (%s) path=%@",identifier,errno,strerror(errno),path);
            return @{@"available":@NO,@"retryable":@(errno!=ENOENT),@"missing":@(errno==ENOENT)};
        }
        NSString *actual=GXContainerIdentity(path);
        if(!own&&![actual isEqualToString:identifier]){
            GXAccessLog(@"verifyLaunch[%@]: identity mismatch actual=%@ — %@",identifier,actual?:@"<nil>",GXContainerDiagnostic(path));
            return @{@"available":@NO,@"retryable":@YES};
        }
        [NSUserDefaults.standardUserDefaults setObject:path forKey:[@"GestaltX.launch.container." stringByAppendingString:identifier]];
        BOOL available=GXHasLaunchImages(path,identifier);
        GXAccessLog(@"verifyLaunch[%@]: available=%d",identifier,available);
        return @{@"available":@(available),@"retryable":@NO};
    }@finally{if(handle>=0)worse_query_release(handle);}
}
+ (NSString *)launchContainerForIdentifier:(NSString *)identifier {
    if(!GXLaunchIdentifier(identifier)){GXAccessLog(@"launchContainer: invalid identifier '%@'",identifier);return nil;}
    if([identifier isEqualToString:NSBundle.mainBundle.bundleIdentifier])return NSHomeDirectory();
    NSString *key=[@"GestaltX.launch.container." stringByAppendingString:identifier];
    NSString *path=[NSUserDefaults.standardUserDefaults stringForKey:key];
    if(!GXApplicationPath(path)){
        GXAccessLog(@"launchContainer[%@]: no cached container (key=%@)",identifier,key);
        return nil;
    }
    int64_t handle=[self acquirePath:path];
    NSString *actual=GXContainerIdentity(path);
    if(handle>=0)worse_query_release(handle);
    BOOL matches=handle>=0 && [actual isEqualToString:identifier];
    if(!matches){
        GXAccessLog(@"launchContainer[%@]: failure handle=%lld actual=%@ — %@",identifier,(long long)handle,actual?:@"<nil>",GXContainerDiagnostic(path));
    }
    return matches?path:nil;
}
+ (NSArray<NSDictionary<NSString *,NSString *> *> *)launchApplications {
    @synchronized(self) {
        NSMutableDictionary<NSString *,NSString *> *names=NSMutableDictionary.new,*paths=NSMutableDictionary.new;
        NSMutableArray<NSDictionary<NSString *,NSString *> *> *result=NSMutableArray.new;
        NSString *own=NSBundle.mainBundle.bundleIdentifier;
        if(own){paths[own]=NSHomeDirectory();names[own]=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]?:@"GestaltX";}
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW|RTLD_LOCAL);
        Class workspace=NSClassFromString(@"LSApplicationWorkspace");
        id service=[workspace respondsToSelector:@selector(defaultWorkspace)]?[workspace defaultWorkspace]:nil;
        NSArray *applications=@[];
        @try {if([service respondsToSelector:@selector(allApplications)])applications=[service allApplications];}
        @catch(NSException *exception){applications=@[];}
        for(id app in applications){
            if(![app respondsToSelector:@selector(bundleIdentifier)])continue;
            NSString *identifier=[app bundleIdentifier];if(!GXLaunchIdentifier(identifier))continue;
            NSString *name=[app respondsToSelector:@selector(localizedName)]?[app localizedName]:nil;
            if(name.length)names[identifier]=name;
            NSString *path=[app respondsToSelector:@selector(dataContainerURL)]?[[app dataContainerURL]path]:nil;
            if(GXApplicationPath(path))paths[identifier]=path;
        }
        // Previously discovered containers avoid repeated enumeration. Recheck
        // their xattr identity below; uninstall/reinstall never reuses old trust.
        NSDictionary *defaults=NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
        NSString *prefix=@"GestaltX.launch.container.";
        for(NSString *key in defaults)if([key hasPrefix:prefix]){
            NSString *identifier=[key substringFromIndex:prefix.length];id path=defaults[key];
            if(GXLaunchIdentifier(identifier)&&[path isKindOfClass:NSString.class]&&GXApplicationPath(path)&&!paths[identifier])paths[identifier]=path;
        }
        // The same bounded fsgetpath discovery used for PosterBoard supplies
        // data-container paths when LaunchServices withholds them from clients.
        struct statfs volume;struct stat statOwn;
        NSString *probe=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        int probeFD=open(probe.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
        BOOL haveInode=probeFD>=0&&fstat(probeFD,&statOwn)==0;
        if(probeFD>=0){close(probeFD);unlink(probe.fileSystemRepresentation);}
        if(haveInode&&!statfs(NSHomeDirectory().fileSystemRepresentation,&volume)&&statOwn.st_ino>0){
            uint64_t upper=(uint64_t)statOwn.st_ino;
            if(upper<=UINT64_MAX-100000)upper+=100000;
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];char buffer[4096];
            for(uint64_t inode=1;inode<=upper;inode++){
                @autoreleasepool {
                if(!(inode%4096)&&deadline.timeIntervalSinceNow<0)break;
                if(fsgetpath(buffer,sizeof(buffer),&volume.f_fsid,inode)<=0)continue;
                NSString *path=[NSString stringWithUTF8String:buffer];if(!GXApplicationPath(path)||[paths.allValues containsObject:path])continue;
                int64_t handle=[self acquirePath:path];NSString *identifier=GXContainerIdentity(path);
                if(handle>=0 && GXLaunchIdentifier(identifier)&&GXHasLaunchImages(path,identifier))paths[identifier]=path;
                if(handle>=0)worse_query_release(handle);
                }
            }
        }
        for(NSString *identifier in paths){
            NSString *path=paths[identifier];BOOL isOwn=[identifier isEqualToString:own];
            int64_t handle=isOwn?-1:[self acquirePath:path];
            BOOL valid=isOwn||(handle>=0&&[GXContainerIdentity(path)isEqualToString:identifier]);
            if(valid&&GXHasLaunchImages(path,identifier)){
                [result addObject:@{@"identifier":identifier,@"name":names[identifier]?:identifier}];
                if(!isOwn)[NSUserDefaults.standardUserDefaults setObject:path forKey:[prefix stringByAppendingString:identifier]];
            }
            if(handle>=0)worse_query_release(handle);
        }
        [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            if([a[@"identifier"]isEqualToString:b[@"identifier"]])return NSOrderedSame;
            if([a[@"identifier"]isEqualToString:own])return NSOrderedAscending;
            if([b[@"identifier"]isEqualToString:own])return NSOrderedDescending;
            return [a[@"name"]localizedStandardCompare:b[@"name"]];
        }];
        [[NSNotificationCenter defaultCenter]postNotificationName:@"GestaltX.worse_query.log" object:nil userInfo:@{@"message":[NSString stringWithFormat:@"Launch images: found %lu app(s).",(unsigned long)result.count]}];
        return result;
    }
}
+ (int64_t)acquirePath:(NSString *)path {
    for (NSString *group in GXEntitlementsReader.usableAppGroups) {
        // The final flag skips an unprivileged preflight stat; no target is created.
        int64_t handle = worse_query(path, group, false, true);
        if (handle >= 0) return handle;
    }
    return -1;
}
+ (NSString *)containerForIdentifier:(NSString *)identifier {
    if (![GXAllowedApplications() containsObject:identifier]) return nil;
    @synchronized (self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *key = [@"GestaltX.customization.container." stringByAppendingString:identifier];
        NSString *cached = [defaults stringForKey:key];
        if (GXApplicationPath(cached)) {
            int64_t h = [self acquirePath:cached];
            NSString *actual = GXContainerIdentity(cached);
            if (h >= 0) worse_query_release(h);
            GXAccessLog(@"container[%@]: cached=%@ handle=%lld actual=%@",identifier,cached,(long long)h,actual?:@"<nil>");
            if ([actual isEqualToString:identifier]) return cached;
            GXAccessLog(@"container[%@]: cached identity mismatch — %@",identifier,GXContainerDiagnostic(cached));
        } else {
            GXAccessLog(@"container[%@]: no cached container, running fsgetpath scan",identifier);
        }
        [defaults removeObjectForKey:key];
        struct statfs volume;
        if (statfs("/private/var/mobile/Containers/Data/Application", &volume)) {
            GXAccessLog(@"container[%@]: statfs failed errno=%d (%s)",identifier,errno,strerror(errno));
            return nil;
        }
        NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        int fd = open(probe.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
        if (fd < 0) {
            GXAccessLog(@"container[%@]: probe create failed errno=%d (%s)",identifier,errno,strerror(errno));
            return nil;
        }
        struct stat own; struct statfs ownVolume;
        BOOL valid = fstat(fd,&own) == 0 && fstatfs(fd,&ownVolume) == 0 &&
                     memcmp(&volume.f_fsid,&ownVolume.f_fsid,sizeof(fsid_t)) == 0;
        close(fd); unlink(probe.fileSystemRepresentation);
        if (!valid || (uint64_t)own.st_ino > UINT64_MAX-100000) {
            GXAccessLog(@"container[%@]: probe invalid (valid=%d ino=%llu)",identifier,valid,(unsigned long long)own.st_ino);
            return nil;
        }
        uint64_t upper = (uint64_t)own.st_ino + 100000;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
        NSMutableDictionary<NSString *,NSString *> *found = NSMutableDictionary.new;
        char buffer[4096];
        for (uint64_t ino=1; ino<=upper; ino++) {
            if (!(ino % 4096) && deadline.timeIntervalSinceNow < 0) break;
            @autoreleasepool {
                if (fsgetpath(buffer,sizeof(buffer),&volume.f_fsid,ino) <= 0) continue;
                NSString *path = [NSString stringWithUTF8String:buffer];
                if (!GXApplicationPath(path)) continue;
                int64_t h = [self acquirePath:path];
                NSString *actual = GXContainerIdentity(path);
                if (h >= 0) worse_query_release(h);
                if (actual && [GXAllowedApplications() containsObject:actual]) {
                    found[actual] = path;
                    [defaults setObject:path forKey:[@"GestaltX.customization.container." stringByAppendingString:actual]];
                }
                if (found[identifier]) return found[identifier];
            }
        }
        GXAccessLog(@"container[%@]: scan finished (up to ino=%llu, found=%@)",identifier,(unsigned long long)upper,found.allKeys);
        return nil;
    }
}
+ (BOOL)openApplication:(NSString *)identifier {
    if (![GXAllowedApplications() containsObject:identifier]) return NO;
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW|RTLD_LOCAL);
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    if (![workspace respondsToSelector:@selector(defaultWorkspace)]) return NO;
    id shared = [workspace defaultWorkspace];
    return [shared respondsToSelector:@selector(openApplicationWithBundleID:)] &&
           [shared openApplicationWithBundleID:identifier];
}
@end
