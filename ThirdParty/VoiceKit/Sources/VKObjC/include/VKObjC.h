//
//  VKObjC.h
//  VKObjC
//
//  The one thing Swift cannot do: catch an Objective-C exception.
//
//  AVAudioEngine's `installTapOnBus:` reports a bad format by *raising*, not by
//  returning an error, and a raise that reaches Swift is an uncatchable abort.
//  That is a crashed app, mid-sentence, with no way to intervene.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning any raised `NSException` into `NO` + an `NSError`.
///
/// Only for framework calls that raise instead of throwing. The exception's name,
/// reason, and userInfo are carried through so the failure is still diagnosable.
BOOL VKCatchException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

/// Domain of errors produced by `VKCatchException`.
extern NSErrorDomain const VKObjCExceptionErrorDomain;

/// `userInfo` key holding the raised exception's name.
extern NSString *const VKObjCExceptionNameKey;

NS_ASSUME_NONNULL_END
