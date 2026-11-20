# Third-party notices

## Pitchy 4.1.0

The app includes a native Swift adaptation of the McLeod pitch detector from [Pitchy 4.1.0](https://www.npmjs.com/package/pitchy/v/4.1.0), Copyright 2018–2021 Ian Johnson, under the MIT terms in [ThirdParty/Pitchy-4.1.0-LICENSE.txt](ThirdParty/Pitchy-4.1.0-LICENSE.txt). The complete MIT notice appears in Settings. These terms apply to the adaptation in `Sources/TunerDSP/PitchAlgorithms.swift`.

The adaptation computes normalized square difference using scoped vDSP correlation and prefix-sum energy, selects a key maximum, and refines its lag parabolically. Application limits include a 0.8 clarity floor, a profile frequency range, a four-cycle minimum, and a 32,768-sample bound. The Watch app bundles no JavaScript runtime or npm package. The optional host comparison uses a separately installed `pitchy@4.1.0` package and its notices.

## App icon

The bundled sine-wave artwork was generated for Watch Tuner with ChatGPT image generation. The three overlaid waves were developed from a single-wave image generated for the same project. The Watch target uses the result in an Icon Composer document and keeps a 1024-pixel asset-catalog rendition. Embedded PNG metadata was removed while preserving the image data.
