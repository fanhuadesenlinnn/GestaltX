// SPDX-License-Identifier: GPL-3.0-only
// LaunchServices database discovery lookup researched using WQ Files.
// https://github.com/kolbicz/WQFiles (reference only; independently implemented).
// Database and app bundles are read only; snapshot writes live elsewhere.
#import "GXLaunchServicesDatabase.h"
#import "GXCustomizationAccess.h"
#import "worse_query.h"
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/fsgetpath.h>
#include <fcntl.h>
#include <unistd.h>

#import "GXLaunchServicesParser.h"
static NSDictionary<NSString *,NSData *> *GXLSRawBundles;
static NSDictionary *GXLSSystemNames(void) {
    return @{@"com.apple.Music":@"Music",@"com.apple.mobilephone":@"Phone",@"com.apple.mobileslideshow":@"Photos",@"com.apple.camera":@"Camera",@"com.apple.MobileSMS":@"Messages",@"com.apple.mobilemail":@"Mail",@"com.apple.mobilesafari":@"Safari",@"com.apple.Preferences":@"Settings",@"com.apple.AppStore":@"App Store",@"com.apple.mobilenotes":@"Notes",@"com.apple.mobiletimer":@"Clock",@"com.apple.mobilecal":@"Calendar",@"com.apple.Maps":@"Maps",@"com.apple.reminders":@"Reminders",@"com.apple.Health":@"Health",@"com.apple.Passbook":@"Wallet",@"com.apple.facetime":@"FaceTime",@"com.apple.DocumentsApp":@"Files",@"com.apple.findmy":@"Find My",@"com.apple.Home":@"Home",@"com.apple.shortcuts":@"Shortcuts",@"com.apple.calculator":@"Calculator",@"com.apple.iBooks":@"Books",@"com.apple.weather":@"Weather",@"com.apple.VoiceMemos":@"Voice Memos",@"com.apple.podcasts":@"Podcasts",@"com.apple.tv":@"TV",@"com.apple.MobileAddressBook":@"Contacts",@"com.apple.Passwords":@"Passwords",@"com.apple.Translate":@"Translate",@"com.apple.Fitness":@"Fitness",@"com.apple.journal":@"Journal",@"com.apple.measure":@"Measure",@"com.apple.freeform":@"Freeform",@"com.apple.Bridge":@"Watch",@"com.apple.stocks":@"Stocks"};
}

static NSString *GXLSNormalized(NSString *path) {
    return [path hasPrefix:@"/var/"] ? [@"/private" stringByAppendingString:path] : path;
}
static NSString *GXLSStoreContainer(NSString *path) {
    NSString *root=@"/private/var/mobile/Containers/Data/InternalDaemon/";
    if(![path isKindOfClass:NSString.class]||![path hasPrefix:root])return nil;
    NSArray *parts=[[path substringFromIndex:root.length]componentsSeparatedByString:@"/"];
    if(parts.count!=4||![[NSUUID alloc]initWithUUIDString:parts[0]]||![parts[1]isEqual:@"Library"]||![parts[2]isEqual:@"Caches"]||
       ![parts[3]hasPrefix:@"com.apple.LaunchServices-"]||![parts[3]hasSuffix:@".csstore"])return nil;
    return [root stringByAppendingString:parts[0]];
}
static BOOL GXLSBundlePath(NSString *path) {
    if(![path isKindOfClass:NSString.class]||[path.pathComponents containsObject:@".."]||[path.pathComponents containsObject:@"."]||![path.pathExtension isEqual:@"app"])return NO;
    for(NSString *root in @[@"/Applications/",@"/System/Applications/"])
        if([path hasPrefix:root]&&[[path substringFromIndex:root.length]pathComponents].count==1)return YES;
    NSString *root=@"/private/var/containers/Bundle/Application/";
    if(![path hasPrefix:root])return NO;
    NSArray *parts=[[path substringFromIndex:root.length]componentsSeparatedByString:@"/"];
    return parts.count==2&&[[NSUUID alloc]initWithUUIDString:parts[0]]!=nil;
}
static NSData *GXLSRead(NSString *path, NSUInteger limit) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;
    struct stat before,after;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_size<=0||(uint64_t)before.st_size>limit){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t position=0;
    while(position<data.length){ssize_t n=read(fd,(uint8_t *)data.mutableBytes+position,data.length-position);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);return nil;}position+=(size_t)n;}
    BOOL unchanged=fstat(fd,&after)==0&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&
        before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec;
    close(fd);return unchanged?data:nil;
}
static NSString *GXLSFindStore(void) {
    NSString *probe=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int fd=open(probe.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
    struct stat info;struct statfs volume;BOOL valid=fd>=0&&fstat(fd,&info)==0&&fstatfs(fd,&volume)==0;
    if(fd>=0){close(fd);unlink(probe.fileSystemRepresentation);}
    if(!valid||(uint64_t)info.st_ino>UINT64_MAX-100000)return nil;
    uint64_t upper=(uint64_t)info.st_ino+100000;
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+20;char buffer[4096];
    // Like WQ Files, look at the newest inodes first: installing an app rewrites this database.
    for(uint64_t inode=upper;inode>0;inode--){
        if(!(inode%1024)&&CFAbsoluteTimeGetCurrent()>deadline)break;
        if(fsgetpath(buffer,sizeof(buffer),&volume.f_fsid,inode)<=0)continue;
        const char *file=strrchr(buffer,'/');if(!file||strncmp(file+1,"com.apple.LaunchServices-",25))continue;
        NSString *path=GXLSNormalized([NSString stringWithUTF8String:buffer]);
        if(GXLSStoreContainer(path))return path;
    }
    return nil;
}
static NSDictionary<NSString *,NSDictionary *> *GXLSApps;
static NSString *GXLSSignature;
@implementation GXLaunchServicesDatabase
+ (NSDictionary<NSString *,NSDictionary *> *)applications:(BOOL)discover {
    @synchronized(self){
        NSString *key=@"GestaltX.launch.database",*path=[NSUserDefaults.standardUserDefaults stringForKey:key];
        NSString *container=GXLSStoreContainer(path);
        if(!container&&discover){path=GXLSFindStore();container=GXLSStoreContainer(path);}
        if(!container)return GXLSApps?:@{};
        int64_t lease=[GXCustomizationAccess acquirePath:container];
        @try {
            struct stat attributes;
            if(lstat(path.fileSystemRepresentation,&attributes)||!S_ISREG(attributes.st_mode)||attributes.st_size<0x1000||attributes.st_size>64*1024*1024){
                [NSUserDefaults.standardUserDefaults removeObjectForKey:key];return @{};
            }
            NSString *signature=[NSString stringWithFormat:@"%@:%llu:%lld:%lld:%ld",path,(unsigned long long)attributes.st_ino,(long long)attributes.st_size,
                                  (long long)attributes.st_mtimespec.tv_sec,attributes.st_mtimespec.tv_nsec];
            if([signature isEqual:GXLSSignature])return GXLSApps?:@{};
            NSData *data=GXLSRead(path,64*1024*1024);
            NSDictionary *display=nil,*names=nil,*containers=nil,*bundles=nil;
            GXLaunchServicesSnapshot *snapshot=data?[GXLaunchServicesParser decode:data]:nil;
            if(!snapshot)return @{};
            display=snapshot.displayNames;names=snapshot.names;containers=snapshot.containers;bundles=snapshot.bundles;GXLSRawBundles=snapshot.records;
            NSMutableDictionary *apps=NSMutableDictionary.new;
            [bundles enumerateKeysAndObjectsUsingBlock:^(NSString *bid,NSString *bundle,BOOL *stop){
                if(!GXLSBundlePath(bundle))return;
                apps[bid]=[@{@"bundle":bundle,@"name":display[bid]?:GXLSSystemNames()[bid]?:names[bid]?:bundle.lastPathComponent.stringByDeletingPathExtension}mutableCopy];
            }];
            [containers enumerateKeysAndObjectsUsingBlock:^(NSString *folder,NSString *bid,BOOL *stop){
                if(![folder hasPrefix:@"/private/var/mobile/Containers/Data/Application/"])return;
                NSMutableDictionary *item=apps[bid];if(!item)return;
                struct stat attributes;
                if(lstat(folder.fileSystemRepresentation,&attributes)&&errno==ENOENT)return;
                if(!item[@"container"])item[@"container"]=folder;
            }];
            GXLSApps=[apps copy];GXLSSignature=signature;
            [NSUserDefaults.standardUserDefaults setObject:path forKey:key];
            return GXLSApps;
        } @finally {if(lease>=0)worse_query_release(lease);}
    }
}
+ (NSDictionary<NSString *,NSNumber *> *)sizesCalibratedWith:(NSDictionary<NSString *,NSNumber *> *)known {
    @synchronized(self){
        // Derive the usage field from multiple values supplied by LaunchServices.
        // An unknown layout simply has no size hint; never guess a record offset.
        NSMutableDictionary<NSNumber *,NSNumber *> *votes=NSMutableDictionary.new;
        for(NSString *bid in known){
            NSData *record=GXLSRawBundles[bid];uint64_t expected=[known[bid]unsignedLongLongValue];
            if(!record||expected<1024*1024)continue;
            const uint8_t *bytes=record.bytes;
            for(NSUInteger offset=0;offset+8<=record.length;offset+=4){
                uint64_t value;memcpy(&value,bytes+offset,8);
                if(value==expected)votes[@(offset)]=@([votes[@(offset)]unsignedIntegerValue]+1);
            }
        }
        NSNumber *chosen=nil;NSUInteger best=1;BOOL ambiguous=NO;
        for(NSNumber *offset in votes){NSUInteger count=[votes[offset]unsignedIntegerValue];
            if(count>best){chosen=offset;best=count;ambiguous=NO;}else if(count==best)ambiguous=YES;
        }
        if(!chosen||ambiguous)return @{};
        NSMutableDictionary *sizes=NSMutableDictionary.new;
        for(NSString *bid in GXLSRawBundles){NSData *record=GXLSRawBundles[bid];NSUInteger offset=chosen.unsignedIntegerValue;
            if(offset+8>record.length)continue;uint64_t value;memcpy(&value,(const uint8_t *)record.bytes+offset,8);
            if(value>0&&value<=1024ULL*1024*1024*1024)sizes[bid]=@(value);
        }
        return sizes;
    }
}
@end
