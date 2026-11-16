import UIKit

/// The text probe: one editable field and a readout of exactly what it holds.
/// It answers whether text entry (HID typing or an accessibility set-value)
/// reached a real UIKit text field, code point for code point. It is separate
/// from the touch probe: the field is a subview of the touch surface, so
/// touches inside its frame go to the field and are not recorded as touches.
@MainActor
final class ProbeTextProbe: NSObject, UITextFieldDelegate {
    static let fieldIdentifier = "probe.text.field"
    static let valueIdentifier = "probe.text.value"

    let field = UITextField()
    let readout: ProbeReadoutElement
    /// Changes the field reported, by any route (typing, paste, set-value).
    private(set) var edits = 0

    init(container: UIView) {
        readout = ProbeReadoutElement(accessibilityContainer: container)
        super.init()
        field.accessibilityIdentifier = Self.fieldIdentifier
        field.accessibilityLabel = "Probe text field"
        field.placeholder = "text probe"
        field.borderStyle = .roundedRect
        field.backgroundColor = .darkGray
        field.textColor = .white
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        // No on-screen keyboard: it would cover the field (an accessibility
        // set-value makes the field first responder), and a covered field is
        // not visible, so later selector guards refuse it. Hardware keyboard
        // events (Manzanero's HID typing) still reach the first responder.
        field.inputView = UIView(frame: .zero)
        field.delegate = self
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        container.addSubview(field)

        readout.accessibilityIdentifier = Self.valueIdentifier
        readout.accessibilityLabel = "Probe text value"
        readout.accessibilityTraits = [.staticText, .updatesFrequently]
        readout.read = { [unowned self] in self.valueJSON }
    }

    @objc private func changed() { edits += 1 }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// `{"v":1,"text":…,"utf8":…,"scalars":…,"edits":…,"focused":…}`, keys sorted.
    var valueJSON: String {
        let text = field.text ?? ""
        let value: [String: Any] = ["v": 1, "text": text, "utf8": text.utf8.count, "scalars": text.unicodeScalars.count,
                                    "edits": edits, "focused": field.isFirstResponder]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
