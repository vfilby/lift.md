import Foundation

// MARK: - Weight Propagation (GH #5, regression GH #489)

extension ActiveWorkoutViewModel {

    /// The weight to suggest for the pending set at `index` instead of its
    /// target, or nil to fall back to the target.
    ///
    /// A change to one set's weight carries over to the later pending sets of
    /// the same exercise that were planned at the same weight (same value and
    /// unit), so sets planned at a different weight (pyramids, back-off sets)
    /// keep their own target:
    /// - While the user edits the current set, later same-target sets follow
    ///   the live `currentWeight`.
    /// - Otherwise the set inherits the actual weight of the most recent
    ///   completed set before it with the same target. Derived from logged
    ///   sets only, so it survives relaunch and never rewrites the target.
    static func suggestedWeight(
        forSetAt index: Int,
        in sets: [SessionSet],
        currentSetIndex: Int?,
        currentWeight: Double?
    ) -> Double? {
        guard sets.indices.contains(index) else { return nil }
        let set = sets[index]
        guard set.status == .pending, let target = set.entries.first?.target?.weight else { return nil }

        if let currentWeight, let current = currentSetIndex, current < index,
           sets[current].entries.first?.target?.weight == target {
            return currentWeight
        }

        return sets[..<index].last { previous in
            previous.status == .completed
                && previous.entries.first?.target?.weight == target
                && previous.entries.first?.actual?.weight?.unit == target.unit
        }?.entries.first?.actual?.weight?.value
    }
}
