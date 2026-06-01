import Testing
@testable import LiftMark

/// TC-E14 (GH #195): the Edit Exercise *Form* tab must reject a set that has a
/// weight but no reps and no time — matching the LMWF spec, the validator, and
/// the Markdown tab (which already rejects it via `MarkdownParser`).
/// `EditableSetRow.isWeightOnly` is the testable predicate the Form save path
/// enforces.
@Suite("EditableSetRow.isWeightOnly")
struct EditExerciseSetValidationTests {

    private func row(weight: String, reps: String = "", time: String = "") -> EditableSetRow {
        EditableSetRow(
            id: "s",
            existingSetId: nil,
            weightText: weight,
            repsText: reps,
            timeText: time,
            restText: "",
            weightUnit: .lbs,
            status: .pending
        )
    }

    @Test("weight with no reps and no time is incomplete (TC-E14)")
    func weightOnlyIsIncomplete() {
        #expect(row(weight: "26").isWeightOnly == true)
        #expect(row(weight: "135").isWeightOnly == true)
        #expect(row(weight: "26.5").isWeightOnly == true)
    }

    @Test("weight with reps is complete")
    func weightWithReps() {
        #expect(row(weight: "135", reps: "5").isWeightOnly == false)
    }

    @Test("weight with time is complete (e.g. a weighted carry: 26 lbs x 30s)")
    func weightWithTime() {
        #expect(row(weight: "26", time: "30").isWeightOnly == false)
    }

    @Test("bodyweight / reps-only set (no weight) is complete")
    func repsOnly() {
        #expect(row(weight: "", reps: "10").isWeightOnly == false)
    }

    @Test("time-only set (no weight) is complete")
    func timeOnly() {
        #expect(row(weight: "", time: "60").isWeightOnly == false)
    }

    @Test("fully empty row is not flagged (treated as bodyweight by the parser)")
    func emptyRow() {
        #expect(row(weight: "").isWeightOnly == false)
    }

    @Test("zero / non-numeric weight is not a real weight")
    func zeroOrNonNumericWeight() {
        #expect(row(weight: "0").isWeightOnly == false)
        #expect(row(weight: "abc").isWeightOnly == false)
    }

    @Test("zero reps and zero time do not satisfy a real weight")
    func zeroRepsAndTime() {
        #expect(row(weight: "100", reps: "0", time: "0").isWeightOnly == true)
    }
}
