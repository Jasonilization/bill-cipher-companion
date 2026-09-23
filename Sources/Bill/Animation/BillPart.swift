import Foundation

/// A single pixel-art sprite now stands in for what used to be a multi-node
/// vector rig (body/eye/hat/limbs as separate nodes) — each animation frame
/// is one fully-composited image. `BillPart` still exists as a thin wrapper
/// so `BillStateMachine`'s part-keyed dictionaries and settle/interrupt
/// logic didn't need to change, just what they iterate over.
enum BillPart: String, CaseIterable, Sendable, Hashable {
    case body
}
