import Foundation

enum ExerciseDisplayItem: Identifiable {
    case single(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)
    case superset(
        parent: SessionExercise,
        children: [(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)])
    case section(name: String)

    var id: String {
        switch self {
        case .single(let exercise, _, _): return exercise.id
        case .superset(let parent, _): return parent.id
        case .section(let name): return "section-\(name)"
        }
    }
}
