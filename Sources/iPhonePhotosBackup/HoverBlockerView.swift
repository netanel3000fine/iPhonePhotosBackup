import SwiftUI
import AppKit

/// A transparent NSView overlay that absorbs mouse-entered/moved/exited events
/// so the underlying NSSegmentedControl never sees hover and therefore never
/// draws its hover-highlight state.  Left-click events are NOT consumed —
/// they fall through to the control below via hitTest returning nil.
class HoverBlockingNSView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove any inherited tracking areas so hover events stop here.
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { /* swallow */ }
    override func mouseMoved(with event: NSEvent)   { /* swallow */ }
    override func mouseExited(with event: NSEvent)  { /* swallow */ }

    // Pass clicks through so the Picker still works.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct HoverBlockerView: NSViewRepresentable {
    func makeNSView(context: Context) -> HoverBlockingNSView { HoverBlockingNSView() }
    func updateNSView(_ nsView: HoverBlockingNSView, context: Context) { }
}
