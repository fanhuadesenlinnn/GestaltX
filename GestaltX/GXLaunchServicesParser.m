// SPDX-License-Identifier: GPL-3.0-only
// Read-only CSStore reader. Record layout facts were checked against WQ Files;
// the parser and its bounds checks are independently implemented here.
#import "GXLaunchServicesParser.h"

@implementation GXLaunchServicesSnapshot
@end

typedef struct {uint32_t bytes,identifier,name,display,container,bundle;} GXLSLayout;
static const GXLSLayout GXLSLayouts[]={
    {0x250,0x0c,0x6c,0x74,0x68,0},
    {0x23c,0x0c,0x68,0x70,0x64,0},
    {0x23c,0x0c,0x64,0x6c,0x60,0},
    {0x23c,0x08,0x64,0x6c,0x60,0},
    {0x25c,0x0c,0x70,0x78,0x6c,0},
    {0x25c,0x10,0x70,0x78,0x6c,4},
    {0x25c,0x0c,0x70,0x78,0x6c,4},
    {0x25c,0x10,0x70,0x78,0x6c,0}
};
static uint32_t GXLSWord(const uint8_t *p){uint32_t v;memcpy(&v,p,4);return CFSwapInt32LittleToHost(v);}
static NSString *GXLSString(uint32_t reference,NSDictionary<NSNumber *,NSString *> *strings){
    if(!(reference&1))return strings[@(reference>>2)];
    // CSStore packs short ASCII names into five 6-bit alphabet indices.
    // This is used by names such as QQ; it is not a string-table offset.
    static const char alphabet[]="\0 abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    char result[6]={0};NSUInteger count=0;uint32_t packed=reference>>2;
    while(packed&&count<5){uint32_t index=packed&63;if(!index)break;result[count++]=alphabet[index];packed>>=6;}
    for(NSUInteger i=0;i<count/2;i++){char c=result[i];result[i]=result[count-i-1];result[count-i-1]=c;}
    return count?[[NSString alloc]initWithBytes:result length:count encoding:NSASCIIStringEncoding]:nil;
}
static NSString *GXLSCanonical(NSString *s){return [s hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:s]:s;}
static BOOL GXLSIdentifier(NSString *s){
    if(s.length<3||s.length>255||![s containsString:@"."])return NO;
    NSCharacterSet *set=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._"];
    return [s rangeOfCharacterFromSet:set.invertedSet].location==NSNotFound;
}
static NSString *GXLSContainer(NSString *s){
    if([s hasSuffix:@"/"])s=[s substringToIndex:s.length-1];s=GXLSCanonical(s);
    NSString *root=@"/private/var/mobile/Containers/Data/Application/";
    if(![s hasPrefix:root]||![[NSUUID alloc]initWithUUIDString:[s substringFromIndex:root.length]])return nil;
    return s;
}
static NSString *GXLSBundle(NSString *s){
    if([s hasSuffix:@"/"])s=[s substringToIndex:s.length-1];s=GXLSCanonical(s);
    if(![s hasPrefix:@"/"]||![s.pathExtension isEqual:@"app"]||[s.pathComponents containsObject:@".."]||[s.pathComponents containsObject:@"."])return nil;
    return s;
}
static NSString *GXLSName(NSString *s){
    if(!s.length||s.length>256||[s hasPrefix:@"/"]||[s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSDictionary<NSString *,NSString *> *GXLSGroups(NSData *data) {
    id root=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    id values=[root isKindOfClass:NSDictionary.class]?root[@"__NO_PERSONA__"]:nil;
    if(![values isKindOfClass:NSDictionary.class]||[values count]>64)return nil;
    NSMutableDictionary *groups=NSMutableDictionary.new;
    NSString *prefix=@"/private/var/mobile/Containers/Shared/AppGroup/";
    for(id key in values){
        id raw=values[key];
        if(![key isKindOfClass:NSString.class]||!GXLSIdentifier(key)||![raw isKindOfClass:NSString.class])return nil;
        NSString *path=GXLSCanonical(raw);
        if([path hasSuffix:@"/"])path=[path substringToIndex:path.length-1];
        if(![path hasPrefix:prefix]||![[NSUUID alloc]initWithUUIDString:[path substringFromIndex:prefix.length]])return nil;
        groups[key]=path;
    }
    return groups;
}

@implementation GXLaunchServicesParser
+ (GXLaunchServicesSnapshot *)decode:(NSData *)data {
    const uint8_t *bytes=data.bytes;NSUInteger length=data.length;
    if(length<4096||length>64*1024*1024||memcmp(bytes,"bdsl",4))return nil;
    const NSUInteger layoutCount=sizeof(GXLSLayouts)/sizeof(GXLSLayouts[0]);
    NSMutableArray<NSMutableData *> *offsets=NSMutableArray.new;
    for(NSUInteger i=0;i<layoutCount;i++)[offsets addObject:NSMutableData.new];
    uint8_t *needed=calloc(1,0x1000000/8);if(!needed)return nil;
    NSMutableDictionary<NSNumber *,NSString *> *strings=NSMutableDictionary.new,*paths=NSMutableDictionary.new,*bundles=NSMutableDictionary.new;
    NSMutableSet<NSNumber *> *groupReferences=NSMutableSet.new,*ambiguousGroups=NSMutableSet.new;
    NSMutableDictionary<NSNumber *,NSDictionary *> *groups=NSMutableDictionary.new;
    NSMutableSet<NSNumber *> *conflictingPaths=NSMutableSet.new,*conflictingBundles=NSMutableSet.new,*heapStrings=NSMutableSet.new;
    @try {
        NSUInteger recordCount=0;
        for(NSUInteger p=0;p+8<=length;p+=4){
            uint32_t size=GXLSWord(bytes+p+4);
            if(size>length-p-8)continue;
            for(NSUInteger l=0;l<layoutCount;l++){
                const GXLSLayout *layout=&GXLSLayouts[l];if(size!=layout->bytes)continue;
                const uint8_t *body=bytes+p+8;uint32_t fields[]={layout->identifier,layout->name,layout->display,layout->container,layout->bundle};
                uint32_t idref=GXLSWord(body+fields[0]);if(!idref||(idref&1)||(idref>>2)>=0x1000000)continue;
                if(++recordCount>100000)return nil;
                uint32_t position=(uint32_t)(p+8);[offsets[l]appendBytes:&position length:4];
                for(NSUInteger f=0;f<5;f++){uint32_t ref=GXLSWord(body+fields[f]);if(ref&&!(ref&1)&&(ref>>2)<0x1000000)needed[(ref>>2)/8]|=1<<((ref>>2)%8);}
                // Group-map offsets differ between the phone's cache and the
                // 27.2 consumer. Accept only an unambiguous, validated map at
                // either observed field; never infer ownership from group names.
                for(uint32_t delta=0x1c;delta<=0x20;delta+=4){
                    uint32_t group=GXLSWord(body+layout->display+delta);
                    if(group&&!(group&1)&&(group>>2)<0x1000000)[groupReferences addObject:@(group>>2)];
                }
            }
        }
        NSRange marker=[data rangeOfData:[NSData dataWithBytes:"<string>" length:8]options:0 range:NSMakeRange(0,length)];
        NSUInteger heap=marker.location==NSNotFound?length:marker.location,totalCharacters=0;
        for(NSUInteger p=0;p+8<=length;p+=4){
            uint32_t sid=GXLSWord(bytes+p);if(!sid||sid>=0x1000000)continue;
            if([groupReferences containsObject:@(sid)]){
                uint32_t size=GXLSWord(bytes+p+4);
                if(size>=40&&size<=64*1024&&size<=length-p-8&&!memcmp(bytes+p+8,"bplist00",8)){
                    NSDictionary *map=GXLSGroups([data subdataWithRange:NSMakeRange(p+8,size)]);
                    if(map.count){
                        if(groups[@(sid)]&&![groups[@(sid)]isEqual:map])[ambiguousGroups addObject:@(sid)];
                        else groups[@(sid)]=map;
                    }
                }
            }
            if(!(needed[sid/8]&(1<<(sid%8))))continue;
            uint32_t count=GXLSWord(bytes+p+4);if(!count||count>=2048||count>=length-p-8||memchr(bytes+p+8,0,count)||(count%4&&bytes[p+8+count]!=0))continue;
            NSNumber *key=@(sid);BOOL fromHeap=p>=heap;
            if(strings[key]&&(!fromHeap||[heapStrings containsObject:key])&&bytes[p+8]!='/')continue;
            NSString *value=[[NSString alloc]initWithBytes:bytes+p+8 length:count encoding:NSUTF8StringEncoding];if(!value)continue;
            NSString *container=GXLSContainer(value),*bundle=GXLSBundle(value);
            if(container){if(paths[key]&&![paths[key]isEqual:container])[conflictingPaths addObject:key];else paths[key]=container;}
            if(bundle){if(bundles[key]&&![bundles[key]isEqual:bundle])[conflictingBundles addObject:key];else bundles[key]=bundle;}
            if(!strings[key]||(fromHeap&&![heapStrings containsObject:key])){
                totalCharacters+=value.length;if(strings.count>=200000||totalCharacters>8*1024*1024)return nil;
                strings[key]=value;if(fromHeap)[heapStrings addObject:key];
            }
        }
        [paths removeObjectsForKeys:conflictingPaths.allObjects];[bundles removeObjectsForKeys:conflictingBundles.allObjects];
        [groups removeObjectsForKeys:ambiguousGroups.allObjects];
        GXLaunchServicesSnapshot *best=nil;NSUInteger bestScore=0;
        for(NSUInteger l=0;l<layoutCount;l++){
            const GXLSLayout *layout=&GXLSLayouts[l];const uint32_t *positions=offsets[l].bytes;
            NSMutableDictionary *names=NSMutableDictionary.new,*display=NSMutableDictionary.new,*containers=NSMutableDictionary.new,*appBundles=NSMutableDictionary.new,*raw=NSMutableDictionary.new;
            NSMutableDictionary *appGroups=NSMutableDictionary.new;
            for(NSUInteger r=0;r<offsets[l].length/4;r++){
                const uint8_t *body=bytes+positions[r];
                NSString *(^string)(uint32_t)=^NSString *(uint32_t field){return GXLSString(GXLSWord(body+field),strings);};
                NSString *bid=string(layout->identifier);if(!GXLSIdentifier(bid))continue;
                uint32_t cref=GXLSWord(body+layout->container),bref=GXLSWord(body+layout->bundle);
                NSString *container=!(cref&1)?paths[@(cref>>2)]:nil;
                NSString *bundle=!(bref&1)?bundles[@(bref>>2)]:nil;
                if(container){if(containers[container]&&![containers[container]isEqual:bid])containers[container]=@"";else containers[container]=bid;}
                NSString *name=GXLSName(string(layout->name)),*title=GXLSName(string(layout->display));
                if(name.length&&!names[bid])names[bid]=name;if(title.length&&!display[bid])display[bid]=title;
                if(bundle){appBundles[bid]=bundle;raw[bid]=[data subdataWithRange:NSMakeRange(positions[r],layout->bytes)];}
                NSDictionary *map=nil;BOOL conflict=NO;
                for(uint32_t delta=0x1c;delta<=0x20;delta+=4){
                    uint32_t group=GXLSWord(body+layout->display+delta);
                    NSDictionary *candidate=!(group&1)?groups[@(group>>2)]:nil;
                    if(candidate){if(map&&![map isEqual:candidate])conflict=YES;else map=candidate;}
                }
                if(bundle&&map&&!conflict)appGroups[bid]=map;
            }
            for(NSString *path in containers.allKeys)if(![containers[path]length])[containers removeObjectForKey:path];
            NSUInteger score=containers.count*1000+MIN(appBundles.count,999);
            if(score>bestScore){
                bestScore=score;best=GXLaunchServicesSnapshot.new;
                best.names=names;best.displayNames=display;best.containers=containers;best.bundles=appBundles;best.records=raw;
                best.groupContainers=appGroups;
            }
        }
        return best.containers.count>=2?best:nil;
    }@finally{free(needed);}
}
@end
