import Foundation
import AVFoundation
for path in CommandLine.arguments.dropFirst() {
 do {
  let file=try AVAudioFile(forReading:URL(fileURLWithPath:path))
  guard let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else { fatalError("buffer") }
  try file.read(into:buffer)
  print("nativeDecodedFrames=\(buffer.frameLength)")
 } catch { print("nativeDecodeUnavailable=\(error)") }
}
