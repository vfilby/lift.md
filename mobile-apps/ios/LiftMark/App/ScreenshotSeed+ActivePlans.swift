#if DEBUG
import Foundation

// MARK: - Active plans (scheduled, with session history)

extension ScreenshotSeed {

    /// Source: test-fixtures/screenshot-routine.md. Showcase plan — the
    /// workout-detail screenshot opens this one. No warmup section so the
    /// screenshots land directly on the working sets and the superset.
    static let pushDayMarkdown = """
    # Push Day — Upper Strength

    @tags: push, upper, strength
    @units: lbs

    ## Main

    ### Barbell Bench Press
    Heavy compound — film a working set if form feels off
    - 135 x 8 @rest: 90s
    - 155 x 6 @rest: 120s
    - 185 x 5 @rest: 150s
    - 195 x 5 @rest: 150s
    - 195 x 5 @rest: 150s

    ### Overhead Press
    Strict press, full lockout overhead
    - 75 x 8 @rest: 90s
    - 95 x 6 @rest: 120s
    - 105 x 5 @rest: 120s

    ### Superset: Chest & Shoulders
    #### Incline Dumbbell Press
    Set the bench around 30°. Press up and slightly in, controlled tempo down.
    - 50 x 10
    - 55 x 10
    - 60 x 8
    #### Lateral Raises
    Slight bend in the elbows. Lead with the elbows, raise to shoulder height — no swinging.
    - 15 x 15
    - 15 x 15
    - 20 x 12

    ### Cable Tricep Pushdown
    Drop set to finish — strip the stack, then max reps
    - 60 x 12 @dropset
    - 40 x AMRAP

    ### Push-ups
    Finisher — go to failure on the last set
    - x 15
    - x 12
    - bw x AMRAP

    ## Cool Down

    ### Plank
    Core finisher
    - 60s @rest: 45s
    - 45s

    ### Doorway Chest Stretch
    Open up the pecs
    - 30s @perside

    ### Cross-Body Shoulder Stretch
    Each side, gentle pull
    - 30s @perside
    """

    static let pullDayMarkdown = """
    # Pull Day — Back & Biceps

    @tags: pull, back, biceps
    @units: lbs

    ## Warmup

    ### Cat-Cow
    Spinal mobility, move with breath
    - x 10

    ### Band Pull-Aparts
    - x 15
    - x 15

    ### Scapular Pull-Ups
    Just the shrug — no elbow bend
    - x 8

    ## Main

    ### Conventional Deadlift
    Working triples — keep core braced and bar close
    - 135 x 5 @rest: 120s
    - 185 x 3 @rest: 150s
    - 225 x 3 @rest: 180s
    - 275 x 3 @rest: 180s
    - 275 x 3 @rest: 180s

    ### Barbell Row
    Pendlay-style, full reset between reps
    - 95 x 8 @rest: 90s
    - 115 x 6 @rest: 120s
    - 135 x 6 @rest: 120s
    - 135 x 6 @rest: 120s

    ### Lat Pulldown
    Squeeze the lats, no momentum
    - 100 x 10 @rest: 90s
    - 120 x 8 @rest: 90s
    - 130 x 6 @rest: 90s

    ### Dumbbell Bicep Curl
    Strict, slow eccentric
    - 25 x 10 @rest: 60s
    - 30 x 8 @rest: 60s
    - 30 x 8 @rest: 60s

    ### Face Pulls
    Pull to forehead, externally rotate
    - 30 x 15
    - 35 x 12
    - 35 x 12

    ## Cool Down

    ### Child's Pose
    - 60s

    ### Lat Stretch
    - 30s @perside
    """

    static let legDayMarkdown = """
    # Leg Day — Lower Power

    @tags: legs, lower, strength
    @units: lbs

    ## Warmup

    ### 90/90 Hip Switches
    - x 10

    ### Bodyweight Squat
    - x 12

    ### Glute Bridge
    - x 12

    ## Main

    ### Barbell Back Squat
    Heavy compound — drive through heels, brace hard
    - 135 x 8 @rest: 90s
    - 185 x 5 @rest: 150s
    - 225 x 5 @rest: 180s
    - 245 x 3 @rest: 180s
    - 245 x 3 @rest: 180s

    ### Romanian Deadlift
    Hip hinge, feel the hamstrings
    - 135 x 8 @rest: 90s
    - 155 x 8 @rest: 90s
    - 175 x 6 @rest: 120s

    ### Bulgarian Split Squat
    Each leg, slow tempo
    - 30 x 10 @perside @rest: 90s
    - 35 x 8 @perside @rest: 90s
    - 35 x 8 @perside @rest: 90s

    ### Leg Press
    Full ROM, no lockout
    - 270 x 12 @rest: 90s
    - 360 x 10 @rest: 120s
    - 405 x 8 @rest: 120s

    ### Standing Calf Raise
    Pause at the top
    - 90 x 15
    - 110 x 12
    - 110 x 12

    ## Cool Down

    ### Pigeon Pose
    - 45s @perside

    ### Quad Stretch
    - 30s @perside

    ### Hamstring Stretch
    - 30s @perside
    """

    static let conditioningMarkdown = """
    # Conditioning & Core

    @tags: conditioning, core, cardio
    @units: lbs

    ## Warmup

    ### Jumping Jacks
    - 60s

    ### High Knees
    - 30s

    ## Circuit

    ### Kettlebell Swing
    Hip-driven, not a squat
    - 35 x 20 @rest: 45s
    - 35 x 20 @rest: 45s
    - 35 x 20 @rest: 45s

    ### Goblet Squat
    Elbows inside knees at the bottom
    - 35 x 15 @rest: 45s
    - 35 x 15 @rest: 45s

    ### Mountain Climbers
    - 45s @rest: 30s
    - 45s @rest: 30s
    - 45s

    ### Russian Twist
    - x 30 @rest: 30s
    - x 30 @rest: 30s

    ## Core

    ### Superset: Plank & Dead Bug
    #### Plank
    Beat last week's 65s — aim for 70s if it feels solid.
    - 60s @rest: 20s
    - 60s @rest: 20s
    - 45s

    #### Dead Bug
    Slow and controlled, lower back pressed into floor.
    - x 10 @perside
    - x 10 @perside
    - x 10 @perside

    ### Hollow Hold
    - 30s @rest: 30s
    - 30s

    ### Bird Dog
    Each side, slow and controlled
    - x 12 @perside

    ## Cool Down

    ### Cat-Cow
    - x 10

    ### Cobra Stretch
    - 30s
    """
}
#endif
