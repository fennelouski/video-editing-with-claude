import Foundation
import CoreGraphics
import CoreText

struct HandoffReport: Sendable {
    struct Section: Sendable { var title: String; var text: String }
    var title: String
    var subtitle: String
    var sections: [Section]
}

actor HandoffExportService {
    func export(_ report: HandoffReport, project: Project, version: CutVersion) throws -> URL {
        try ProjectRepository.validateDrive(project.folder)
        let folder = project.folder.appendingPathComponent("exports")
        guard folder.resolvingSymlinksInPath().path.hasPrefix(project.folder.resolvingSymlinksInPath().path + "/") else { throw ProjectFailure.invalidProject }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = UUID().uuidString
        let temporary = folder.appendingPathComponent(".handoff-\(suffix).tmp")
        let final = folder.appendingPathComponent("\(version.folderName)-script-shot-list-\(suffix.prefix(8)).pdf")
        let bytes = try Self.render(report)
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }

    static func render(_ report: HandoffReport) throws -> Data {
        let content = NSMutableAttributedString(string: "")
        var paragraphSpace: CGFloat = 8
        let paragraph = withUnsafePointer(to: &paragraphSpace) { pointer in
            var setting = CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        func append(_ text: String, size: CGFloat, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            content.append(NSAttributedString(string: text + "\n", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
            ]))
        }
        append(report.title, size: 22, bold: true)
        append(report.subtitle, size: 10)
        for section in report.sections {
            append(section.title, size: 15, bold: true)
            append(section.text, size: 11)
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw ProjectFailure.invalidProject }
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &page,
                                      [kCGPDFContextTitle: report.title, kCGPDFContextCreator: "Clauto Editor"] as CFDictionary) else { throw ProjectFailure.invalidProject }
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        var index = 0, number = 1
        while index < content.length {
            guard number <= 250 else { throw WorkflowFailure.invalid("This handoff is too long to export. Split the project before retrying.") }
            context.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: 42, y: 58, width: 528, height: 676), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: index, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw WorkflowFailure.invalid("The handoff text could not fit on the page.") }
            index += visible.length
            let footer = NSAttributedString(string: "Clauto Editor  |  Page \(number)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 9, nil),
            ])
            context.textPosition = CGPoint(x: 42, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage()
            number += 1
        }
        context.closePDF()
        return data as Data
    }
}
