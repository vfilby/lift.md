import Foundation

extension Double {
    /// Display formatting for weights and plate values.
    ///
    /// Whole numbers render without a decimal (`45` → `"45"`); fractional values
    /// render with up to two decimal places and no trailing zeros (`2.5` → `"2.5"`,
    /// `33.75` → `"33.75"`, `1.25` → `"1.25"`).
    ///
    /// Rounds to the nearest 0.01 first so floating-point noise and legitimate
    /// quarter-plate increments both survive — e.g. a 112.5 lb target yields a
    /// 33.75 lb-per-side breakdown that must read as `"33.75"`, not the `"33.8"`
    /// produced by a blanket `%.1f`. See GH #211.
    var formattedWeight: String {
        let rounded = (self * 100).rounded() / 100
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(rounded))
        }
        // One decimal suffices when the hundredths place is zero (2.5, 112.5);
        // otherwise show both decimals (33.75, 1.25).
        if (rounded * 10).truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.1f", rounded)
        }
        return String(format: "%.2f", rounded)
    }
}
