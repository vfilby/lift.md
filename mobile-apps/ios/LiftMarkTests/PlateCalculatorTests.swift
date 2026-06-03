import Testing
@testable import LiftMark

@Suite("PlateCalculator")
struct PlateCalculatorTests {

    // MARK: - isBarbellExercise

    @Suite("isBarbellExercise")
    struct IsBarbellExerciseTests {

        @Test("identifies barbell exercises by equipment type")
        func equipmentType() {
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Some Exercise", equipmentType: "Barbell") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Some Exercise", equipmentType: "barbell") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Some Exercise", equipmentType: "Dumbbell") == false)
        }

        @Test("identifies common barbell exercises by name")
        func knownExercises() {
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Back Squat") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Deadlift") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Bench Press") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Overhead Press") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Barbell Row") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Romanian Deadlift") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "RDL") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Power Clean") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Front Squat") == true)
        }

        @Test("does not identify non-barbell exercises")
        func nonBarbell() {
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Dumbbell Curl") == false)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Pull-up") == false)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Bodyweight Squat") == false)
        }

        @Test("is case-insensitive")
        func caseInsensitive() {
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "DEADLIFT") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "bench press") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "BaRbElL rOw") == true)
        }

        // GH #124 — shorthand exercise names must resolve via ExerciseDictionary.
        @Test("resolves shorthand aliases to canonical via ExerciseDictionary")
        func aliasResolution() {
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "Bench") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "bench") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "OHP") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "ohp") == true)
            #expect(PlateCalculator.isBarbellExercise(exerciseName: "DL") == true)
        }
    }

    // MARK: - calculatePlates (lbs)

    @Suite("calculatePlates — pounds")
    struct CalculatePlatesLbsTests {

        @Test("95 lbs — single 25 per side")
        func plates95() {
            let result = PlateCalculator.calculatePlates(totalWeight: 95, unit: "lbs")
            #expect(result.weightPerSide == 25)
            #expect(result.unit == "lbs")
            #expect(result.barWeight == 45)
            #expect(result.isAchievable == true)
            #expect(result.plates.count == 1)
            #expect(result.plates[0].weight == 25)
            #expect(result.plates[0].count == 1)
        }

        @Test("135 lbs — single 45 per side")
        func plates135() {
            let result = PlateCalculator.calculatePlates(totalWeight: 135, unit: "lbs")
            #expect(result.weightPerSide == 45)
            #expect(result.plates.count == 1)
            #expect(result.plates[0].weight == 45)
            #expect(result.plates[0].count == 1)
            #expect(result.isAchievable == true)
        }

        @Test("225 lbs — two 45s per side")
        func plates225() {
            let result = PlateCalculator.calculatePlates(totalWeight: 225, unit: "lbs")
            #expect(result.weightPerSide == 90)
            #expect(result.plates.count == 1)
            #expect(result.plates[0].weight == 45)
            #expect(result.plates[0].count == 2)
            #expect(result.isAchievable == true)
        }

        @Test("315 lbs — three 45s per side")
        func plates315() {
            let result = PlateCalculator.calculatePlates(totalWeight: 315, unit: "lbs")
            #expect(result.weightPerSide == 135)
            #expect(result.plates.count == 1)
            #expect(result.plates[0].weight == 45)
            #expect(result.plates[0].count == 3)
            #expect(result.isAchievable == true)
        }

        @Test("185 lbs — mixed plate sizes")
        func plates185() {
            let result = PlateCalculator.calculatePlates(totalWeight: 185, unit: "lbs")
            #expect(result.weightPerSide == 70)
            #expect(result.plates.count == 2)
            #expect(result.plates[0].weight == 45)
            #expect(result.plates[0].count == 1)
            #expect(result.plates[1].weight == 25)
            #expect(result.plates[1].count == 1)
            #expect(result.isAchievable == true)
        }

        @Test("152.5 lbs — small increments with remainder")
        func plates152_5() {
            let result = PlateCalculator.calculatePlates(totalWeight: 152.5, unit: "lbs")
            #expect(result.weightPerSide == 53.75)
            #expect(result.plates.count == 3)
            #expect(result.plates[0].weight == 45)
            #expect(result.plates[1].weight == 5)
            #expect(result.plates[2].weight == 2.5)
            #expect(result.isAchievable == false)
            #expect(result.remainder != nil)
            #expect(abs(result.remainder! - 1.25) < 0.01)
        }

        @Test("45 lbs — bar weight only")
        func barOnly() {
            let result = PlateCalculator.calculatePlates(totalWeight: 45, unit: "lbs")
            #expect(result.weightPerSide == 0)
            #expect(result.plates.isEmpty)
            #expect(result.isAchievable == true)
        }

        @Test("100 lbs — achievable with 25 + 2.5")
        func plates100() {
            let result = PlateCalculator.calculatePlates(totalWeight: 100, unit: "lbs")
            #expect(result.weightPerSide == 27.5)
            #expect(result.plates.count == 2)
            #expect(result.plates[0].weight == 25)
            #expect(result.plates[1].weight == 2.5)
            #expect(result.isAchievable == true)
        }

        @Test("30 lbs — less than bar weight")
        func lessThanBar() {
            let result = PlateCalculator.calculatePlates(totalWeight: 30, unit: "lbs")
            #expect(result.weightPerSide == 0)
            #expect(result.plates.isEmpty)
            #expect(result.isAchievable == false)
            #expect(result.remainder! < 0)
        }
    }

    // MARK: - calculatePlates (kg)

    @Suite("calculatePlates — kilograms")
    struct CalculatePlatesKgTests {

        @Test("60 kg")
        func plates60() {
            let result = PlateCalculator.calculatePlates(totalWeight: 60, unit: "kg")
            #expect(result.weightPerSide == 20)
            #expect(result.unit == "kg")
            #expect(result.barWeight == 20)
            #expect(result.plates.count == 1)
            #expect(result.plates[0].weight == 20)
            #expect(result.plates[0].count == 1)
            #expect(result.isAchievable == true)
        }

        @Test("100 kg")
        func plates100() {
            let result = PlateCalculator.calculatePlates(totalWeight: 100, unit: "kg")
            #expect(result.weightPerSide == 40)
            #expect(result.plates.count == 2)
            #expect(result.plates[0].weight == 25)
            #expect(result.plates[1].weight == 15)
            #expect(result.isAchievable == true)
        }

        @Test("140 kg")
        func plates140() {
            let result = PlateCalculator.calculatePlates(totalWeight: 140, unit: "kg")
            #expect(result.weightPerSide == 60)
            #expect(result.plates.count == 2)
            #expect(result.plates[0].weight == 25)
            #expect(result.plates[0].count == 2)
            #expect(result.plates[1].weight == 10)
            #expect(result.plates[1].count == 1)
            #expect(result.isAchievable == true)
        }

        @Test("20 kg — bar only")
        func barOnly() {
            let result = PlateCalculator.calculatePlates(totalWeight: 20, unit: "kg")
            #expect(result.weightPerSide == 0)
            #expect(result.plates.isEmpty)
            #expect(result.isAchievable == true)
        }
    }

    // MARK: - calculatePlates (custom bar weight)

    @Suite("calculatePlates — custom bar weight")
    struct CustomBarWeightTests {

        @Test("35 lb bar")
        func customBar35lbs() {
            let result = PlateCalculator.calculatePlates(totalWeight: 135, unit: "lbs", barWeight: 35)
            #expect(result.weightPerSide == 50)
            #expect(result.barWeight == 35)
            #expect(result.plates.count == 2)
            #expect(result.plates[0].weight == 45)
            #expect(result.plates[1].weight == 5)
            #expect(result.isAchievable == true)
        }

        @Test("15 kg bar")
        func customBar15kg() {
            let result = PlateCalculator.calculatePlates(totalWeight: 60, unit: "kg", barWeight: 15)
            #expect(result.weightPerSide == 22.5)
            #expect(result.plates.count == 2)
            #expect(result.plates[0].weight == 20)
            #expect(result.plates[1].weight == 2.5)
            #expect(result.isAchievable == true)
        }
    }

    // MARK: - formatPlateBreakdown

    @Suite("formatPlateBreakdown")
    struct FormatPlateBreakdownTests {

        @Test("single plate")
        func singlePlate() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 95, unit: "lbs")
            #expect(PlateCalculator.formatPlateBreakdown(breakdown) == "25lbs")
        }

        @Test("multiple of same plate")
        func multipleSame() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 225, unit: "lbs")
            #expect(PlateCalculator.formatPlateBreakdown(breakdown) == "2\u{00D7}45lbs")
        }

        @Test("mixed plates")
        func mixedPlates() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 185, unit: "lbs")
            #expect(PlateCalculator.formatPlateBreakdown(breakdown) == "45lbs + 25lbs")
        }

        @Test("complex with remainder")
        func complexWithRemainder() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 152.5, unit: "lbs")
            // 1.25 rounds to "1.2" with Swift's %.1f (banker's rounding)
            #expect(PlateCalculator.formatPlateBreakdown(breakdown) == "45lbs + 5lbs + 2.5lbs (+1.2lbs short)")
        }

        @Test("bar only")
        func barOnly() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 45, unit: "lbs")
            #expect(PlateCalculator.formatPlateBreakdown(breakdown) == "Bar only")
        }

        @Test("shows remainder when not achievable")
        func showsRemainder() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 146, unit: "lbs")
            let formatted = PlateCalculator.formatPlateBreakdown(breakdown)
            #expect(formatted.contains("45lbs + 5lbs"))
            #expect(formatted.contains("short"))
        }
    }

    // MARK: - formatCompletePlateSetup

    @Suite("formatCompletePlateSetup")
    struct FormatCompletePlateSetupTests {

        @Test("95 lbs")
        func setup95() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 95, unit: "lbs")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "45lb bar + 25lbs per side")
        }

        @Test("135 lbs")
        func setup135() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 135, unit: "lbs")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "45lb bar + 45lbs per side")
        }

        @Test("155 lbs")
        func setup155() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 155, unit: "lbs")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "45lb bar + 55lbs per side")
        }

        @Test("225 lbs")
        func setup225() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 225, unit: "lbs")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "45lb bar + 90lbs per side")
        }

        // GH #211: 112.5 on a 45 lb bar is 33.75 per side (25+5+2.5+1.25). The
        // per-side total must keep its quarter-plate precision and not collapse
        // to "33.8" under a blanket single-decimal format.
        @Test("112.5 lbs — quarter-plate per side keeps full precision")
        func setup112_5() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 112.5, unit: "lbs")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "45lb bar + 33.75lbs per side")
        }

        @Test("kilograms")
        func kilograms() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 100, unit: "kg")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "20kg bar + 40kg per side")
        }

        @Test("bar only")
        func barOnly() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 45, unit: "lbs")
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "Bar only")
        }

        @Test("custom bar weight")
        func customBar() {
            let breakdown = PlateCalculator.calculatePlates(totalWeight: 135, unit: "lbs", barWeight: 35)
            #expect(PlateCalculator.formatCompletePlateSetup(breakdown) == "35lb bar + 50lbs per side")
        }
    }
}
