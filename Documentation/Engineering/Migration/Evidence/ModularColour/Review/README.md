# Final Modular review follow-up

The Select predictor used signed absolute value after wrapping subtraction. Transformed Int32 working planes can contain the minimum signed value before final sample validation, causing that operation to trap. Unsigned magnitude preserves the existing wrapping subtraction and comparison while representing that magnitude safely.

The retained test checks 216 extreme neighbourhood combinations against widened reference arithmetic and a complete public 2×2 RGB stream with identity RCT. The malformed variant now reaches defined precision rejection in both allocating and caller-storage decode; the caller destination is invalidated. A valid control still decodes exact samples. Scoped debug passed two declarations / three cases; the affected ASan run passed 22 declarations / 132 cases with no skips or diagnostics. These precede gradient-loop adoption; final combined qualification is separate. No failing input or safety result is silently excluded.
