import XCTest
@testable import LiftMark

final class ExerciseDictionaryTests: XCTestCase {

    // MARK: - getCanonicalName

    func testGetCanonicalName_exactMatch() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("Bench Press"), "Bench Press")
    }

    func testGetCanonicalName_alias() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("barbell bench press"), "Bench Press")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("flat bench"), "Bench Press")
    }

    func testGetCanonicalName_caseInsensitive() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("BENCH PRESS"), "Bench Press")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("bench press"), "Bench Press")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("Bench press"), "Bench Press")
    }

    func testGetCanonicalName_unknownReturnsOriginal() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("Some Weird Exercise"), "Some Weird Exercise")
    }

    func testGetCanonicalName_ohpAlias() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("ohp"), "Overhead Press")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("military press"), "Overhead Press")
    }

    func testGetCanonicalName_rdlAlias() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("rdl"), "Romanian Deadlift")
    }

    // GH #124 — `Bench` was a phantom alias: barbell math silently failed to engage.
    func testGetCanonicalName_benchShorthand() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("Bench"), "Bench Press")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("bench"), "Bench Press")
    }

    func testGetCanonicalName_deadliftShorthand() {
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("dl"), "Deadlift")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("DL"), "Deadlift")
        XCTAssertEqual(ExerciseDictionary.getCanonicalName("deads"), "Deadlift")
    }

    // MARK: - isSameExercise

    func testIsSameExercise_sameCanonical() {
        XCTAssertTrue(ExerciseDictionary.isSameExercise("Bench Press", "barbell bench press"))
        XCTAssertTrue(ExerciseDictionary.isSameExercise("flat bench", "bb bench"))
    }

    func testIsSameExercise_differentExercises() {
        XCTAssertFalse(ExerciseDictionary.isSameExercise("Bench Press", "Incline Bench Press"))
        XCTAssertFalse(ExerciseDictionary.isSameExercise("Squat", "Front Squat"))
    }

    func testIsSameExercise_dumbbellVsBarbell() {
        XCTAssertFalse(ExerciseDictionary.isSameExercise("Bench Press", "Dumbbell Bench Press"))
        XCTAssertFalse(ExerciseDictionary.isSameExercise("Bicep Curl", "Dumbbell Curl"))
    }

    // MARK: - getAliases

    func testGetAliases_returnsAll() {
        let aliases = ExerciseDictionary.getAliases("Bench Press")
        XCTAssertTrue(aliases.contains("bench press"))
        XCTAssertTrue(aliases.contains("barbell bench press"))
        XCTAssertTrue(aliases.contains("flat bench"))
        XCTAssertTrue(aliases.contains("bb bench"))
    }

    func testGetAliases_fromAlias() {
        let aliases = ExerciseDictionary.getAliases("flat bench")
        XCTAssertTrue(aliases.contains("bench press"))
        XCTAssertTrue(aliases.contains("barbell bench press"))
    }

    func testGetAliases_unknownReturnsSingleElement() {
        let aliases = ExerciseDictionary.getAliases("Unknown Exercise")
        XCTAssertEqual(aliases, ["unknown exercise"])
    }

    // MARK: - getDefinition

    func testGetDefinition_found() {
        let def = ExerciseDictionary.getDefinition("Back Squat")
        XCTAssertNotNil(def)
        XCTAssertEqual(def?.canonical, "Back Squat")
        XCTAssertEqual(def?.category, "compound")
        XCTAssertTrue(def?.muscleGroups.contains("quadriceps") ?? false)
    }

    func testGetDefinition_fromAlias() {
        let def = ExerciseDictionary.getDefinition("squat")
        XCTAssertNotNil(def)
        XCTAssertEqual(def?.canonical, "Back Squat")
    }

    func testGetDefinition_notFound() {
        XCTAssertNil(ExerciseDictionary.getDefinition("Unknown Exercise"))
    }

    func testGetDefinition_categoryCheck() {
        XCTAssertEqual(ExerciseDictionary.getDefinition("Pull-Up")?.category, "bodyweight")
        XCTAssertEqual(ExerciseDictionary.getDefinition("Lateral Raise")?.category, "isolation")
        XCTAssertEqual(ExerciseDictionary.getDefinition("Deadlift")?.category, "compound")
    }
}
