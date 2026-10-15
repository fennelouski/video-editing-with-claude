import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct FrameReadConcurrencyTests {
    @Test func manyFrameCapturesKeepPipeDrainsAndOtherTasksResponsive() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try f.request(), count = min(48,max(24,ProcessInfo.processInfo.activeProcessorCount+4))
        if let marker = ProcessInfo.processInfo.environment["CLAUTO_FRAME_IO_PROBE_MARKER"] {
            try Data("Synthetic concurrent capture probe entered: \(count) jobs\n".utf8).write(to: URL(fileURLWithPath: marker),options: .withoutOverwriting)
        }
        async let output = ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),arguments: ["-c","import sys; sys.stdout.write('x'*350000); sys.stderr.write('y'*350000)"],timeout: .seconds(10)))
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let frame = try await ReviewFrameCaptureService().capture(request,project: f.project)
                    #expect(frame.request == request && frame.actualTime == .init(value: request.frame.presentationValue,timescale: 24000))
                    #expect(frame.width == 160 && frame.height == 90 && TranscriptSourceMap.sha(frame.png) == frame.pngSHA256)
                    return 1
                }
            }
            var total = 0
            for try await value in group { total += value }
            return total
        }
        let result = try await output
        #expect(completed == count && result.succeeded && result.output.count == 262_144 && result.error.count == 262_144)
    }
}
