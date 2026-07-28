import Foundation

/// Named, independently-animatable parts of Bill's rig. Each maps to one
/// SKNode positioned relative to a fixed "home" transform defined by
/// `BillRigNode` — animation clips only ever specify *targets*, never deltas,
/// so replaying/looping a clip never drifts.
enum BillPart: String, CaseIterable, Sendable, Hashable {
    case body
    case eye
    case pupil
    case hat
    case bowtie
    case leftArm
    case rightArm
    case leftLeg
    case rightLeg
}
