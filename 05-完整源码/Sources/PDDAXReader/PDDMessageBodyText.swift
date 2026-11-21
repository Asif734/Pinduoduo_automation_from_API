import Foundation

enum PDDMessageBodyText {
    static func sameAXTextFragments(_ left: String, _ right: String) -> Bool {
        left.components(separatedBy: "\n").sorted() == right.components(separatedBy: "\n").sorted()
    }

    /// Read receipts are UI metadata. Never apply this to customer-authored text.
    static func serviceBodyWithoutReadStatus(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !["已读", "未读"].contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func serviceStatusOnlyDifference(_ left: String, _ right: String) -> Bool {
        let body = serviceBodyWithoutReadStatus(left)
        return !body.isEmpty && body == serviceBodyWithoutReadStatus(right)
    }
}
