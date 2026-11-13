#import <Foundation/Foundation.h>
#import "GXLaunchServicesParser.h"

static void word(NSMutableData *data,NSUInteger offset,uint32_t value){value=CFSwapInt32HostToLittle(value);memcpy((uint8_t *)data.mutableBytes+offset,&value,4);}
static void string(NSMutableData *data,NSUInteger *position,uint32_t sid,NSString *value){
    NSData *utf8=[value dataUsingEncoding:NSUTF8StringEncoding];word(data,*position,sid);word(data,*position+4,(uint32_t)utf8.length);
    [data replaceBytesInRange:NSMakeRange(*position+8,utf8.length)withBytes:utf8.bytes];*position+=8+((utf8.length+3)/4)*4;
}
static NSMutableData *fixture(void){
    NSMutableData *data=[NSMutableData dataWithLength:16384];memcpy(data.mutableBytes,"bdsl",4);memcpy((uint8_t *)data.mutableBytes+0x1800,"<string>",8);
    NSUInteger position=0x2000;
    for(uint32_t app=0;app<2;app++){
        NSUInteger record=0x100+app*0x300;uint32_t sid=1+app*10;
        word(data,record+4,0x250);word(data,record+8+0x00,sid<<2);word(data,record+8+0x0c,(sid+1)<<2);
        word(data,record+8+0x6c,(sid+2)<<2);word(data,record+8+0x74,(sid+3)<<2);word(data,record+8+0x68,(sid+4)<<2);
        NSString *uuid=app?@"00000000-0000-0000-0000-000000000002":@"00000000-0000-0000-0000-000000000001";
        string(data,&position,sid,[@"/private/var/containers/Bundle/Application/" stringByAppendingFormat:@"%@/Test.app",uuid]);
        string(data,&position,sid+1,app?@"test.second":@"test.first");
        string(data,&position,sid+2,app?@"二番目":@"Test");string(data,&position,sid+3,app?@"日本語":@"测试");
        string(data,&position,sid+4,[@"/var/mobile/Containers/Data/Application/" stringByAppendingString:uuid]);
    }
    return data;
}
int main(void){@autoreleasepool{
    NSMutableData *data=fixture();GXLaunchServicesSnapshot *result=[GXLaunchServicesParser decode:data];
    NSCAssert(result.containers.count==2&&result.bundles.count==2,@"App/container mapping failed");
    NSCAssert([result.displayNames[@"test.first"]isEqual:@"测试"]&&[result.displayNames[@"test.second"]isEqual:@"日本語"],@"Unicode names were lost");
    NSCAssert([result.bundles[@"test.first"]hasPrefix:@"/private/var/containers/Bundle/Application/"],@"A normal /private/var alias was filtered");
    NSCAssert([GXLaunchServicesParser decode:[NSData dataWithBytes:"bdsl" length:4]]==nil,@"Truncated store accepted");
    NSMutableData *packed=fixture();word(packed,0x100+8+0x6c,0x2cb1);word(packed,0x100+8+0x74,0x2cb1);
    GXLaunchServicesSnapshot *shortName=[GXLaunchServicesParser decode:packed];
    NSCAssert([shortName.displayNames[@"test.first"]isEqual:@"QQ"],@"Packed short app names were not decoded");
    NSMutableData *invalid=fixture();word(invalid,0x100+8+0x0c,0xfffffff0);word(invalid,0x400+8+0x0c,0xfffffff0);
    NSCAssert([GXLaunchServicesParser decode:invalid]==nil,@"Invalid string references accepted");
    NSMutableData *groupFixture=fixture();
    NSDictionary *groupMap=@{@"__NO_PERSONA__":@{@"group.test.notifications":@"/private/var/mobile/Containers/Shared/AppGroup/00000000-0000-0000-0000-000000000003"}};
    NSData *groupData=[NSPropertyListSerialization dataWithPropertyList:groupMap format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    word(groupFixture,0x100+8+0x90,1000<<2);word(groupFixture,0x2ff8,1000);word(groupFixture,0x2ffc,(uint32_t)groupData.length);
    [groupFixture replaceBytesInRange:NSMakeRange(0x3000,groupData.length)withBytes:groupData.bytes];
    GXLaunchServicesSnapshot *groupResult=[GXLaunchServicesParser decode:groupFixture];
    NSCAssert([groupResult.groupContainers[@"test.first"][@"group.test.notifications"]hasSuffix:@"000000000003"],@"App-group relationship was lost");
    NSCAssert(!groupResult.groupContainers[@"test.second"],@"A group was assigned to an unrelated app");
    NSDictionary *badMap=@{@"__NO_PERSONA__":@{@"group.test.notifications":@"/private/var/mobile/Library/Sounds"}};
    NSData *badData=[NSPropertyListSerialization dataWithPropertyList:badMap format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    word(groupFixture,0x2ffc,(uint32_t)badData.length);[groupFixture replaceBytesInRange:NSMakeRange(0x3000,badData.length)withBytes:badData.bytes];
    NSCAssert(![GXLaunchServicesParser decode:groupFixture].groupContainers[@"test.first"],@"An out-of-scope group path was accepted");
    word(data,0x100+4,UINT32_MAX);word(data,0x400+4,UINT32_MAX);
    NSCAssert([GXLaunchServicesParser decode:data]==nil,@"Out-of-bounds record sizes accepted");
    puts("PASS: app/container mapping, Unicode names, /private/var aliases and malformed store rejection.");
}}
