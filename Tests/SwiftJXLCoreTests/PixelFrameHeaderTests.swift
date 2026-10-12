// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct PixelFrameHeaderTests {
    private func budget() throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 64 * 1024 * 1024,
            maximumMemoryBytes: 64 * 1024 * 1024, maximumDecodedBytes: 64 * 1024 * 1024,
            maximumCompressedBytes: 4 * 1024 * 1024, deadline: .now.advanced(by: .seconds(30)))
    }
    private func fixture(_ name: String, _ directory: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jxl", subdirectory: directory))
        return try Data(contentsOf: url)
    }

    @Test(arguments: [false, true], [false, true])
    func dispatchAndConveniencePreserveAdmission(_ xyb: Bool, _ icc: Bool) throws {
        let data = try fixture(xyb ? (icc ? "grayscale" : "pred-17-3-8") : (icc ? "icc-3-8" : "premult-4-8"),
            xyb ? (icc ? "VarDCT/Conformance" : "VarDCT") : (icc ? "Modular/ICC" : "Modular/Alpha"))
        let sharedBudget = try budget(), directBudget = try budget()
        let header = try PixelFrameHeader.read(data, budget: sharedBudget)
        #expect(header.metadata.xybEncoded == xyb)
        #expect(header.metadata.colorEncoding.useICC == icc)
        let position = header.reader.position
        if xyb {
            let selected = try VarDCTFrameEnvelope.read(header)
            let direct = try VarDCTFrameEnvelope.read(data, budget: directBudget)
            #expect(selected.width == direct.width && selected.height == direct.height)
            #expect(selected.iccProfile == direct.iccProfile && selected.frame == direct.frame)
            #expect(selected.sectionCount == direct.sectionCount)
        } else {
            let selected = try ModularFrameDecoder.prepare(header)
            let direct = try ModularFrameDecoder.prepare(data, budget: directBudget)
            #expect(selected.width == direct.width && selected.height == direct.height)
            #expect(selected.iccProfile == direct.iccProfile)
            #expect(selected.alphaAssociated == direct.alphaAssociated)
            #expect(selected.transferFunction == direct.transferFunction)
        }
        // Selecting a profile must not parse/re-admit the input a second time.
        #expect(sharedBudget.reservedWorkspaceBytes == directBudget.reservedWorkspaceBytes)
        #expect(header.reader.position == position)
    }

    @Test(arguments: [false, true])
    func selectedProfileStillEnforcesICCLimits(_ xyb: Bool) throws {
        let data = try fixture(xyb ? "grayscale" : "icc-1-16", xyb ? "VarDCT/Conformance" : "Modular/ICC")
        for metadataLimit in [false, true] {
            let header = try PixelFrameHeader.read(data, budget: budget())
            #expect(throws: ScalarModularError.self) {
                if xyb {
                    _ = try VarDCTFrameEnvelope.read(header, maximumICCBytes: metadataLimit ? 4096 : 1,
                        maximumMetadataBytes: metadataLimit ? 1 : 4096)
                } else {
                    _ = try ModularFrameDecoder.prepare(header, maximumICCBytes: metadataLimit ? 4096 : 1,
                        maximumMetadataBytes: metadataLimit ? 1 : 4096)
                }
            }
        }
    }

    @Test func sharedPreparationRejectsBoundsAndTruncation() throws {
        let data = try fixture("pred-17-3-8", "VarDCT")
        #expect(throws: ScalarModularError.self) { try PixelFrameHeader.read(data, budget: budget(), maximumDimension: 16) }
        #expect(throws: ScalarModularError.self) { try PixelFrameHeader.read(data, budget: budget(), maximumPixels: 152) }
        #expect(throws: ScalarModularError.self) { try PixelFrameHeader.read(data, budget: budget(), maximumNestingDepth: 0) }
        #expect(throws: (any Error).self) { try PixelFrameHeader.read(Data(data.prefix(2)), budget: budget()) }
        let header = try PixelFrameHeader.read(data, budget: budget(), maximumDimension: 17, maximumPixels: 153)
        #expect(header.width == 17 && header.height == 9)
    }

    @Test(arguments: [false, true])
    func cancellationBetweenHeaderAndProfileRejects(_ xyb: Bool) async throws {
        let data = try fixture(xyb ? "pred-17-3-8" : "premult-4-8", xyb ? "VarDCT" : "Modular/Alpha")
        let header = try PixelFrameHeader.read(data, budget: budget())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            if xyb { _ = try VarDCTFrameEnvelope.read(header) }
            else { _ = try ModularFrameDecoder.prepare(header) }
        }
        do { try await task.value; Issue.record("Cancelled profile preparation succeeded") }
        catch is CancellationError { }
    }
}
