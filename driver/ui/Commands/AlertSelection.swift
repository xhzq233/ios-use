import CoreGraphics
import Foundation

enum AlertSurface: String, Equatable {
    case springboard
    case activeApp
}

enum AlertKind: String, Equatable {
    case alert
    case sheet
}

enum AlertLayoutDirection: String, Equatable {
    case leftToRight
    case rightToLeft
}

enum AlertLayoutDirectionSource: String, Equatable {
    case runnerEffective
}

struct AlertButtonSnapshot: Equatable {
    let queryIndex: Int
    let label: String
    let identifier: String
    let isHittable: Bool
    let frame: CGRect
}

struct AlertSnapshot: Equatable {
    let surface: AlertSurface
    let kind: AlertKind
    let text: String
    let frame: CGRect
    let buttons: [AlertButtonSnapshot]
}

enum AlertButtonSelection: Equatable {
    case index(Int)
    case label(String)
    case onlyButton
    case visualPrimary

    var requestedStrategy: String {
        switch self {
        case .index: return "index"
        case .label: return "label"
        case .onlyButton: return "onlyButton"
        case .visualPrimary: return "visualPrimary"
        }
    }
}

struct AlertSelectionResolution: Equatable {
    let queryIndex: Int
    let strategy: String
    let layoutDirection: AlertLayoutDirection?
    let layoutDirectionSource: AlertLayoutDirectionSource?
}

enum AlertSelectionFailure: Error, Equatable {
    case noHittableButtons
    case invalidIndex(Int)
    case labelNotFound(String)
    case duplicateLabel(String, count: Int)
    case multipleHittableButtons(Int)
    case invalidVisualGeometry(index: Int)
    case unsupportedVisualCandidateCount(Int)
    case ambiguousVisualLayout

    var diagnostic: String {
        switch self {
        case .noHittableButtons:
            return "alert has no hittable buttons"
        case .invalidIndex(let index):
            return "alert has no hittable button at query index \(index)"
        case .labelNotFound(let label):
            return "alert has no unique button labeled \"\(label)\""
        case .duplicateLabel(let label, let count):
            return "alert has \(count) buttons labeled \"\(label)\""
        case .multipleHittableButtons(let count):
            return "\(count) hittable buttons require an explicit selection"
        case .invalidVisualGeometry(let index):
            return "button at query index \(index) has invalid geometry"
        case .unsupportedVisualCandidateCount(let count):
            return "visual primary is ambiguous for \(count) hittable buttons"
        case .ambiguousVisualLayout:
            return "button geometry does not resolve one visual primary action"
        }
    }
}

enum AlertSelectionEngine {
    private static let overlapThreshold = 0.6
    private static let centerTolerance: CGFloat = 1

    static func select(
        _ selection: AlertButtonSelection,
        in snapshot: AlertSnapshot,
        layoutDirection: AlertLayoutDirection,
        layoutDirectionSource: AlertLayoutDirectionSource = .runnerEffective
    ) -> Result<AlertSelectionResolution, AlertSelectionFailure> {
        switch selection {
        case .index(let requestedIndex):
            guard let button = snapshot.buttons.first(where: {
                $0.queryIndex == requestedIndex && $0.isHittable
            }) else {
                return .failure(.invalidIndex(requestedIndex))
            }
            return .success(AlertSelectionResolution(
                queryIndex: button.queryIndex,
                strategy: "index",
                layoutDirection: nil,
                layoutDirectionSource: nil
            ))

        case .label(let requestedLabel):
            let normalized = normalizeText(requestedLabel)
            let matches = snapshot.buttons.filter {
                $0.isHittable && normalizeText($0.label) == normalized
            }
            guard !matches.isEmpty else {
                return .failure(.labelNotFound(requestedLabel))
            }
            guard matches.count == 1 else {
                return .failure(.duplicateLabel(requestedLabel, count: matches.count))
            }
            return .success(AlertSelectionResolution(
                queryIndex: matches[0].queryIndex,
                strategy: "label",
                layoutDirection: nil,
                layoutDirectionSource: nil
            ))

        case .onlyButton:
            let hittable = snapshot.buttons.filter(\.isHittable)
            guard !hittable.isEmpty else {
                return .failure(.noHittableButtons)
            }
            guard hittable.count == 1 else {
                return .failure(.multipleHittableButtons(hittable.count))
            }
            return .success(AlertSelectionResolution(
                queryIndex: hittable[0].queryIndex,
                strategy: "onlyButton",
                layoutDirection: nil,
                layoutDirectionSource: nil
            ))

        case .visualPrimary:
            return selectVisualPrimary(
                in: snapshot,
                layoutDirection: layoutDirection,
                layoutDirectionSource: layoutDirectionSource
            )
        }
    }

    static func sameGeneration(
        _ lhs: AlertSnapshot,
        _ rhs: AlertSnapshot,
        frameTolerance: CGFloat = 2
    ) -> Bool {
        guard lhs.surface == rhs.surface,
              lhs.kind == rhs.kind,
              normalizeText(lhs.text) == normalizeText(rhs.text),
              approximatelyEqual(lhs.frame, rhs.frame, tolerance: frameTolerance),
              lhs.buttons.count == rhs.buttons.count else {
            return false
        }

        return zip(lhs.buttons, rhs.buttons).allSatisfy { left, right in
            left.queryIndex == right.queryIndex
                && normalizeText(left.label) == normalizeText(right.label)
                && normalizeText(left.identifier) == normalizeText(right.identifier)
                && approximatelyEqual(left.frame, right.frame, tolerance: frameTolerance)
        }
    }

    static func normalizeText(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    static func containsIdentity(_ identity: String, in text: String) -> Bool {
        let normalizedIdentity = normalizeText(identity)
        let normalizedText = normalizeText(text)
        guard !normalizedIdentity.isEmpty else { return false }

        var searchStart = normalizedText.startIndex
        while searchStart < normalizedText.endIndex,
              let range = normalizedText.range(
                  of: normalizedIdentity,
                  range: searchStart..<normalizedText.endIndex
              ) {
            let leftIsBoundary = range.lowerBound == normalizedText.startIndex
                || !isIdentityCharacter(normalizedText[normalizedText.index(before: range.lowerBound)])
            let rightIsBoundary = range.upperBound == normalizedText.endIndex
                || !isIdentityCharacter(normalizedText[range.upperBound])
            if leftIsBoundary && rightIsBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func selectVisualPrimary(
        in snapshot: AlertSnapshot,
        layoutDirection: AlertLayoutDirection,
        layoutDirectionSource: AlertLayoutDirectionSource
    ) -> Result<AlertSelectionResolution, AlertSelectionFailure> {
        let hittable = snapshot.buttons.filter(\.isHittable)
        guard !hittable.isEmpty else {
            return .failure(.noHittableButtons)
        }
        if let invalid = hittable.first(where: { !isValidFrame($0.frame) }) {
            return .failure(.invalidVisualGeometry(index: invalid.queryIndex))
        }
        guard hittable.count <= 2 else {
            return .failure(.unsupportedVisualCandidateCount(hittable.count))
        }
        guard hittable.count == 2 else {
            return .success(AlertSelectionResolution(
                queryIndex: hittable[0].queryIndex,
                strategy: "visualPrimaryHeuristic",
                layoutDirection: layoutDirection,
                layoutDirectionSource: layoutDirectionSource
            ))
        }

        let first = hittable[0]
        let second = hittable[1]
        let horizontal = overlapRatio(
            first.frame.minY,
            first.frame.maxY,
            second.frame.minY,
            second.frame.maxY
        ) >= overlapThreshold
        let vertical = overlapRatio(
            first.frame.minX,
            first.frame.maxX,
            second.frame.minX,
            second.frame.maxX
        ) >= overlapThreshold

        let selected: AlertButtonSnapshot
        if horizontal && !vertical {
            guard abs(first.frame.midX - second.frame.midX) > centerTolerance else {
                return .failure(.ambiguousVisualLayout)
            }
            switch layoutDirection {
            case .leftToRight:
                selected = first.frame.midX > second.frame.midX ? first : second
            case .rightToLeft:
                selected = first.frame.midX < second.frame.midX ? first : second
            }
        } else if vertical && !horizontal {
            guard abs(first.frame.midY - second.frame.midY) > centerTolerance else {
                return .failure(.ambiguousVisualLayout)
            }
            selected = first.frame.midY < second.frame.midY ? first : second
        } else {
            return .failure(.ambiguousVisualLayout)
        }

        return .success(AlertSelectionResolution(
            queryIndex: selected.queryIndex,
            strategy: "visualPrimaryHeuristic",
            layoutDirection: layoutDirection,
            layoutDirectionSource: layoutDirectionSource
        ))
    }

    private static func overlapRatio(
        _ firstMin: CGFloat,
        _ firstMax: CGFloat,
        _ secondMin: CGFloat,
        _ secondMax: CGFloat
    ) -> CGFloat {
        let overlap = max(0, min(firstMax, secondMax) - max(firstMin, secondMin))
        let shorter = min(firstMax - firstMin, secondMax - secondMin)
        guard shorter > 0 else { return 0 }
        return overlap / shorter
    }

    private static func isValidFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func isIdentityCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "-"
            || character == "_"
    }
}
