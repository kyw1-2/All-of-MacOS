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
    void (^finish)(id, NSError *) = ^(id assertion, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(assertion, error); });
    };
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
