import SpriteKit

/// Which FX layer (if any) a state should show alongside its clip.
enum BillFX {
    case steam
    case sparkle
    case zzz
    case confettiAndSparkle
}

/// All of Bill's animation content: one clip per `BillState`, plus a small
/// pool of idle-variety beats. This is the "data, not code" layer the
/// architecture calls for — tuning a reaction means editing keyframes here,
/// never touching the state machine or renderer.
@MainActor
enum AnimationClipLibrary {

    static func clip(for state: BillState) -> AnimationClip {
        switch state {
        case .idle: return idle
        case .walking: return walking
        case .talking: return talking
        case .thinking: return thinking
        case .happy: return happy
        case .annoyed: return annoyed
        case .sleeping: return sleeping
        case .gaming: return gaming
        case .coding: return coding
        case .heatingUp: return heatingUp
        case .charging: return charging
        case .surprised: return surprised
        case .celebrating: return celebrating
        }
    }

    /// The prop Bill should be holding for a state (states not listed keep
    /// his default cane).
    static func prop(for state: BillState) -> BillProp {
        switch state {
        case .gaming: return .controller
        case .coding: return .laptop
        case .heatingUp: return .thermometer
        case .charging: return .chargerCable
        default: return .cane
        }
    }

    static func fx(for state: BillState) -> BillFX? {
        switch state {
        case .heatingUp: return .steam
        case .sleeping: return .zzz
        case .celebrating: return .confettiAndSparkle
        case .happy: return .sparkle
        default: return nil
        }
    }

    // MARK: - Ambient rest

    static let idle = AnimationClip(tracks: [:], loop: .once)

    // MARK: - Locomotion

    static let walking = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.28, offset: CGVector(dx: 0, dy: 4)),
                PoseKeyframe(duration: 0.28, offset: CGVector(dx: 0, dy: 0)),
            ],
            .leftLeg: [
                PoseKeyframe(duration: 0.28, rotation: 0.5),
                PoseKeyframe(duration: 0.28, rotation: -0.4),
            ],
            .rightLeg: [
                PoseKeyframe(duration: 0.28, rotation: -0.4),
                PoseKeyframe(duration: 0.28, rotation: 0.5),
            ],
            .leftArm: [
                PoseKeyframe(duration: 0.28, rotation: -0.3),
                PoseKeyframe(duration: 0.28, rotation: 0.35),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.28, rotation: 0.35),
                PoseKeyframe(duration: 0.28, rotation: -0.3),
            ],
        ],
        loop: .loop
    )

    // MARK: - Conversational

    static let talking = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.32, rotation: 0.035),
                PoseKeyframe(duration: 0.32, rotation: -0.02),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.3, rotation: 0.25),
                PoseKeyframe(duration: 0.3, rotation: 0.05),
            ],
            .pupil: [
                PoseKeyframe(duration: 0.5, offset: CGVector(dx: 2, dy: 1)),
                PoseKeyframe(duration: 0.5, offset: CGVector(dx: -2, dy: -1)),
            ],
        ],
        loop: .pingpong
    )

    static let thinking = AnimationClip(
        tracks: [
            .leftArm: [
                PoseKeyframe(duration: 0.45, rotation: -1.1, timing: .easeOut),
                PoseKeyframe(duration: 1.4, rotation: -1.1),
            ],
            .body: [
                PoseKeyframe(duration: 0.9, rotation: -0.03),
                PoseKeyframe(duration: 0.9, rotation: 0.02),
            ],
            .pupil: [
                PoseKeyframe(duration: 0.8, offset: CGVector(dx: -4, dy: 5)),
                PoseKeyframe(duration: 0.8, offset: CGVector(dx: 4, dy: 5)),
            ],
        ],
        loop: .pingpong
    )

    // MARK: - Emotional beats (single-shot, settle back to idle)

    static let happy = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.14, scale: 1.12, timing: .easeOut),
                PoseKeyframe(duration: 0.12, scale: 0.96),
                PoseKeyframe(duration: 0.18, scale: 1.0),
                PoseKeyframe(duration: 0.5),
            ],
            .leftArm: [
                PoseKeyframe(duration: 0.18, rotation: -2.6, timing: .easeOut),
                PoseKeyframe(duration: 0.5, rotation: -2.6),
                PoseKeyframe(duration: 0.3),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.18, rotation: 2.6, timing: .easeOut),
                PoseKeyframe(duration: 0.5, rotation: 2.6),
                PoseKeyframe(duration: 0.3),
            ],
            .eye: [
                PoseKeyframe(duration: 0.16, scale: 0.55),
                PoseKeyframe(duration: 0.5, scale: 1.0),
                PoseKeyframe(duration: 0.3),
            ],
        ],
        loop: .once
    )

    static let annoyed = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.06, offset: CGVector(dx: -6, dy: 0)),
                PoseKeyframe(duration: 0.06, offset: CGVector(dx: 6, dy: 0)),
                PoseKeyframe(duration: 0.06, offset: CGVector(dx: -4, dy: 0)),
                PoseKeyframe(duration: 0.06, offset: CGVector(dx: 0, dy: 0)),
                PoseKeyframe(duration: 0.6),
            ],
            .leftArm: [
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: 20, dy: 20), rotation: -1.9),
                PoseKeyframe(duration: 0.7, offset: CGVector(dx: 20, dy: 20), rotation: -1.9),
                PoseKeyframe(duration: 0.3),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: -20, dy: 20), rotation: 1.9),
                PoseKeyframe(duration: 0.7, offset: CGVector(dx: -20, dy: 20), rotation: 1.9),
                PoseKeyframe(duration: 0.3),
            ],
            .eye: [
                PoseKeyframe(duration: 0.15, scale: 0.7),
                PoseKeyframe(duration: 0.75, scale: 0.7),
                PoseKeyframe(duration: 0.3, scale: 1.0),
            ],
        ],
        loop: .once
    )

    static let surprised = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.1, offset: CGVector(dx: 0, dy: 14), scale: 1.08, timing: .easeOut),
                PoseKeyframe(duration: 0.35, offset: CGVector(dx: 0, dy: 0), scale: 1.0, timing: .easeOut),
                PoseKeyframe(duration: 0.4),
            ],
            .eye: [
                PoseKeyframe(duration: 0.08, scale: 1.35, timing: .easeOut),
                PoseKeyframe(duration: 0.4, scale: 1.0),
                PoseKeyframe(duration: 0.4),
            ],
            .leftArm: [
                PoseKeyframe(duration: 0.1, offset: CGVector(dx: 10, dy: 10), rotation: -1.4, timing: .easeOut),
                PoseKeyframe(duration: 0.6),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.1, offset: CGVector(dx: -10, dy: 10), rotation: 1.4, timing: .easeOut),
                PoseKeyframe(duration: 0.6),
            ],
            .hat: [
                PoseKeyframe(duration: 0.1, offset: CGVector(dx: 0, dy: 8), timing: .easeOut),
                PoseKeyframe(duration: 0.5),
            ],
        ],
        loop: .once
    )

    static let celebrating = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: 0, dy: 12), timing: .easeOut),
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: 0, dy: 0), timing: .easeIn),
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: 0, dy: 12), timing: .easeOut),
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: 0, dy: 0), timing: .easeIn),
                PoseKeyframe(duration: 0.2, offset: CGVector(dx: 0, dy: 12), timing: .easeOut),
                PoseKeyframe(duration: 0.4),
            ],
            .leftArm: [
                PoseKeyframe(duration: 0.2, rotation: -2.8, timing: .easeOut),
                PoseKeyframe(duration: 0.2, rotation: -2.4),
                PoseKeyframe(duration: 0.2, rotation: -2.8),
                PoseKeyframe(duration: 0.2, rotation: -2.4),
                PoseKeyframe(duration: 0.2, rotation: -2.8),
                PoseKeyframe(duration: 0.4),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.2, rotation: 2.8, timing: .easeOut),
                PoseKeyframe(duration: 0.2, rotation: 2.4),
                PoseKeyframe(duration: 0.2, rotation: 2.8),
                PoseKeyframe(duration: 0.2, rotation: 2.4),
                PoseKeyframe(duration: 0.2, rotation: 2.8),
                PoseKeyframe(duration: 0.4),
            ],
        ],
        loop: .once
    )

    // MARK: - Sustained conditions

    static let sleeping = AnimationClip(
        tracks: [
            .eye: [
                PoseKeyframe(duration: 0.4, scale: 0.06, timing: .easeIn),
                PoseKeyframe(duration: 1.6, scale: 0.06),
            ],
            .body: [
                PoseKeyframe(duration: 1.4, offset: CGVector(dx: 0, dy: -3)),
                PoseKeyframe(duration: 1.4, offset: CGVector(dx: 0, dy: 0)),
            ],
            .hat: [
                PoseKeyframe(duration: 0.4, rotation: -0.08),
                PoseKeyframe(duration: 1.6, rotation: -0.08),
            ],
        ],
        loop: .pingpong
    )

    static let gaming = AnimationClip(
        tracks: [
            .leftArm: [
                PoseKeyframe(duration: 0.3, offset: CGVector(dx: 14, dy: 22), rotation: -1.25, timing: .easeOut),
                PoseKeyframe(duration: 0.5, offset: CGVector(dx: 14, dy: 22), rotation: -1.15),
                PoseKeyframe(duration: 0.5, offset: CGVector(dx: 14, dy: 22), rotation: -1.25),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.3, offset: CGVector(dx: -14, dy: 22), rotation: 1.25, timing: .easeOut),
                PoseKeyframe(duration: 0.5, offset: CGVector(dx: -14, dy: 22), rotation: 1.15),
                PoseKeyframe(duration: 0.5, offset: CGVector(dx: -14, dy: 22), rotation: 1.25),
            ],
            .body: [
                PoseKeyframe(duration: 0.4, offset: CGVector(dx: 0, dy: 3)),
                PoseKeyframe(duration: 0.4, offset: CGVector(dx: 0, dy: 0)),
            ],
            .pupil: [
                PoseKeyframe(duration: 0.35, offset: CGVector(dx: -5, dy: 0)),
                PoseKeyframe(duration: 0.35, offset: CGVector(dx: 5, dy: 0)),
            ],
        ],
        loop: .loop
    )

    static let coding = AnimationClip(
        tracks: [
            .leftArm: [
                PoseKeyframe(duration: 0.35, offset: CGVector(dx: 12, dy: 30), rotation: -1.05, timing: .easeOut),
                PoseKeyframe(duration: 0.12, offset: CGVector(dx: 12, dy: 30), rotation: -1.0),
                PoseKeyframe(duration: 0.12, offset: CGVector(dx: 12, dy: 30), rotation: -1.08),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.35, offset: CGVector(dx: -12, dy: 30), rotation: 1.05, timing: .easeOut),
                PoseKeyframe(duration: 0.1, offset: CGVector(dx: -12, dy: 30), rotation: 1.1),
                PoseKeyframe(duration: 0.14, offset: CGVector(dx: -12, dy: 30), rotation: 1.02),
            ],
            .body: [
                PoseKeyframe(duration: 0.4, offset: CGVector(dx: 0, dy: -2), rotation: -0.05, timing: .easeOut),
                PoseKeyframe(duration: 1.2, offset: CGVector(dx: 0, dy: -2), rotation: -0.05),
            ],
        ],
        loop: .loop
    )

    static let heatingUp = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 0.9, offset: CGVector(dx: -3, dy: -4), scale: 0.97),
                PoseKeyframe(duration: 0.9, offset: CGVector(dx: 3, dy: -4), scale: 0.97),
            ],
            .eye: [
                PoseKeyframe(duration: 0.5, scale: 0.5, timing: .easeOut),
                PoseKeyframe(duration: 1.3, scale: 0.5),
            ],
            .leftArm: [
                PoseKeyframe(duration: 0.9, rotation: -0.2),
                PoseKeyframe(duration: 0.9, rotation: -0.35),
            ],
            .rightArm: [
                PoseKeyframe(duration: 0.9, rotation: 0.2),
                PoseKeyframe(duration: 0.9, rotation: 0.35),
            ],
        ],
        loop: .pingpong
    )

    static let charging = AnimationClip(
        tracks: [
            .body: [
                PoseKeyframe(duration: 1.1, scale: 1.03),
                PoseKeyframe(duration: 1.1, scale: 1.0),
            ],
            .eye: [
                PoseKeyframe(duration: 1.1, scale: 0.8),
                PoseKeyframe(duration: 1.1, scale: 0.85),
            ],
        ],
        loop: .pingpong
    )

    // MARK: - Idle variety (short, sparse beats — not a continuous loop)

    enum IdleVariant: CaseIterable {
        case blink
        case lookLeft
        case lookRight
        case stretch
        case tiltCheck

        var clip: AnimationClip {
            switch self {
            case .blink:
                return AnimationClip(tracks: [
                    .eye: [
                        PoseKeyframe(duration: 0.08, scale: 0.08, timing: .easeIn),
                        PoseKeyframe(duration: 0.1, scale: 1.0, timing: .easeOut),
                    ],
                ], loop: .once)
            case .lookLeft:
                return AnimationClip(tracks: [
                    .pupil: [
                        PoseKeyframe(duration: 0.3, offset: CGVector(dx: -7, dy: 1)),
                        PoseKeyframe(duration: 0.6, offset: CGVector(dx: -7, dy: 1)),
                        PoseKeyframe(duration: 0.3),
                    ],
                ], loop: .once)
            case .lookRight:
                return AnimationClip(tracks: [
                    .pupil: [
                        PoseKeyframe(duration: 0.3, offset: CGVector(dx: 7, dy: 1)),
                        PoseKeyframe(duration: 0.6, offset: CGVector(dx: 7, dy: 1)),
                        PoseKeyframe(duration: 0.3),
                    ],
                ], loop: .once)
            case .stretch:
                return AnimationClip(tracks: [
                    .body: [
                        PoseKeyframe(duration: 0.35, scale: 1.05, timing: .easeOut),
                        PoseKeyframe(duration: 0.45, scale: 1.0, timing: .easeIn),
                    ],
                    .leftArm: [
                        PoseKeyframe(duration: 0.35, rotation: -1.0, timing: .easeOut),
                        PoseKeyframe(duration: 0.45),
                    ],
                    .rightArm: [
                        PoseKeyframe(duration: 0.35, rotation: 1.0, timing: .easeOut),
                        PoseKeyframe(duration: 0.45),
                    ],
                ], loop: .once)
            case .tiltCheck:
                return AnimationClip(tracks: [
                    .body: [
                        PoseKeyframe(duration: 0.4, rotation: 0.12),
                        PoseKeyframe(duration: 0.4, rotation: 0),
                    ],
                    .hat: [
                        PoseKeyframe(duration: 0.4, rotation: 0.12),
                        PoseKeyframe(duration: 0.4, rotation: 0),
                    ],
                ], loop: .once)
            }
        }
    }
}
