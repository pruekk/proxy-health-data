import XCTest
@testable import ProxyHealthCore

/// The two things here that can be wrong without saying so: pace inverting into speed, and a
/// session carrying an alert it should not.
final class WorkoutRecipeTests: XCTestCase {

    // MARK: Pace inverts

    func testFasterPaceIsTheHigherSpeed() {
        // 7:14/km and 7:55/km. The faster of the two has to end up as the upper bound.
        let range = WorkoutRecipe.speedRange(paceSecPerKm: [434, 475])
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lowerBound, 1000.0 / 475, accuracy: 0.0001)
        XCTAssertEqual(range!.upperBound, 1000.0 / 434, accuracy: 0.0001)
        XCTAssertLessThan(range!.lowerBound, range!.upperBound)
    }

    func testOrderOfTheInputDoesNotMatter() {
        XCTAssertEqual(WorkoutRecipe.speedRange(paceSecPerKm: [475, 434]),
                       WorkoutRecipe.speedRange(paceSecPerKm: [434, 475]))
    }

    func testAPaceOfZeroIsRefusedRatherThanDividedBy() {
        XCTAssertNil(WorkoutRecipe.speedRange(paceSecPerKm: [0, 475]))
        XCTAssertNil(WorkoutRecipe.speedRange(paceSecPerKm: [434, 0]))
        XCTAssertNil(WorkoutRecipe.speedRange(paceSecPerKm: [-10, 475]))
    }

    func testAnIncompleteRangeIsRefused() {
        XCTAssertNil(WorkoutRecipe.speedRange(paceSecPerKm: nil))
        XCTAssertNil(WorkoutRecipe.speedRange(paceSecPerKm: [434]))
        XCTAssertNil(WorkoutRecipe.speedRange(paceSecPerKm: []))
    }

    func testASinglePaceIsStillAValidRange() {
        let range = WorkoutRecipe.speedRange(paceSecPerKm: [434, 434])
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lowerBound, range!.upperBound, accuracy: 0.0001)
    }

    // MARK: The heart-rate ceiling is a range only because the API has no threshold

    func testTheCeilingIsTheTopOfTheBand() {
        let band = WorkoutRecipe.heartRateBand(ceiling: 150)
        XCTAssertEqual(band.upperBound, 150)
        XCTAssertEqual(band.lowerBound, 100, "the floor sits far enough below to never fire while running")
    }

    func testTheFloorNeverGoesBelowAPlausiblePulse() {
        XCTAssertEqual(WorkoutRecipe.heartRateBand(ceiling: 90).lowerBound, 60)
    }

    // MARK: Policy per kind of session

    func testEasyWatchesTheHeartAndNotThePace() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "easy", zoneCeiling: 150), .heartRateCeiling(150))
    }

    func testLongAllowsForCardiacDrift() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "long", zoneCeiling: 150), .heartRateCeiling(155))
    }

    func testPaceSessionsJudgeAverageOrCurrentAccordingly() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "marathon", zoneCeiling: 150), .pace(average: true))
        XCTAssertEqual(WorkoutRecipe.policy(for: "threshold", zoneCeiling: 150), .pace(average: false))
    }

    func testIntervalKeepsPaceOffTheRecoveries() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "interval", zoneCeiling: 150), .paceOnWorkOnly)
    }

    func testRepetitionIsSilent() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "repetition", zoneCeiling: 150), .silent)
    }

    func testRestAndCrossAreNotHandedToTheWatch() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "rest", zoneCeiling: 150), .notSupported)
        XCTAssertEqual(WorkoutRecipe.policy(for: "cross", zoneCeiling: 150), .notSupported)
        XCTAssertEqual(WorkoutRecipe.policy(for: "something-new", zoneCeiling: 150), .notSupported)
    }

    func testAnEasyRunWithoutZonesGoesOutSilentRatherThanGuessing() {
        XCTAssertEqual(WorkoutRecipe.policy(for: "easy", zoneCeiling: nil), .silent)
    }

    // MARK: Building

    private func easyPlan() -> [WorkoutRecipe.PlannedStep] {
        [
            .init(phase: "warmup", minutes: 15),
            .init(phase: "main", minutes: 40, paceSecPerKm: [434, 475]),
            .init(phase: "cooldown", minutes: 10),
            .init(phase: "stretch", minutes: 15),
        ]
    }

    func testAnEasyRunCarriesOneHeartRateAlertOnTheMainStepOnly() throws {
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "easy", displayName: "EASY", steps: easyPlan(), zoneCeiling: 150))

        XCTAssertEqual(recipe.warmup?.goal, .minutes(15))
        XCTAssertNil(recipe.warmup?.alert, "a floor would fire for the whole warmup, which is when being under it is right")
        XCTAssertEqual(recipe.blocks.count, 1)
        XCTAssertEqual(recipe.blocks[0].steps[0].step.alert, .heartRate(100...150))
        XCTAssertEqual(recipe.cooldown?.goal, .minutes(10))
        XCTAssertNil(recipe.cooldown?.alert)
    }

    func testTheStretchIsDroppedRatherThanTimedAsARun() throws {
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "easy", displayName: "EASY", steps: easyPlan(), zoneCeiling: 150))
        // warmup + one main + cooldown. The 15-minute stretch is nowhere.
        XCTAssertEqual(recipe.blocks.flatMap(\.steps).count, 1)
    }

    func testAnEasyRunDoesNotPickUpThePaceTheCoachWrote() throws {
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "easy", displayName: "EASY", steps: easyPlan(), zoneCeiling: 150))
        if case .speed = recipe.blocks[0].steps[0].step.alert {
            XCTFail("an easy run must not alert on pace even when the plan carries one")
        }
    }

    func testIntervalRepsBecomeOneRepeatedBlock() throws {
        let steps: [WorkoutRecipe.PlannedStep] = [
            .init(phase: "warmup", minutes: 15),
            .init(phase: "main", minutes: 2, paceSecPerKm: [425, 435]),
            .init(phase: "recovery", minutes: 2),
            .init(phase: "cooldown", minutes: 10),
        ]
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "interval", displayName: "INT", steps: steps, repeats: 4, zoneCeiling: 150))

        XCTAssertEqual(recipe.blocks.count, 1)
        XCTAssertEqual(recipe.blocks[0].iterations, 4)
        XCTAssertEqual(recipe.blocks[0].steps.count, 2)
        XCTAssertFalse(recipe.blocks[0].steps[0].isRecovery)
        XCTAssertTrue(recipe.blocks[0].steps[1].isRecovery)
        XCTAssertNotNil(recipe.blocks[0].steps[0].step.alert, "the work step keeps its pace")
        XCTAssertNil(recipe.blocks[0].steps[1].step.alert, "the recovery must stay quiet")
    }

    func testWithoutRepsEachStepIsItsOwnBlock() throws {
        let steps: [WorkoutRecipe.PlannedStep] = [
            .init(phase: "warmup", minutes: 10),
            .init(phase: "main", minutes: 20, paceSecPerKm: [400, 410]),
            .init(phase: "main", minutes: 20, paceSecPerKm: [390, 400]),
        ]
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "threshold", displayName: "THR", steps: steps, zoneCeiling: 150))
        XCTAssertEqual(recipe.blocks.count, 2)
        XCTAssertTrue(recipe.blocks.allSatisfy { $0.iterations == 1 })
    }

    func testADistanceStepKeepsItsDistance() throws {
        let steps: [WorkoutRecipe.PlannedStep] = [
            .init(phase: "warmup", minutes: 10),
            .init(phase: "main", distanceKm: 8, paceSecPerKm: [400, 420]),
        ]
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "marathon", displayName: "MAR", steps: steps, zoneCeiling: 150))
        XCTAssertEqual(recipe.blocks[0].steps[0].step.goal, .kilometres(8))
        XCTAssertEqual(recipe.blocks[0].steps[0].step.alert, .speed(1000.0/420...1000.0/400, average: true))
    }

    func testAStepWithNeitherTimeNorDistanceStaysOpen() throws {
        let steps: [WorkoutRecipe.PlannedStep] = [
            .init(phase: "warmup", minutes: 10),
            .init(phase: "main"),
        ]
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "easy", displayName: "EASY", steps: steps, zoneCeiling: 150))
        XCTAssertEqual(recipe.blocks[0].steps[0].step.goal, .open)
    }

    func testARestDayIsNotBuiltAtAll() {
        XCTAssertNil(WorkoutRecipe.build(
            type: "rest", displayName: "พัก", steps: [.init(phase: "main", minutes: 30)], zoneCeiling: 150))
    }

    func testADayWithNothingButStretchingIsNotBuilt() {
        XCTAssertNil(WorkoutRecipe.build(
            type: "easy", displayName: "EASY",
            steps: [.init(phase: "stretch", minutes: 20)], zoneCeiling: 150))
    }

    func testADayWithNoMainStepIsNotBuilt() {
        XCTAssertNil(WorkoutRecipe.build(
            type: "easy", displayName: "EASY",
            steps: [.init(phase: "warmup", minutes: 10), .init(phase: "cooldown", minutes: 10)],
            zoneCeiling: 150))
    }

    func testAPaceSessionWithoutAPaceSimplyCarriesNoAlert() throws {
        let steps: [WorkoutRecipe.PlannedStep] = [
            .init(phase: "warmup", minutes: 10),
            .init(phase: "main", minutes: 20),
        ]
        let recipe = try XCTUnwrap(WorkoutRecipe.build(
            type: "threshold", displayName: "THR", steps: steps, zoneCeiling: 150))
        XCTAssertNil(recipe.blocks[0].steps[0].step.alert)
    }
}
