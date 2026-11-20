# Silent Pitchy comparison harness

Generated samples only; the harness is not linked into the Watch app and opens no audio device. It compares the retained native harmonic/noise-aware methods and native McLeod estimator, then optionally runs the same buffers through the original published Pitchy 4.1.0. Rejection and wrong pitches are reported separately. A result within 8 cents is a diagnostic criterion, not an acoustic accuracy claim. Harmonic-related mixtures do not prove source separation.

Compile from the repository root with `swiftc -O -swift-version 6 Sources/TunerDSP/*.swift Tools/PitchComparison/main.swift -o /tmp/watch-pitch-comparison`, then run that executable to write its JSON to a local JSON file. No extra Swift source or package is required.

For the upstream comparison, supply a local Node environment with the exact `pitchy@4.1.0` package and its MIT notice, copy `compare.mjs` beside that environment’s `node_modules`, and run `node /path/to/host-environment/compare.mjs input.json output.json`. That optional host dependency is not a Watch dependency. The native path retains the application’s range, four-cycle and clarity bounds; upstream output is shown separately.

Run `python3 Scripts/audit-pitch-dependencies.py --help` for source and optional built-bundle checks.
