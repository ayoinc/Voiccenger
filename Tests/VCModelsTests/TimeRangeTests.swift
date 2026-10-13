import Testing
@testable import VCModels

@Suite struct TimeRangeTests {
    @Test func overlapOfDisjointRangesIsZero() {
        #expect(TimeRange(start: 0, end: 1).overlap(with: TimeRange(start: 2, end: 3)) == 0)
    }

    @Test func overlapIsIntersectionLength() {
        #expect(TimeRange(start: 0, end: 2).overlap(with: TimeRange(start: 1.5, end: 3)) == 0.5)
    }

    @Test func endBeforeStartClampsToEmpty() {
        #expect(TimeRange(start: 2, end: 1).duration == 0)
    }

    @Test func circularGeometryApertureIsDiameter() {
        let g = MicArrayGeometry.circular(name: "c4", count: 4, radius: 0.05)
        #expect(abs(g.aperture - 0.1) < 1e-9)
    }
}
