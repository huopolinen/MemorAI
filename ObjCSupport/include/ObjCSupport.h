#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C `NSException` it raises and converting
/// it to an `NSError` (domain "ObjCException"). Returns `nil` on success.
///
/// Swift's `do/try/catch` only handles `Error` values — it cannot catch the
/// `NSException`s that AVFoundation/AVAudioEngine raise for invalid state (e.g.
/// `installTap` format mismatches). An uncaught `NSException` calls `abort()` and
/// kills the whole process. Wrap such calls in this shim to turn them into
/// recoverable Swift errors.
NSError * _Nullable objc_tryCatch(__attribute__((noescape)) void (^block)(void));

NS_ASSUME_NONNULL_END
