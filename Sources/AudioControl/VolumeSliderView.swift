import AppKit

/// Menu item view: "Volume" slider (0–100%) with a percentage label, reporting every change while dragging.
final class VolumeSliderView: NSView {
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private let onChange: (Int) -> Void

    init(percent: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: Double(percent), minValue: 0, maxValue: 100, target: nil, action: nil)
        valueLabel = NSTextField(labelWithString: "\(percent)%")
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))

        let title = NSTextField(labelWithString: "Volume")
        title.frame = NSRect(x: 20, y: 5, width: 56, height: 18)
        slider.frame = NSRect(x: 76, y: 4, width: 132, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        valueLabel.frame = NSRect(x: 212, y: 5, width: 40, height: 18)
        valueLabel.alignment = .right
        for label in [title, valueLabel] {
            label.font = .menuFont(ofSize: 0)
        }
        valueLabel.textColor = .secondaryLabelColor
        [title, slider, valueLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Updates the displayed value without reporting a change.
    func setPercent(_ percent: Int) {
        slider.doubleValue = Double(percent)
        valueLabel.stringValue = "\(percent)%"
    }

    @objc private func sliderChanged() {
        let percent = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(percent)%"
        onChange(percent)
    }
}
