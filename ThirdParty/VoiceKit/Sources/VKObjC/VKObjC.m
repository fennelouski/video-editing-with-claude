//
//  VKObjC.m
//  VKObjC
//

#import "VKObjC.h"

NSErrorDomain const VKObjCExceptionErrorDomain = @"VKObjCExceptionErrorDomain";
NSString *const VKObjCExceptionNameKey = @"VKObjCExceptionName";

BOOL VKCatchException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"Objective-C exception";
            info[VKObjCExceptionNameKey] = exception.name ?: @"NSException";
            *error = [NSError errorWithDomain:VKObjCExceptionErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
