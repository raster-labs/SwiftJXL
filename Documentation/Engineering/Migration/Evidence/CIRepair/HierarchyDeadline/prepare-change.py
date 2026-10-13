from pathlib import Path
repo=Path('/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public')
p=repo/'Tests/SwiftJXLCoreTests/VarDCTHierarchicalAnalysisTests.swift'
s=p.read_text()
s=s.replace('private func budget(_ maximum: Int = 256 * 1024 * 1024) throws -> ScalarOperationBudget {','''private func budget(_ maximum: Int = 256 * 1024 * 1024,
                        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
                        cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {''')
s=s.replace('maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))','maximumCompressedBytes: maximum, deadline: deadline, cancellation: cancellation)')
a=s.index('    @Test func nestedQuantisationAndGroupBoundaries() throws {')
b=s.index('    @Test(arguments: [4,5,6,7,8,9,10,11,18,19,20])',a)
s=s[:a]+'''    private func texturedPlanes(width: Int, height: Int) -> [[Float]] {
        // A smooth first cell and textured later cells give different local
        // adaptive QFs, exposing accidental re-quantisation of nested leaves.
        var planes = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 3)
        for y in 0..<height { for x in 0..<width {
            let value: Float = x % 64 < 8 && y % 64 < 8 ? 0.3 : Float((x * 17 + y * 13) % 31) / 40
            planes[0][y * width + x] = value / 8
            planes[1][y * width + x] = value
            planes[2][y * width + x] = value * 1.4
        } }
        return planes
    }
    private func checkStrategyMap(_ result: VarDCTHierarchicalAnalysis.Result,
                                  width: Int, height: Int, budget: ScalarOperationBudget) throws {
        let bx = (width + 7) / 8, by = (height + 7) / 8
        let map = try VarDCTStrategyMap.read(result.strategies + result.quantisation.map { $0 - 1 },
            count: result.transforms.count, width: bx, height: by, budget: budget)
        #expect(map.transforms == result.transforms)
        #expect(result.ac.allSatisfy { $0.count == bx * by * 64 })
        #expect(map.indices.count == bx * by)
        #expect(map.indices.allSatisfy { $0 >= 0 && $0 < result.transforms.count })
        for (index, transform) in result.transforms.enumerated() {
            #expect(transform.x % 32 + transform.cellsX <= 32)
            #expect(transform.y % 32 + transform.cellsY <= 32)
            for y in transform.y..<(transform.y + transform.cellsY) {
                for x in transform.x..<(transform.x + transform.cellsX) {
                    #expect(map.indices[y * bx + x] == index)
                }
            }
        }
    }
    @Test func nestedLeavesInheritRegionQuantisation() throws {
        // One full search region isolates QF inheritance. Group boundaries are
        // checked separately below, avoiding four duplicate textured searches
        // inside a single 30-second correctness-test operation under TSan.
        let width = 64, height = 64, planes = texturedPlanes(width: width, height: height)
        let operation = try budget()
        let result = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
            scale: 5111, distance: 1, adaptiveQuantisation: true, budget: operation)
        try checkStrategyMap(result, width: width, height: height, budget: operation)
        let firstPatch = planes.map { plane in (0..<64).map { plane[($0 / 8) * width + $0 % 8] } }
        let laterPatch = planes.map { plane in (0..<64).map { plane[($0 / 8) * width + 8 + $0 % 8] } }
        let firstQF = try VarDCTEncoderPreparation.quantisation(firstPatch, distance: 1)
        let laterQF = try VarDCTEncoderPreparation.quantisation(laterPatch, distance: 1)
        #expect(firstQF < laterQF)
        #expect(result.transforms.count > 1)
        #expect(result.transforms.allSatisfy { $0.quantisation == UInt32(firstQF) })
    }
    @Test(arguments: [false, true])
    func groupBoundariesAndPartialCells(_ vertical: Bool) throws {
        // Cross the 256-pixel AC-group boundary in both orientations, including
        // a partial final cell in the other dimension. Keep each independent
        // operation under the same deadline as every other hierarchy test.
        let width = vertical ? 17 : 264, height = vertical ? 264 : 17
        let operation = try budget()
        let result = try VarDCTHierarchicalAnalysis.analyse(texturedPlanes(width: width, height: height),
            width: width, height: height, scale: 5111, distance: 1,
            adaptiveQuantisation: true, budget: operation)
        try checkStrategyMap(result, width: width, height: height, budget: operation)
        #expect(result.transforms.contains { vertical ? $0.y == 32 : $0.x == 32 })
        #expect(result.transforms.contains { vertical ? $0.x == 2 : $0.y == 2 })
    }
    @Test func expiredAndCancelledSearchRejectBeforeWorkspaceAdmission() throws {
        let planes = [[Float]](repeating: [Float](repeating: 0.375, count: 256), count: 3)
        let expired = try budget(deadline: .now.advanced(by: .seconds(-1)))
        #expect(throws: ScalarModularError.resourceLimit) {
            try VarDCTHierarchicalAnalysis.analyse(planes, width: 16, height: 16,
                scale: 5111, distance: 1, adaptiveQuantisation: true, budget: expired)
        }
        #expect(expired.reservedWorkspaceBytes == 0)
        let cancellation = ScalarOperationCancellation(), cancelled = try budget(cancellation: cancellation)
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try VarDCTHierarchicalAnalysis.analyse(planes, width: 16, height: 16,
                scale: 5111, distance: 1, adaptiveQuantisation: true, budget: cancelled)
        }
        #expect(cancelled.reservedWorkspaceBytes == 0)
    }
''' +s[b:]
Path(__file__).with_name('candidate.swift').write_text(s)
print('Prepared candidate test changes without editing the running baseline.')
