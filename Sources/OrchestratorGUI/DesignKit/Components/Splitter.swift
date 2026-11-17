import AppKit
import SwiftUI

/// A 5 pt vertical drag handle. `size` is the width of the pane before it. Hover brightens the line and shows the resize cursor.
struct KitSplitter: View {
    @Binding var size: Double
    let range: ClosedRange<Double>
    var forced: KitState?
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        let hover = forced == .hover || hovering
        Rectangle()
            .fill(hover ? Ink.borderStrong : Ink.border)
            .frame(width: Metric.splitter)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .kitAnimation(.hover, value: hover)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        let origin = start ?? size
                        start = origin
                        size = min(max(origin + drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}
