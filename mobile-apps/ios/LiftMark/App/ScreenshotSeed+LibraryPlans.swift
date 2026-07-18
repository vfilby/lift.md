#if DEBUG
import Foundation

// MARK: - Library-only plans (no scheduled history)

extension ScreenshotSeed {

    static let fullBodyMarkdown = """
    # Full Body — 5×5 Strength

    @tags: full-body, strength, beginner
    @units: lbs

    ## Main

    ### Back Squat
    Five across — same weight all sets once warm
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s
    - 185 x 5 @rest: 180s

    ### Bench Press
    Pause briefly on the chest each rep
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s
    - 155 x 5 @rest: 180s

    ### Barbell Row
    Flat back, pull to the lower ribs
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    - 135 x 5 @rest: 120s
    """

    static let upperBodyMarkdown = """
    # Upper Body — Hypertrophy

    @tags: upper, hypertrophy
    @units: lbs

    ## Main

    ### Incline Dumbbell Press
    Controlled tempo, stretch at the bottom
    - 50 x 12 @rest: 90s
    - 55 x 10 @rest: 90s
    - 60 x 8 @rest: 90s

    ### Seated Cable Row
    Squeeze and hold a beat at the back
    - 120 x 12 @rest: 75s
    - 135 x 10 @rest: 75s
    - 150 x 8 @rest: 75s

    ### Dumbbell Shoulder Press
    Press to lockout, no leg drive
    - 35 x 12 @rest: 75s
    - 40 x 10 @rest: 75s

    ### Lat Pulldown
    Drive the elbows down and back
    - 110 x 12 @rest: 75s
    - 120 x 10 @rest: 75s
    """

    static let armDayMarkdown = """
    # Arm Day — Biceps & Triceps

    @tags: arms, biceps, triceps
    @units: lbs

    ## Main

    ### Barbell Curl
    Strict — no swinging at the hips
    - 60 x 12 @rest: 60s
    - 70 x 10 @rest: 60s
    - 70 x 10 @rest: 60s

    ### Close-Grip Bench Press
    Elbows tucked, full lockout
    - 115 x 10 @rest: 90s
    - 125 x 8 @rest: 90s

    ### Hammer Curl
    Neutral grip, control the lowering
    - 30 x 12 @rest: 60s
    - 30 x 12 @rest: 60s

    ### Overhead Cable Extension
    Keep the elbows high and still
    - 50 x 15 @rest: 60s
    - 60 x 12 @rest: 60s
    """

    static let mobilityMarkdown = """
    # Mobility & Core

    @tags: mobility, core, recovery
    @units: lbs

    ## Main

    ### Plank
    Brace hard, breathe steady
    - 60s @rest: 45s
    - 60s @rest: 45s
    - 45s

    ### Dead Bug
    Slow and controlled, opposite arm and leg
    - x 12 @perside
    - x 12 @perside

    ### Bird Dog
    Reach long, pause at full extension
    - x 10 @perside
    - x 10 @perside

    ### Couch Stretch
    Open the hip flexors
    - 45s @perside

    ### Cat-Cow
    Move with the breath
    - x 10
    """
}
#endif
