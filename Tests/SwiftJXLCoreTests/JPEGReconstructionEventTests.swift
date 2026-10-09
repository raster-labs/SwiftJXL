// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct JPEGReconstructionEventTests {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let name: String
            let resetPoints: [[UInt32]]
            let extraZeroRuns: [[[UInt32]]]
        }
        let fixtures: [Entry]
    }
    private func fixture(_ name: String, _ ext: String, directory: String = "JPEGEvents") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: directory))
        return try Data(contentsOf: url)
    }

    @Test(arguments: ["sequential-extra-zero", "progressive-split", "progressive-grouped",
                      "progressive-restart-split", "progressive-band-zero"])
    func explicitEntropyVectorsAndIndependentReconstructionAgree(_ name: String) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: fixture("manifest", "json"))
        let expected = try #require(manifest.fixtures.first { $0.name == name })
        let decoded = try JPEGCoefficientDecoder.decode(fixture(name, "jpg"), policy: JPEGCoefficientPolicy())
        let oracle = try JBRDBoxReader.read(fixture(name, "jbrd"), policy: JBRDPolicy()).box
        #expect(decoded.scans.count == expected.resetPoints.count)
        #expect(decoded.scans.map(\.resetPoints) == expected.resetPoints)
        #expect(decoded.scans.map { $0.extraZeroRuns.map { [$0.blockIdx, $0.numExtraZeroRuns] } } == expected.extraZeroRuns)
        try compare(decoded.scans, oracle.scanInfo)
    }

    @Test(arguments: ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail", "fill-marker",
                      "progressive-edge", "progressive-restart", "progressive-422", "progressive-440",
                      "progressive-dc-refine", "sequential-multiscan"])
    func existingCorpusScansMatchIndependentJBRD(_ name: String) throws {
        let decoded = try JPEGCoefficientDecoder.decode(fixture(name, "jpg", directory: "JPEG"), policy: JPEGCoefficientPolicy())
        let oracle = try JBRDBoxReader.read(fixture(name, "jbrd", directory: "JBRD"), policy: JBRDPolicy()).box
        try compare(decoded.scans, oracle.scanInfo)
    }

    private func compare(_ scans: [JBRDScanInfo], _ expected: [JBRDScanInfo]) throws {
        try #require(scans.count == expected.count)
        for (actual, reference) in zip(scans, expected) {
            #expect(actual.ss == reference.ss && actual.se == reference.se)
            #expect(actual.ah == reference.ah && actual.al == reference.al)
            #expect(actual.components == reference.components)
            #expect(actual.numComponents == reference.numComponents)
            #expect(actual.resetPoints == reference.resetPoints)
            #expect(actual.extraZeroRuns == reference.extraZeroRuns)
        }
    }

    @Test func cumulativeEventLimitAdmitsExactBoundaryAndRejectsBeforePublication() throws {
        let data = try fixture("progressive-split", "jpg")
        let result = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy(maximumScanEvents: 6))
        #expect(result.scans.reduce(0) { $0 + $1.resetPoints.count + $1.extraZeroRuns.count } == 6)
        for limit in [1, 5] {
            #expect(throws: JPEGEntropyError.resourceLimit) {
                try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy(maximumScanEvents: limit))
            }
        }
        for limit in [0, 65537, Int.max] {
            #expect(throws: JPEGEntropyError.resourceLimit) { try JPEGCoefficientPolicy(maximumScanEvents: limit) }
        }
    }

    @Test func unrepresentableRefinementZeroRunIsExplicitlyRejected() throws {
        #expect(throws: JPEGEntropyError.unsupported) {
            try JPEGCoefficientDecoder.decode(fixture("refinement-extra-zero-unsupported", "jpg"),
                                             policy: JPEGCoefficientPolicy())
        }
    }
}
