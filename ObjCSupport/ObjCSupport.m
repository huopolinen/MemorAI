#import "ObjCSupport.h"

NSError * _Nullable objc_tryCatch(__attribute__((noescape)) void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"Objective-C exception";
        if (exception.name) {
            info[@"ExceptionName"] = exception.name;
        }
        return [NSError errorWithDomain:@"ObjCException" code:0 userInfo:info];
    }
}
