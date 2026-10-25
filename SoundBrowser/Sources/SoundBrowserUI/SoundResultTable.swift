import SwiftUI
import AppKit
import SoundBrowserCore

/// AppKit owns selection and keyboard navigation. Immutable row snapshots are
/// applied on the next main-queue turn, never from a table delegate callback.
struct SoundResultTable: NSViewRepresentable {
    struct Row: Equatable {
        let id, title, subtitle, duration: String
        let peaks: [Float]
    }
    let rows: [Row]
    let selection: String?
    let select: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select:select) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.identifier = .init("soundResultsTable")
        table.setAccessibilityLabel("Sound results")
        table.headerView = nil; table.rowHeight = 58; table.intercellSpacing = .zero
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let title = NSTableColumn(identifier:.init("title"));title.width = 300;title.minWidth = 140
        let envelope = NSTableColumn(identifier:.init("envelope"));envelope.width = 90;envelope.minWidth = 90;envelope.maxWidth = 90
        let duration = NSTableColumn(identifier:.init("duration"));duration.width = 72;duration.minWidth = 72;duration.maxWidth = 72
        for column in [title,envelope,duration] { table.addTableColumn(column) }
        table.delegate = context.coordinator;table.dataSource = context.coordinator
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.documentView = table
        scroll.autohidesScrollers = true;scroll.drawsBackground = true
        table.autoresizingMask = [.width]
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.select = select
        context.coordinator.schedule(rows:rows,selection:selection)
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        var rows: [Row] = []
        var select: (String?) -> Void
        var generation = 0, applying = false
        init(select:@escaping (String?) -> Void) { self.select = select }
        func schedule(rows: [Row], selection: String?) {
            generation += 1;let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, let table = self.table else { return }
                self.applying = true;defer { self.applying = false }
                if self.rows != rows { self.rows = rows;table.reloadData() }
                let index = rows.firstIndex(where: { $0.id == selection })
                let expected = index.map { IndexSet(integer:$0) } ?? IndexSet()
                if table.selectedRowIndexes != expected { table.selectRowIndexes(expected,byExtendingSelection:false) }
                let available = max(140,table.bounds.width-162)
                table.tableColumns.first?.width = available
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column else { return nil }
            let value = rows[row]
            if column.identifier.rawValue == "envelope" { return PeakView(peaks:value.peaks) }
            if column.identifier.rawValue == "duration" {
                let label = NSTextField(labelWithString:value.duration)
                label.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);label.alignment = .right
                label.textColor = .secondaryLabelColor
                let cell = NSTableCellView();cell.addSubview(label);label.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-10),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
                return cell
            }
            let name = NSTextField(labelWithString:value.title), subtitle = NSTextField(labelWithString:value.subtitle)
            name.font = .systemFont(ofSize:13,weight:.medium);name.lineBreakMode = .byTruncatingTail
            subtitle.font = .systemFont(ofSize:11);subtitle.textColor = .secondaryLabelColor
            let stack = NSStackView(views:[name,subtitle]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 5
            let cell = NSTableCellView();cell.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:9),stack.trailingAnchor.constraint(lessThanOrEqualTo:cell.trailingAnchor,constant:-8),stack.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            cell.setAccessibilityLabel("\(value.title), \(value.duration), \(value.subtitle)")
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table, rows.indices.contains(table.selectedRow) else { return }
            let id = rows[table.selectedRow].id
            DispatchQueue.main.async { [weak self] in self?.select(id) }
        }
        func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? { rows.indices.contains(row) ? rows[row].title : nil }
    }
}

private final class PeakView: NSView {
    let peaks: [Float]
    init(peaks:[Float]) { self.peaks = peaks;super.init(frame:.zero);setAccessibilityLabel(peaks.isEmpty ? "Envelope unavailable" : "Measured original WAV envelope") }
    required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        guard !peaks.isEmpty else {
            let dash = NSBezierPath();dash.move(to:.init(x:8,y:bounds.midY));dash.line(to:.init(x:bounds.width-8,y:bounds.midY));NSColor.tertiaryLabelColor.setStroke();dash.stroke();return
        }
        let p = NSBezierPath();let width = bounds.width-8
        for (index,value) in peaks.enumerated() {
            let x = 4+(CGFloat(index)+0.5)*width/CGFloat(peaks.count),height = max(1,CGFloat(value)*30)
            p.move(to:.init(x:x,y:bounds.midY-height/2));p.line(to:.init(x:x,y:bounds.midY+height/2))
        }
        NSColor.labelColor.setStroke();p.lineWidth = max(0.65,width/CGFloat(peaks.count)*0.65);p.stroke()
    }
}
