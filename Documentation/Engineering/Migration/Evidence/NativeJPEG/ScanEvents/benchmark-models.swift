import Foundation
package struct JBRDScanInfo: Sendable, Equatable {
    package var ss: UInt32        // Spectral start (Ss)
    package var se: UInt32        // Spectral end (Se)
    package var ah: UInt32        // Approximation high
    package var al: UInt32        // Approximation low
    package var numComponents: UInt32
    package var components: [JBRDScanComponent]
    package var lastNeededPass: UInt32
    package var resetPoints: [UInt32]
    package var extraZeroRuns: [JBRDExtraZeroRun]
    package init(
        ss: UInt32 = 0, se: UInt32 = 63,
        ah: UInt32 = 0, al: UInt32 = 0,
        numComponents: UInt32 = 1,
        components: [JBRDScanComponent] = [],
        lastNeededPass: UInt32 = 0,
        resetPoints: [UInt32] = [],
        extraZeroRuns: [JBRDExtraZeroRun] = []
    ) {
        self.ss = ss; self.se = se
        self.ah = ah; self.al = al
        self.numComponents = numComponents
        self.components = components
        self.lastNeededPass = lastNeededPass
        self.resetPoints = resetPoints
        self.extraZeroRuns = extraZeroRuns
    }
}

package struct JBRDScanComponent: Sendable, Equatable {
    package var compIdx: UInt32
    package var dcTblIdx: UInt32
    package var acTblIdx: UInt32
    package init(
        compIdx: UInt32 = 0, dcTblIdx: UInt32 = 0,
        acTblIdx: UInt32 = 0
    ) {
        self.compIdx = compIdx
        self.dcTblIdx = dcTblIdx
        self.acTblIdx = acTblIdx
    }
}

package struct JBRDExtraZeroRun: Sendable, Equatable {
    package var blockIdx: UInt32
    package var numExtraZeroRuns: UInt32
    package init(blockIdx: UInt32 = 0, numExtraZeroRuns: UInt32 = 1) {
        self.blockIdx = blockIdx
        self.numExtraZeroRuns = numExtraZeroRuns
    }
}

