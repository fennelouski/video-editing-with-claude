//
//  ObjCException.swift
//  VoiceKit
//
//  Swift-facing wrapper over the VKObjC @try/@catch shim.
//

import Foundation
import VKObjC

/// Runs `body`, converting a raised Objective-C exception into a thrown Swift error.
///
/// Reach for this only where a framework raises instead of throwing — chiefly
/// `AVAudioNode.installTap(onBus:bufferSize:format:block:)`, which raises when the
/// format it is handed disagrees with the hardware. Unwrapped, that raise aborts the
/// whole process; here it becomes a failed session the caller can report or retry.
///
/// - Note: Catching an ObjC exception and carrying on is only safe because the calls
///   guarded here fail before they mutate anything. Do not widen this to arbitrary code.
public func catchingObjCException(_ body: () -> Void) throws {
    var error: NSError?
    guard VKCatchException(body, &error) else {
        throw error ?? NSError(
            domain: VKObjCExceptionErrorDomain, code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Objective-C exception"]
        )
    }
}
