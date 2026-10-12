// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTColourTests {
    private struct Anchor: Decodable { let rgb: [Double], xyb: [Double] }
    @Test func highPrecisionDefinitionAnchors() throws {
        let url = try #require(Bundle.module.url(forResource: "opsin-anchors", withExtension: "json", subdirectory: "VarDCT"))
        let anchors = try JSONDecoder().decode([Anchor].self, from: Data(contentsOf: url))
        for a in anchors {
            let actual = try DefaultOpsin.forward((a.rgb[0], a.rgb[1], a.rgb[2]))
            #expect(abs(actual.X - a.xyb[0]) < 1e-12)
            #expect(abs(actual.Y - a.xyb[1]) < 1e-12)
            #expect(abs(actual.B - a.xyb[2]) < 1e-12)
        }
    }

    @Test func defaultMatrixRoundTripAndPrimaryAnchors() throws {
        for r in 0...16 { for g in 0...16 { for b in 0...16 {
            let input = (Double(r) / 16, Double(g) / 16, Double(b) / 16)
            let xyb = try DefaultOpsin.forward(input)
            let rgb = try DefaultOpsin.inverse(xyb)
            #expect(abs(rgb.R - input.0) < 0.000002)
            #expect(abs(rgb.G - input.1) < 0.000002)
            #expect(abs(rgb.B - input.2) < 0.000002)
        } } }
        let black = try DefaultOpsin.forward((0, 0, 0))
        #expect(abs(black.X) < 1e-12 && abs(black.Y) < 1e-12 && abs(black.B) < 1e-12)
        let white = try DefaultOpsin.forward((1, 1, 1))
        #expect(abs(white.X) < 1e-12)
        #expect(abs(white.Y - white.B) < 1e-12)
        // Inverse output is linear, unclipped RGB. The frame layer must apply
        // the declared transfer and quantisation once, not clamp this stage.
        let high = try DefaultOpsin.inverse((0, 1.5, 1.5))
        #expect(high.R > 1 && high.G > 1 && high.B > 1)
    }

    @Test func invalidSamplesRejectWithoutImplicitClamping() {
        for value: Double in [.nan, .infinity, -.infinity, -0.01, 1.01] {
            #expect(throws: (any Error).self) { try DefaultOpsin.forward((value, 0, 0)) }
        }
        for value: Double in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            #expect(throws: (any Error).self) { try DefaultOpsin.inverse((value, 0, 0)) }
        }
    }
}
