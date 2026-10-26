import AppKit

func symbolButton(_ symbol: String, title: String, target: AnyObject?, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: target, action: action)
    button.bezelStyle = .texturedRounded; button.isBordered = false
    button.toolTip = title; button.setAccessibilityLabel(title)
    button.refusesFirstResponder = true
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
}

func label(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size); view.textColor = color
    view.lineBreakMode = .byTruncatingTail
    return view
}

func safeFrame(_ saved: NSRect?, size: NSSize) -> NSRect {
    let screens = NSScreen.screens
    let primary = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    var rect = saved ?? NSRect(x: primary.maxX - size.width - 70, y: primary.maxY - size.height - 90, width: size.width, height: size.height)
    let screen = screens.first { $0.visibleFrame.intersection(rect).width >= 100 && $0.visibleFrame.intersection(rect).height >= 100 }?.visibleFrame ?? primary
    rect.size.width = min(max(rect.width, 380), screen.width)
    rect.size.height = min(max(rect.height, 280), screen.height)
    rect.origin.x = min(max(rect.origin.x, screen.minX), screen.maxX - rect.width)
    rect.origin.y = min(max(rect.origin.y, screen.minY), screen.maxY - rect.height)
    return rect
}
