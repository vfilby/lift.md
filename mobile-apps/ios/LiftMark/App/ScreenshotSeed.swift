#if DEBUG
import Foundation
import GRDB

/// Seeds a deterministic dataset for App Store screenshot capture: four
/// LMWF plans (Push / Pull / Legs / Conditioning) plus six weeks of
/// completed sessions on a realistic split so home tiles, history list,
/// and exercise progress charts all show varied content with a believable
/// upward trend.
///
/// Triggered via `--seed-screenshots` (paired with `--reset-data`). The
/// markdown lives inline so the app needs no host-filesystem access; the
/// canonical Push Day copy is `test-fixtures/screenshot-routine.md`.
///
/// Split across extension files to keep each concern focused:
/// - `ScreenshotSeed+SessionWrites.swift` — completed-session DB writes
///   and the progressive-overload math.
/// - `ScreenshotSeed+ActivePlans.swift` — markdown for the four plans in
///   the schedule.
/// - `ScreenshotSeed+LibraryPlans.swift` — markdown for library-only plans.
enum ScreenshotSeed {

    // MARK: - Public entry point

    static func seed() {
        let parsedPlans = planSources.compactMap { source -> (WorkoutPlan, PlanKey)? in
            let parsed = MarkdownParser.parseWorkout(source.markdown)
            guard parsed.success, var plan = parsed.data else {
                Logger.shared.error(.app, "ScreenshotSeed: failed to parse '\(source.key)'")
                return nil
            }
            plan.isFavorite = source.favorite
            return (plan, source.key)
        }

        let repository = WorkoutPlanRepository()
        do {
            for (plan, _) in parsedPlans {
                try repository.create(plan)
            }
            try seedHistory(plans: Dictionary(uniqueKeysWithValues: parsedPlans.map { ($1, $0) }))
        } catch {
            Logger.shared.error(.app, "ScreenshotSeed: \(error.localizedDescription)")
        }
    }

    // MARK: - Schedule

    // push/pull/legs/conditioning are the actively-run programs that fill the
    // history. fullBody/upper/arms/mobility round out the plan library so the
    // Plans screen looks lived-in — they're saved but not (yet) in the schedule,
    // so they carry no session history.
    enum PlanKey: String { case push, pull, legs, conditioning, fullBody, upper, arms, mobility }

    /// 6-week PPL+conditioning split. Tuples are (daysAgo, plan). Entries are
    /// kept in chronological order — newest last — so progressive-overload
    /// math reads naturally (week 0 = oldest, week N = today).
    private static let schedule: [(daysAgo: Int, plan: PlanKey)] = [
        // Week 6 (oldest)
        (40, .push), (39, .pull), (37, .legs), (35, .conditioning),
        // Week 5
        (33, .push), (32, .pull), (30, .legs), (28, .conditioning),
        // Week 4
        (26, .push), (25, .pull), (23, .legs), (21, .conditioning),
        // Week 3
        (19, .push), (18, .pull), (16, .legs),
        // Week 2 — slight schedule drift; took Saturday off
        (12, .push), (11, .pull), (9, .legs), (7, .conditioning),
        // Week 1 (most recent — today is day 0, no session today). Newest
        // entry is Push Day so the trend-graph screenshot lands on a session
        // containing Barbell Bench Press without filtering by name.
        (5, .legs), (4, .pull), (2, .push)
    ]

    private static func seedHistory(plans: [PlanKey: WorkoutPlan]) throws {
        let dbQueue = try DatabaseManager.shared.database()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Reverse so we walk newest→oldest while writing — order doesn't matter
        // for correctness but keeps the SQL trace readable.
        for (index, entry) in schedule.enumerated() {
            guard let plan = plans[entry.plan] else { continue }
            guard let sessionDate = calendar.date(byAdding: .day, value: -entry.daysAgo, to: now),
                  let startDate = startTime(for: entry.plan, on: sessionDate, calendar: calendar),
                  let endDate = calendar.date(byAdding: .minute, value: durationMinutes(for: entry.plan), to: startDate)
            else { continue }

            // Progression index: 0 = oldest session, schedule.count-1 = newest.
            let progressionWeeks = (schedule.count - 1 - index) / 4 // ~weeks-back from latest
            try writeCompletedSession(
                plan: plan,
                timing: SessionTiming(
                    date: dateFormatter.string(from: sessionDate),
                    start: isoFormatter.string(from: startDate),
                    end: isoFormatter.string(from: endDate)
                ),
                weeksFromLatest: progressionWeeks,
                in: dbQueue
            )
        }
    }

    /// Slightly different start times by plan so the history list isn't
    /// uniform — push/pull are morning, legs is afternoon, conditioning is
    /// evening. Adds visual variety to the timestamps.
    private static func startTime(for plan: PlanKey, on date: Date, calendar: Calendar) -> Date? {
        switch plan {
        case .push: return calendar.date(bySettingHour: 7, minute: 15, second: 0, of: date)
        case .pull: return calendar.date(bySettingHour: 7, minute: 30, second: 0, of: date)
        case .legs: return calendar.date(bySettingHour: 17, minute: 0, second: 0, of: date)
        case .conditioning: return calendar.date(bySettingHour: 18, minute: 30, second: 0, of: date)
        // Library-only plans (no scheduled sessions); values are placeholders.
        case .fullBody, .upper, .arms, .mobility:
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date)
        }
    }

    private static func durationMinutes(for plan: PlanKey) -> Int {
        switch plan {
        case .push: return 52
        case .pull: return 48
        case .legs: return 58
        case .conditioning: return 32
        // Library-only plans (no scheduled sessions); values are placeholders.
        case .fullBody, .upper, .arms, .mobility: return 45
        }
    }

    // MARK: - Plan sources

    struct PlanSource {
        let key: PlanKey
        let markdown: String
        let favorite: Bool
    }

    private static let planSources: [PlanSource] = [
        PlanSource(key: .push, markdown: pushDayMarkdown, favorite: true),
        PlanSource(key: .pull, markdown: pullDayMarkdown, favorite: false),
        PlanSource(key: .legs, markdown: legDayMarkdown, favorite: false),
        PlanSource(key: .conditioning, markdown: conditioningMarkdown, favorite: false),
        // Library-only plans — fill out the Plans screen, no session history.
        PlanSource(key: .fullBody, markdown: fullBodyMarkdown, favorite: false),
        PlanSource(key: .upper, markdown: upperBodyMarkdown, favorite: false),
        PlanSource(key: .arms, markdown: armDayMarkdown, favorite: false),
        PlanSource(key: .mobility, markdown: mobilityMarkdown, favorite: false)
    ]
}
#endif
