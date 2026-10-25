import Foundation
import HealthKit
import UIKit

struct SyncReport: Sendable, Codable {
    var samples = 0
    var deletedSamples = 0
    var workouts = 0
    var days = 0
    var errors: [String] = []
    var startedAt = Date()
    var finishedAt = Date()
    var trigger: SyncTrigger = .manual
    var skipped = false

    var durationMs: Double { finishedAt.timeIntervalSince(startedAt) * 1000 }
}

/// What asked for the sync. Background runs are rate limited; a manual tap never is.
enum SyncTrigger: String, Sendable, Codable {
    case manual, foreground, background
}

enum SyncError: LocalizedError {
    case notConfigured
    case healthDataUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set the server URL and API token in Settings first."
        case .healthDataUnavailable: "Health data is not available on this device."
        }
    }
}

/// Reads HealthKit incrementally (anchored queries) and uploads changes to the server.
/// Concurrent callers (UI button, background observers) share one in-flight sync.
actor SyncEngine {
    static let shared = SyncEngine()

    let store = HKHealthStore()
    private var current: Task<SyncReport, Error>?
    private var observersStarted = false
    private var activeObservers: [HKObserverQuery] = []

    private static var pageSize: Int { AppConfig.pageSize }
    private static var uploadChunk: Int { AppConfig.uploadChunk }
    /// Workouts examined per sync for the raw-detail backfill, so a first run stays bounded.
    func shouldSkipBackgroundSync() -> Bool {
        guard SyncState.syncOnlyWhileCharging else { return false }
        return !Self.isCharging()
    }

    private static func isCharging() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return [.charging, .full].contains(UIDevice.current.batteryState)
    }

    /// Minimum gap between automatic syncs.
    private static var cooldownSeconds: TimeInterval { AppConfig.cooldownSeconds }
    private static var workoutDetailLimit: Int { CatalogStore.cached?.sync?.workoutDetailLimit ?? 40 }
    private static var recoveryTailSeconds: TimeInterval { CatalogStore.cached?.sync?.recoveryTailSeconds ?? 600 }

    // MARK: Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw SyncError.healthDataUnavailable }
        let types = HealthCatalog.readTypes
        try await store.requestAuthorization(toShare: [], read: types)
        CatalogStore.authorizedTypes = Set(types.map(\.identifier))
    }

    // MARK: Sync

    func sync(
        trigger: SyncTrigger = .manual,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SyncReport {
        if let current { return try await current.value }
        // HealthKit can fire several observers at once and a foreground return often lands right
        // after one; without this the same work runs repeatedly for nothing.
        if trigger != .manual, let last = SyncState.lastSyncAt, Date().timeIntervalSince(last) < Self.cooldownSeconds {
            var report = SyncReport()
            report.trigger = trigger
            report.skipped = true
            return report
        }
        let task = Task { try await self.performSync(trigger: trigger, progress: progress) }
        current = task
        defer { if current == task { current = nil } }
        return try await task.value
    }

    private func performSync(
        trigger: SyncTrigger,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> SyncReport {
        let settings = SyncSettings.load()
        guard let client = APIClient(settings: settings) else { throw SyncError.notConfigured }
        guard HKHealthStore.isHealthDataAvailable() else { throw SyncError.healthDataUnavailable }

        var report = SyncReport()
        report.trigger = trigger
        await refreshCatalog(client: client, progress: progress)
        await syncProfile(client: client, report: &report)

        let catalog = HealthCatalog.effective
        for skipped in catalog.skipped { report.errors.append("catalog: skipped \(skipped)") }

        // Workout windows up front, so samples recorded during a session are tagged as they are
        // uploaded. Without this the per-workout pass has to send the same samples a second time
        // purely to mark them, which is what made a 12 km run upload twice.
        let windows = (try? await workoutWindows(settings: settings)) ?? TimeWindows([])
        var changed: Set<String> = []

        for metric in catalog.quantities {
            do {
                SyncState.applyBackfillPolicy(metric.backfill, for: metric.key)
                // Aggregate-only metrics still run the anchored query — it is local and cheap, and
                // it is how we learn the metric changed — but nothing is uploaded.
                let tagWorkouts = HealthCatalog.isWorkoutDetail(metric.key) && !windows.isEmpty
                let (added, deleted) = try await drain(
                    key: metric.key,
                    predicate: .quantitySample(type: metric.type, predicate: Self.since(Self.start(metric.backfill, settings))),
                    client: client,
                    makeRequest: metric.uploadsRaw ? { samples, deleted in
                        SyncRequest(
                            samples: samples.map { sample in
                                var payload = Self.payload(sample, metric: metric)
                                if tagWorkouts, windows.contains(sample.startDate) { payload.context = "workout" }
                                return payload
                            },
                            deletedSamples: deleted.isEmpty ? nil : [DeletedSamples(type: metric.key, ids: deleted)]
                        )
                    } : nil
                )
                if added + deleted > 0 { changed.insert(metric.key) }
                report.samples += metric.uploadsRaw ? added : 0
                report.deletedSamples += deleted
                if added + deleted > 0 { progress("\(metric.key): \(added) new, \(deleted) deleted") }
            } catch {
                report.errors.append("\(metric.key): \(error.localizedDescription)")
            }
        }

        for metric in catalog.categories {
            do {
                SyncState.applyBackfillPolicy(metric.backfill, for: metric.key)
                let (added, deleted) = try await drain(
                    key: metric.key,
                    predicate: .categorySample(type: metric.type, predicate: Self.since(Self.start(metric.backfill, settings))),
                    client: client
                ) { samples, deleted in
                    SyncRequest(
                        samples: samples.map { Self.payload($0, metric: metric) },
                        deletedSamples: deleted.isEmpty ? nil : [DeletedSamples(type: metric.key, ids: deleted)]
                    )
                }
                if added + deleted > 0 { changed.insert(metric.key) }
                report.samples += added
                report.deletedSamples += deleted
                if added + deleted > 0 { progress("\(metric.key): \(added) new, \(deleted) deleted") }
            } catch {
                report.errors.append("\(metric.key): \(error.localizedDescription)")
            }
        }

        do {
            // Workouts are few and valuable, so they use the longer daily backfill window.
            let workoutSince = Date().addingTimeInterval(-Double(settings.dailyBackfillDays) * 86_400)
            let (added, _) = try await drain(
                key: "workouts",
                predicate: .workout(Self.since(workoutSince)),
                client: client
            ) { workouts, deleted in
                SyncRequest(
                    workouts: workouts.map(Self.payload),
                    deletedWorkoutIds: deleted.isEmpty ? nil : deleted
                )
            }
            report.workouts += added
            if added > 0 { progress("workouts: \(added)") }
        } catch {
            report.errors.append("workouts: \(error.localizedDescription)")
        }

        // Hourly buckets for the few metrics where the shape of the day matters. Only the last
        // few days are recomputed: older hours never change once the samples have landed.
        do {
            let hours = try await syncHourly(client: client, changed: changed, report: &report)
            if hours > 0 { progress("hourly buckets: \(hours) วัน") }
        } catch {
            report.errors.append("hourly: \(error.localizedDescription)")
        }

        // Daily aggregates and rings are recomputed for recent days every sync, since the Watch
        // can deliver samples late. The first sync backfills the full window.
        let days = SyncState.dailyBackfillDone ? 3 : settings.dailyBackfillDays
        do {
            report.days = try await syncDaily(days: days, client: client, changed: changed, report: &report)
            progress("daily summaries: \(report.days) days")
            if report.errors.isEmpty { SyncState.dailyBackfillDone = true }
        } catch {
            report.errors.append("daily: \(error.localizedDescription)")
        }

        // Raw heart rate and speed for workouts older than the raw window, so past runs can be
        // reviewed (drift, zones, splits) without carrying every heart-rate sample ever recorded.
        do {
            let detailed = try await syncWorkoutDetails(client: client, settings: settings, progress: progress)
            if detailed > 0 { progress("workout detail: \(detailed) workouts") }
        } catch {
            report.errors.append("workout detail: \(error.localizedDescription)")
        }

        report.finishedAt = Date()
        SyncState.lastSyncAt = report.finishedAt
        SyncState.remember(report)
        // Best effort: the history is nicer to have than the sync is to fail over.
        try? await client.recordSync(
            SyncLogPayload(
                startedAt: report.startedAt,
                durationMs: report.durationMs,
                trigger: trigger.rawValue,
                samples: report.samples,
                deletedSamples: report.deletedSamples,
                workouts: report.workouts,
                days: report.days,
                catalogVersion: CatalogStore.cached?.version,
                errors: report.errors.isEmpty ? nil : Array(report.errors.prefix(40))
            )
        )
        return report
    }

    /// For each workout in the backfill window that has not been covered yet, uploads the raw
    /// heart-rate and speed samples inside it plus a recovery tail. Anchored queries only keep the
    /// recent window for these high-volume types, so this fills in the parts that matter.
    private func syncWorkoutDetails(
        client: APIClient,
        settings: SyncSettings,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        let since = Date().addingTimeInterval(-Double(settings.dailyBackfillDays) * 86_400)
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(Self.since(since))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: Self.workoutDetailLimit
        )
        // Sessions inside the raw window were tagged during the main pass; fetching them again
        // would upload the same thousands of samples twice.
        let rawWindowStart = Self.start(.standard, settings)
        let workouts = try await query.result(for: store).filter { workout in
            guard !SyncState.workoutDetailDone(workout.uuid.uuidString) else { return false }
            if workout.startDate >= rawWindowStart {
                SyncState.markWorkoutDetailDone(workout.uuid.uuidString)
                return false
            }
            return true
        }
        guard !workouts.isEmpty else { return 0 }

        var done = 0
        for workout in workouts {
            let window = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate.addingTimeInterval(Self.recoveryTailSeconds)
            )
            var payloads: [SamplePayload] = []
            for metric in HealthCatalog.workoutDetailMetrics {
                let samples = try await HKSampleQueryDescriptor(
                    predicates: [.quantitySample(type: metric.type, predicate: window)],
                    sortDescriptors: [],
                    limit: Self.pageSize
                ).result(for: store)
                payloads += samples.map { sample in
                    var payload = Self.payload(sample, metric: metric)
                    payload.context = "workout"
                    return payload
                }
            }
            guard !payloads.isEmpty else {
                SyncState.markWorkoutDetailDone(workout.uuid.uuidString)
                continue
            }
            for chunk in stride(from: 0, to: payloads.count, by: Self.uploadChunk) {
                let slice = Array(payloads[chunk..<min(chunk + Self.uploadChunk, payloads.count)])
                try await client.sync(SyncRequest(samples: slice))
            }
            SyncState.markWorkoutDetailDone(workout.uuid.uuidString)
            done += 1
            progress("workout \(Self.dayKey(workout.startDate)): \(payloads.count) raw samples")
        }
        return done
    }

    /// Downloads the metric catalog and asks for any read permission it added. Without this a
    /// metric added server-side would sync nothing: HealthKit returns no data for a type that was
    /// never authorised, rather than prompting.
    private func refreshCatalog(client: APIClient, progress: @escaping @Sendable (String) -> Void) async {
        // `try?` folds both outcomes that mean "keep what we have": a 304, and a failed request.
        if let catalog = try? await client.catalog(knownVersion: CatalogStore.cached?.version) {
            CatalogStore.save(catalog)
            progress("catalog updated to \(catalog.version)")
        }
        await requestNewReadTypes()
    }

    /// Requests authorization for read types that have never been requested. iOS only shows the
    /// sheet for undetermined types, so this is a no-op once everything has been decided.
    func requestNewReadTypes(force: Bool = false) async {
        let types = HealthCatalog.readTypes
        let identifiers = Set(types.map(\.identifier))
        let pending = identifiers.subtracting(CatalogStore.authorizedTypes)
        guard force || !pending.isEmpty else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            CatalogStore.authorizedTypes = identifiers
        } catch {
            // Leave the record untouched so the next launch tries again.
        }
    }

    /// Uploads HealthKit characteristics (date of birth, biological sex) when they first become
    /// available or change. They give the server the age and sex needed to read a VO2 max number.
    private func syncProfile(client: APIClient, report: inout SyncReport) async {
        var profile = ProfilePayload()
        if let components = try? store.dateOfBirthComponents(),
           let year = components.year, let month = components.month, let day = components.day {
            profile.dateOfBirth = String(format: "%04d-%02d-%02d", year, month, day)
        }
        switch try? store.biologicalSex().biologicalSex {
        case .female: profile.biologicalSex = "female"
        case .male: profile.biologicalSex = "male"
        case .other: profile.biologicalSex = "other"
        default: break
        }
        guard profile != ProfilePayload(), profile != SyncState.lastProfile else { return }
        do {
            try await client.sync(SyncRequest(profile: profile))
            SyncState.lastProfile = profile
        } catch {
            report.errors.append("profile: \(error.localizedDescription)")
        }
    }

    /// Pages through an anchored query, uploading each page before saving the new anchor,
    /// so an upload failure is retried on the next sync.
    /// `makeRequest` of nil advances the anchor without uploading: used by aggregate-only
    /// metrics, where the query still tells us something changed.
    private func drain<S: HKSample>(
        key: String,
        predicate: HKSamplePredicate<S>,
        client: APIClient,
        makeRequest: (([S], [String]) -> SyncRequest)?
    ) async throws -> (added: Int, deleted: Int) {
        var anchor = SyncState.anchor(for: key)
        var added = 0
        var deleted = 0
        while true {
            let query = HKAnchoredObjectQueryDescriptor(predicates: [predicate], anchor: anchor, limit: Self.pageSize)
            let result = try await query.result(for: store)
            let deletedIds = result.deletedObjects.map(\.uuid.uuidString)
            if let makeRequest, !result.addedSamples.isEmpty || !deletedIds.isEmpty {
                try await client.sync(makeRequest(result.addedSamples, deletedIds))
            }
            SyncState.setAnchor(result.newAnchor, for: key)
            anchor = result.newAnchor
            added += result.addedSamples.count
            deleted += deletedIds.count
            if result.addedSamples.count + result.deletedObjects.count < Self.pageSize { break }
        }
        return (added, deleted)
    }

    /// Workout time spans inside the raw window, padded by the recovery tail. Samples that land
    /// in one are tagged on their way up, so the per-workout pass has nothing left to re-send
    /// for recent sessions.
    private func workoutWindows(settings: SyncSettings) async throws -> TimeWindows {
        let since = Self.start(.standard, settings)
        let workouts = try await HKSampleQueryDescriptor(
            predicates: [.workout(Self.since(since))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: Self.workoutDetailLimit
        ).result(for: store)
        return TimeWindows(workouts.map {
            ($0.startDate, $0.endDate.addingTimeInterval(Self.recoveryTailSeconds))
        })
    }

    /// Uploads per-hour statistics for the metrics flagged `hourly` in the catalog. One document
    /// per day on the server holds all 24 slots, so a year costs 365 documents.
    private func syncHourly(client: APIClient, changed: Set<String>, report: inout SyncReport) async throws -> Int {
        let hourly = HealthCatalog.effective.quantities.filter { HealthCatalog.isHourly($0.key) }
        let wanted = Set(Recompute.metrics(all: hourly.map(\.key), changed: changed, backfilling: !SyncState.dailyBackfillDone))
        let metrics = hourly.filter { wanted.contains($0.key) }
        guard !metrics.isEmpty else { return 0 }

        let calendar = Calendar.current
        let days = CatalogStore.cached?.sync?.hourlyRecomputeDays ?? 3
        let end = Date()
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: end)!)

        var stats: [HourlyStatPayload] = []
        for metric in metrics {
            let options: HKStatisticsOptions = metric.aggregation == .cumulative
                ? .cumulativeSum
                : [.discreteAverage, .discreteMin, .discreteMax]
            let query = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: metric.type, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
                options: options,
                anchorDate: start,
                intervalComponents: DateComponents(hour: 1)
            )
            let unit = metric.unit
            for s in try await query.result(for: store).statistics() {
                let sum = s.sumQuantity()?.doubleValue(for: unit)
                let avg = s.averageQuantity()?.doubleValue(for: unit)
                guard sum != nil || avg != nil else { continue }
                stats.append(
                    HourlyStatPayload(
                        date: Self.dayKey(s.startDate),
                        hour: calendar.component(.hour, from: s.startDate),
                        type: metric.key,
                        unit: unit.unitString,
                        sum: sum,
                        avg: avg,
                        min: s.minimumQuantity()?.doubleValue(for: unit),
                        max: s.maximumQuantity()?.doubleValue(for: unit)
                    )
                )
            }
        }
        guard !stats.isEmpty else { return 0 }
        for chunk in stride(from: 0, to: stats.count, by: Self.uploadChunk) {
            let slice = Array(stats[chunk..<min(chunk + Self.uploadChunk, stats.count)])
            try await client.sync(SyncRequest(hourlyStats: slice))
        }
        return Set(stats.map(\.date)).count
    }

    private func syncDaily(days: Int, client: APIClient, changed: Set<String>, report: inout SyncReport) async throws -> Int {
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: end)!)

        // Recomputing all 36 metrics took six to ten seconds of statistics queries on every
        // sync, however little had changed.
        let all = HealthCatalog.effective.quantities
        let wanted = Set(Recompute.metrics(all: all.map(\.key), changed: changed, backfilling: !SyncState.dailyBackfillDone))
        var stats: [DailyStatPayload] = []
        for metric in all where wanted.contains(metric.key) {
            do {
                stats += try await dailyStats(metric, from: start, to: end)
            } catch {
                // Missing permission or no data for a type is not fatal for the others.
                if (error as? HKError)?.code != .errorNoData {
                    report.errors.append("daily \(metric.key): \(error.localizedDescription)")
                }
            }
        }
        let rings = try await activitySummaries(from: start, to: end)

        var dates = Set(rings.map(\.date))
        guard !stats.isEmpty || !rings.isEmpty else { return 0 }
        for chunk in stride(from: 0, to: max(stats.count, 1), by: Self.uploadChunk) {
            let slice = Array(stats[chunk..<min(chunk + Self.uploadChunk, stats.count)])
            slice.forEach { dates.insert($0.date) }
            try await client.sync(SyncRequest(dailyStats: slice, activitySummaries: chunk == 0 ? rings : nil))
        }
        return dates.count
    }

    private func dailyStats(_ metric: QuantityMetric, from start: Date, to end: Date) async throws -> [DailyStatPayload] {
        let options: HKStatisticsOptions = metric.aggregation == .cumulative
            ? .cumulativeSum
            : [.discreteAverage, .discreteMin, .discreteMax]
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: metric.type, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await query.result(for: store)
        let unit = metric.unit
        return collection.statistics().compactMap { s in
            let payload = DailyStatPayload(
                date: Self.dayKey(s.startDate),
                type: metric.key,
                unit: unit.unitString,
                sum: s.sumQuantity()?.doubleValue(for: unit),
                avg: s.averageQuantity()?.doubleValue(for: unit),
                min: s.minimumQuantity()?.doubleValue(for: unit),
                max: s.maximumQuantity()?.doubleValue(for: unit)
            )
            return payload.sum == nil && payload.avg == nil ? nil : payload
        }
    }

    private func activitySummaries(from start: Date, to end: Date) async throws -> [ActivitySummaryPayload] {
        let calendar = Calendar.current
        var startComponents = calendar.dateComponents([.era, .year, .month, .day], from: start)
        var endComponents = calendar.dateComponents([.era, .year, .month, .day], from: end)
        startComponents.calendar = calendar
        endComponents.calendar = calendar
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startComponents, end: endComponents)
        let summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: store)

        return summaries.compactMap { s in
            guard let day = calendar.date(from: s.dateComponents(for: calendar)) else { return nil }
            return ActivitySummaryPayload(
                date: Self.dayKey(day),
                moveMode: s.activityMoveMode == .appleMoveTime ? "moveTime" : "activeEnergy",
                activeEnergyKcal: s.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                activeEnergyGoalKcal: s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
                moveMinutes: s.appleMoveTime.doubleValue(for: .minute()),
                moveMinutesGoal: s.appleMoveTimeGoal.doubleValue(for: .minute()),
                exerciseMinutes: s.appleExerciseTime.doubleValue(for: .minute()),
                exerciseMinutesGoal: s.exerciseTimeGoal?.doubleValue(for: .minute()),
                standHours: s.appleStandHours.doubleValue(for: .count()),
                standHoursGoal: s.standHoursGoal?.doubleValue(for: .count())
            )
        }
    }

    // MARK: Background delivery

    /// Registers observer queries so HealthKit wakes the app when new data arrives.
    func startBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable(), SyncState.backgroundDeliveryEnabled, !observersStarted else { return }
        observersStarted = true

        let catalog = HealthCatalog.effective
        let types: [(HKSampleType, HKUpdateFrequency)] =
            catalog.quantities.map { ($0.type, .hourly) }
            + catalog.categories.map { ($0.type, .hourly) }
            + [(HKObjectType.workoutType(), .immediate)]

        for (type, frequency) in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    // Honour the battery preference: a background wake while off charge is skipped,
                    // and the next foreground sync picks the data up anyway.
                    if await SyncEngine.shared.shouldSkipBackgroundSync() { completion(); return }
                    _ = try? await SyncEngine.shared.sync(trigger: .background)
                    completion()
                }
            }
            activeObservers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in }
        }
    }

    /// Stops HealthKit waking the app. Observer queries already running are released too, so
    /// nothing fires until background delivery is switched back on.
    func stopBackgroundDelivery() {
        observersStarted = false
        store.disableAllBackgroundDelivery { _, _ in }
        for query in activeObservers { store.stop(query) }
        activeObservers.removeAll()
    }

    // MARK: Mapping

    private static func since(_ date: Date) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: date, end: nil)
    }

    /// First sync reaches back this far; after that the anchor takes over.
    private static func start(_ backfill: Backfill, _ settings: SyncSettings) -> Date {
        switch backfill {
        case .standard: Date().addingTimeInterval(-Double(settings.sampleBackfillDays) * 86_400)
        case .extended: Date().addingTimeInterval(-Double(HealthCatalog.extendedBackfillDays) * 86_400)
        case .all: .distantPast
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static func device(_ sample: HKSample) -> String? {
        sample.device?.model ?? sample.device?.name
    }

    private static func payload(_ s: HKQuantitySample, metric: QuantityMetric) -> SamplePayload {
        SamplePayload(
            id: s.uuid.uuidString,
            type: metric.key,
            kind: "quantity",
            value: s.quantity.doubleValue(for: metric.unit),
            unit: metric.unit.unitString,
            startDate: s.startDate,
            endDate: s.endDate,
            sourceName: s.sourceRevision.source.name,
            sourceBundleId: s.sourceRevision.source.bundleIdentifier,
            device: device(s),
            metadata: MetaValue.from(s.metadata)
        )
    }

    private static func payload(_ s: HKCategorySample, metric: CategoryMetric) -> SamplePayload {
        SamplePayload(
            id: s.uuid.uuidString,
            type: metric.key,
            kind: "category",
            value: Double(s.value),
            valueLabel: metric.label(s.value),
            startDate: s.startDate,
            endDate: s.endDate,
            sourceName: s.sourceRevision.source.name,
            sourceBundleId: s.sourceRevision.source.bundleIdentifier,
            device: device(s),
            metadata: MetaValue.from(s.metadata)
        )
    }

    private static func payload(_ w: HKWorkout) -> WorkoutPayload {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRate = w.statistics(for: HKQuantityType(.heartRate))
        let distanceTypes: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceDownhillSnowSports, .distanceWheelchair,
        ]
        let distance = distanceTypes.lazy
            .compactMap { w.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }
            .first
        let speed = [HKQuantityTypeIdentifier.runningSpeed, .cyclingSpeed].lazy
            .compactMap { w.statistics(for: HKQuantityType($0))?.averageQuantity()?.doubleValue(for: .meter().unitDivided(by: .second())) }
            .first

        return WorkoutPayload(
            id: w.uuid.uuidString,
            activityType: w.workoutActivityType.rawValue,
            activityTypeName: w.workoutActivityType.name,
            startDate: w.startDate,
            endDate: w.endDate,
            durationSec: w.duration,
            activeEnergyKcal: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            distanceM: distance,
            avgHeartRate: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            minHeartRate: heartRate?.minimumQuantity()?.doubleValue(for: bpm),
            maxHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: bpm),
            stepCount: w.statistics(for: HKQuantityType(.stepCount))?.sumQuantity()?.doubleValue(for: .count()),
            avgRunningPowerW: w.statistics(for: HKQuantityType(.runningPower))?.averageQuantity()?.doubleValue(for: .watt()),
            avgSpeedMps: speed,
            elevationAscendedM: (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            isIndoor: w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool,
            sourceName: w.sourceRevision.source.name,
            sourceBundleId: w.sourceRevision.source.bundleIdentifier,
            device: device(w),
            metadata: MetaValue.from(w.metadata)
        )
    }
}
