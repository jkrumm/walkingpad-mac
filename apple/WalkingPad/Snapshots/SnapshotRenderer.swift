#if SNAPSHOT_HARNESS
  import AppKit
  import SwiftUI

  /// A window that stays where it is put: AppKit pulls a window that is entirely off screen back.
  private final class OffscreenWindow: NSWindow {
    /// Key, so controls draw in their active colours (a prominent button is grey in a window that is
    /// not key).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
      frameRect
    }
  }

  /// Draws a SwiftUI view in a real, never shown window far off screen and reads it back as a 2x
  /// PNG. A window, not `ImageRenderer`, because only AppKit draws the controls (Button, Stepper,
  /// TextField, the hotkey recorder). No Screen Recording permission: the app reads its own views.
  @MainActor
  struct SnapshotRenderer {
    static let scale: CGFloat = 2

    let window: NSWindow
    let isPopover: Bool

    init(
      content: AnyView, width: CGFloat, height fixedHeight: CGFloat? = nil, isPopover: Bool,
      dark: Bool, title: String = "WalkingPad Settings"
    ) {
      self.isPopover = isPopover
      let host = NSHostingController(rootView: content)
      host.sizingOptions = []
      let fitting = NSHostingView(rootView: content)
      fitting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
      let height = fixedHeight ?? ceil(fitting.fittingSize.height)
      let style: NSWindow.StyleMask = isPopover ? [.borderless] : [.titled, .closable]
      window = OffscreenWindow(
        contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: style,
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.title = title
      window.contentViewController = host
      window.setContentSize(NSSize(width: width, height: height))
      window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
      if isPopover {
        window.isOpaque = false
        window.backgroundColor = .clear
      }
    }

    /// For a window the frame view, which includes the title bar.
    private var captured: NSView {
      guard !isPopover, let frame = window.contentView?.superview else {
        return window.contentView ?? NSView()
      }
      return frame
    }

    /// Lets SwiftUI lay out and run `.task` and `onAppear` work.
    func settle(_ milliseconds: Int = 400) async {
      NSApplication.shared.activate()
      window.makeKeyAndOrderFront(nil)
      try? await Task.sleep(for: .milliseconds(milliseconds))
      window.contentView?.layoutSubtreeIfNeeded()
      captured.displayIfNeeded()
    }

    func png() -> Data? {
      let view = captured
      view.layoutSubtreeIfNeeded()
      let bounds = view.bounds
      guard bounds.width > 0, bounds.height > 0,
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * Self.scale),
          pixelsHigh: Int(bounds.height * Self.scale), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0)
      else { return nil }
      rep.size = bounds.size
      view.cacheDisplay(in: bounds, to: rep)
      return rep.representation(using: .png, properties: [:])
    }

    func close() {
      window.contentViewController = nil
      window.close()
    }
  }
#endif
