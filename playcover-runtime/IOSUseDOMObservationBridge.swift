import Foundation

@objc(IOSUseDOMObservationBridge)
final class IOSUseDOMObservationBridge: NSObject {
    private static let store = SemanticDOM.Store()

    @objc static func reset() { store.reset() }

    @objc(observe:app:width:height:diff:since:)
    static func observe(_ elements: [[String: Any]], app: String, width: Double, height: Double,
                        diff: Bool, since: String) -> String {
        let nodes = elements.map {
            SemanticDOM.Element(label: $0["label"] as? String ?? "",
                accessibilityLabel: $0["accessibilityLabel"] as? String ?? "",
                value: $0["value"] as? String ?? "", hint: $0["hint"] as? String ?? "",
                traits: $0["traits"] as? [String] ?? [], children: $0["children"] as? Int ?? 0,
                rect: $0["rect"] as? [Double] ?? [])
        }
        let observation = store.observe(app: app, size: [width, height], elements: nodes,
                                        diff: diff, since: since)
        // Only strings, booleans and integer offsets are encoded here.
        return String(decoding: try! JSONEncoder().encode(observation), as: UTF8.self)
    }
}
