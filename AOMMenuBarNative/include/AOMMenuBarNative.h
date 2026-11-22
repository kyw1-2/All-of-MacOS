// AOM 7.10: macOS 27's menu bar visibility restriction (MenuBarClientCore,
// the allow-list behind assessment mode). macOS 27 drops a status item that
// grows very wide, so the old "long divider" hiding no longer works; macOS
// itself hides every app not on the list and reflows the bar.
//
// Approach and the private class/selector names follow Hidden Bar's
// HBNativeVisibilityShim (MIT, © 2019 Dwarves Foundation, © 2026 Console
// Labs; see LICENSE-HiddenBar.txt). Objective-C so an exception from a
// changed private API is caught instead of crashing AOM.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The framework, both classes and every selector resolve.
BOOL AOMMenuBarNativeIsAvailable(void);

/// Keeps only these system items and apps visible. The completion runs on
/// the main queue with the assertion to hold, or an error.
void AOMMenuBarNativeActivate(NSArray<NSNumber *> *allowedSystemItems,
                              NSArray<NSString *> *allowedBundleIdentifiers,
                              void (^completion)(id _Nullable assertion, NSError * _Nullable error));

void AOMMenuBarNativeInvalidate(id assertion);

NS_ASSUME_NONNULL_END
