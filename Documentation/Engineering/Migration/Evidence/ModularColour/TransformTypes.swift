// SPDX-License-Identifier: Apache-2.0
// Migration validation harness; not production codec code.
package enum ModularTransformId: UInt32, Sendable, Equatable {
    case rct     = 0
    case palette = 1
    case squeeze = 2
}

/// One Modular transform applied to the image before per-channel
/// prediction. We parse the metadata for each known kind and store
/// it; pixel-application is the next milestone.
package struct ModularTransform: Sendable, Equatable {
    package let id: ModularTransformId
    /// For RCT and Palette: starting channel index.
    package let beginC: UInt32
    /// For RCT: type 0..41 (default 6 = YCoCg).
    package let rctType: UInt32
    /// For Palette: number of channels covered.
    package let numC: UInt32
    /// For Palette: number of palette colours.
    package let nbColors: UInt32
    /// For Palette: number of delta entries.
    package let nbDeltas: UInt32
    /// For Palette: predictor index (libjxl modular predictor).
    package let palettePredictor: UInt32
    /// For Squeeze: per-step squeeze parameters. Empty means default
    /// squeeze pattern (libjxl computes it from the channel layout).
    package let squeezes: [SqueezeParams]

    package init(
        id: ModularTransformId,
        beginC: UInt32 = 0,
        rctType: UInt32 = 6,
        numC: UInt32 = 3,
        nbColors: UInt32 = 256,
        nbDeltas: UInt32 = 0,
        palettePredictor: UInt32 = 0,
        squeezes: [SqueezeParams] = []
    ) {
        self.id = id
        self.beginC = beginC
        self.rctType = rctType
        self.numC = numC
        self.nbColors = nbColors
        self.nbDeltas = nbDeltas
        self.palettePredictor = palettePredictor
        self.squeezes = squeezes
    }

    /// Per-step squeeze parameters when the transform is a Squeeze.
    package struct SqueezeParams: Sendable, Equatable {
        package let horizontal: Bool
        package let inPlace: Bool
        package let beginC: UInt32
        package let numC: UInt32

        package init(
            horizontal: Bool = false, inPlace: Bool = false,
            beginC: UInt32 = 0, numC: UInt32 = 2
        ) {
            self.horizontal = horizontal; self.inPlace = inPlace
            self.beginC = beginC; self.numC = numC
        }

    }
}
