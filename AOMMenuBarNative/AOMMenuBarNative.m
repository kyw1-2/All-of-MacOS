// See AOMMenuBarNative.h (approach after Hidden Bar's shim, MIT).
#import "AOMMenuBarNative.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const AOMFrameworkPath = @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const AOMConfigurationClass = @"MBAssessmentModeConfiguration";
static NSString *const AOMAssertionClass = @"MBAssessmentModeAssertion";

static NSError *AOMNativeError(NSString *reason) {
    return [NSError errorWithDomain:@"AOMMenuBarNative" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
}

BOOL AOMMenuBarNativeIsAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen(AOMFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) { available = NO; return; }
        Class configuration = NSClassFromString(AOMConfigurationClass);
        Class assertion = NSClassFromString(AOMAssertionClass);
        available = configuration && assertion
            && [configuration instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
            && [assertion instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
            && [assertion instancesRespondToSelector:@selector(invalidate)];
    });
    return available;
}

void AOMMenuBarNativeActivate(NSArray<NSNumber *> *allowedSystemItems,
                              NSArray<NSString *> *allowedBundleIdentifiers,
                              void (^completion)(id _Nullable assertion, NSError * _Nullable error)) {
    // 7.13 (Gemini 7.12.1 #3): the completion runs once, on the main queue.
    // A request macOS hasn't answered in 5 s fails open; an assertion that
    // arrives after that (or a second answer) is invalidated, never kept.
    __block BOOL done = NO; // read and written on the main queue only
    void (^finish)(id, NSError *) = ^(id assertion, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) {
                if (assertion) { AOMMenuBarNativeInvalidate(assertion); }
                return;
            }
            done = YES;
            completion(assertion, error);
        });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (done) { return; }
        done = YES;
        completion(nil, AOMNativeError(@"macOS didn't answer the menu bar request in 5 seconds"));
    });
    if (!AOMMenuBarNativeIsAvailable()) { finish(nil, AOMNativeError(@"MenuBarClientCore is unavailable")); return; }
    @try {
        // NSArrays, not sets: the framework indexes into them.
        id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [NSClassFromString(AOMConfigurationClass) alloc], @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:),
            [allowedSystemItems copy], [allowedBundleIdentifiers copy]);
        id assertion = [[NSClassFromString(AOMAssertionClass) alloc] init];
        if (!configuration || !assertion) { finish(nil, AOMNativeError(@"Could not create the restriction")); return; }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion, @selector(activateWithConfiguration:completionHandler:), configuration, ^(NSError *error) {
                finish(error ? nil : assertion, error);
            });
    } @catch (NSException *exception) {
        finish(nil, AOMNativeError([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]));
    }
}

void AOMMenuBarNativeInvalidate(id assertion) {
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
        }
    } @catch (NSException *exception) {
        NSLog(@"AOMMenuBarNative: invalidate raised %@: %@", exception.name, exception.reason);
    }
}
