#if !WATCHTUNER_APP
#error("Compile this smoke check with WATCHTUNER_APP")
#endif

@main
struct WatchProductionSmoke {
    static func main() {
        precondition(PitchAlgorithm.allCases == [.mcleod], "Watch builds must expose only McLeod")
        precondition(PitchAlgorithm.mcleod.code == 3, "McLeod must keep capture code 3")
        for code: UInt64 in [0, 1, 2, 3, 4, UInt64.max] {
            precondition(PitchAlgorithm(code: code) == .mcleod, "Watch decoding must select McLeod")
        }
        for profile in TunerProfile.allCases {
            precondition(PitchConfiguration.production(profile: profile).algorithm == .mcleod,
                         "Every production profile must select McLeod")
        }
        print("PASS: WATCHTUNER_APP exposes only McLeod; code 3, six decoded codes and all production profiles verified")
    }
}
