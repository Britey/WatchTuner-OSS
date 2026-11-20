#!/usr/bin/env python3
"""Dependency-free, deterministic Xcode project generation for this standalone Watch app."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
# Keep legacy harmonic implementations in SwiftPM/host tools, outside Watch builds.
historical_sources = {'PitchDetector.swift', 'HarmonicSpectrum.swift', 'VocalPeriodEstimator.swift'}
sources = sorted([*root.glob('App/*.swift'),
                  *(p for p in root.glob('Sources/TunerDSP/*.swift') if p.name not in historical_sources)])
uid = lambda n: f'{n:024X}'
entries=[]
for i, path in enumerate(sources):
    entries += [f'{uid(100+i)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.relative_to(root)}"; sourceTree = SOURCE_ROOT; }};', f'{uid(200+i)} = {{isa = PBXBuildFile; fileRef = {uid(100+i)}; }};']
entries += [
f'{uid(1)} = {{isa = PBXProject; attributes = {{LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid(8)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {uid(2)}; productRefGroup = {uid(3)}; projectDirPath = ""; projectRoot = ""; targets = ({uid(4)}); }};',
f'{uid(2)} = {{isa = PBXGroup; children = ({", ".join(uid(100+i) for i in range(len(sources)))}, {uid(14)}, {uid(17)}, {uid(3)}); sourceTree = "<group>"; }};',
f'{uid(3)} = {{isa = PBXGroup; children = ({uid(5)}); name = Products; sourceTree = "<group>"; }};',
f'{uid(4)} = {{isa = PBXNativeTarget; buildConfigurationList = {uid(9)}; buildPhases = ({uid(6)}, {uid(7)}, {uid(16)}); buildRules = (); dependencies = (); name = WatchTuner; productName = WatchTuner; productReference = {uid(5)}; productType = "com.apple.product-type.application"; }};',
f'{uid(5)} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Watch Tuner.app"; sourceTree = BUILT_PRODUCTS_DIR; }};',
f'{uid(6)} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(uid(200+i) for i in range(len(sources)))}); runOnlyForDeploymentPostprocessing = 0; }};',
f'{uid(7)} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
f'{uid(14)} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = App/Assets.xcassets; sourceTree = SOURCE_ROOT; }};',
f'{uid(15)} = {{isa = PBXBuildFile; fileRef = {uid(14)}; }};',
f'{uid(16)} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid(15)}, {uid(18)}); runOnlyForDeploymentPostprocessing = 0; }};',
f'{uid(17)} = {{isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = App/WatchTunerIcon.icon; sourceTree = SOURCE_ROOT; }};',
f'{uid(18)} = {{isa = PBXBuildFile; fileRef = {uid(17)}; }};',
f'{uid(8)} = {{isa = XCConfigurationList; buildConfigurations = ({uid(10)}, {uid(11)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};',
f'{uid(9)} = {{isa = XCConfigurationList; buildConfigurations = ({uid(12)}, {uid(13)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};']
for num,name in [(10,'Debug'),(11,'Release')]:
    entries.append(f'{uid(num)} = {{isa = XCBuildConfiguration; buildSettings = {{CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "{ "-Onone" if name == "Debug" else "-O"}"; SDKROOT = watchos; }}; name = {name}; }};')
settings='''ASSETCATALOG_COMPILER_APPICON_NAME = WatchTunerIcon; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = App/Info.plist; INFOPLIST_KEY_CFBundleDisplayName = "Watch Tuner"; INFOPLIST_KEY_NSMicrophoneUsageDescription = "When you tap Start, Watch Tuner uses the microphone to show pitch, even with your wrist down, until you tap Stop. Audio is processed only on your Watch and is not recorded."; INFOPLIST_KEY_WKApplication = YES; INFOPLIST_KEY_WKWatchOnly = YES; MARKETING_VERSION = 0.1; PRODUCT_BUNDLE_IDENTIFIER = local.watchtuner.utility; PRODUCT_NAME = "Watch Tuner"; SUPPORTED_PLATFORMS = "watchos watchsimulator"; TARGETED_DEVICE_FAMILY = 4; WATCHOS_DEPLOYMENT_TARGET = 11.0; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) WATCHTUNER_APP"; ENABLE_USER_SCRIPT_SANDBOXING = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'''
for num,name in [(12,'Debug'),(13,'Release')]:
    entries.append(f'{uid(num)} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};')
(root/'WatchTuner.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(entries)+f'\n}}; rootObject = {uid(1)}; }}\n')
(root/'WatchTuner.xcodeproj/xcshareddata/xcschemes/WatchTuner.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(4)}" BuildableName="Watch Tuner.app" BlueprintName="WatchTuner" ReferencedContainer="container:WatchTuner.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(4)}" BuildableName="Watch Tuner.app" BlueprintName="WatchTuner" ReferencedContainer="container:WatchTuner.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')

# Dedicated Watch UI smoke-test target; does not capture the host microphone.
pbx=root/'WatchTuner.xcodeproj/project.pbxproj'
s=pbx.read_text().replace(f'targets = ({uid(4)});', f'targets = ({uid(4)}, {uid(30)});')
s=s.replace(f'{uid(2)} = {{isa = PBXGroup; children = (', f'{uid(2)} = {{isa = PBXGroup; children = ({uid(31)}, ')
s=s.replace(f'{uid(3)} = {{isa = PBXGroup; children = ({uid(5)});', f'{uid(3)} = {{isa = PBXGroup; children = ({uid(5)}, {uid(32)});')
ui=[
f'{uid(30)} = {{isa = PBXNativeTarget; buildConfigurationList = {uid(36)}; buildPhases = ({uid(34)}, {uid(35)}); buildRules = (); dependencies = ({uid(40)}); name = WatchTunerUITests; productName = WatchTunerUITests; productReference = {uid(32)}; productType = "com.apple.product-type.bundle.ui-testing"; }};',
f'{uid(31)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/WatchTunerUITests.swift; sourceTree = SOURCE_ROOT; }};',
f'{uid(32)} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = WatchTunerUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};',
f'{uid(33)} = {{isa = PBXBuildFile; fileRef = {uid(31)}; }};',
f'{uid(34)} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uid(33)}); runOnlyForDeploymentPostprocessing = 0; }};',
f'{uid(35)} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
f'{uid(36)} = {{isa = XCConfigurationList; buildConfigurations = ({uid(37)}, {uid(38)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};',
f'{uid(39)} = {{isa = PBXContainerItemProxy; containerPortal = {uid(1)}; proxyType = 1; remoteGlobalIDString = {uid(4)}; remoteInfo = WatchTuner; }};',
f'{uid(40)} = {{isa = PBXTargetDependency; target = {uid(4)}; targetProxy = {uid(39)}; }};']
for num,name in [(37,'Debug'),(38,'Release')]:
 ui.append(f'{uid(num)} = {{isa = XCBuildConfiguration; buildSettings = {{CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = local.watchtuner.utility.uitests; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = watchos; SUPPORTED_PLATFORMS = "watchos watchsimulator"; TARGETED_DEVICE_FAMILY = 4; WATCHOS_DEPLOYMENT_TARGET = 11.0; TEST_TARGET_NAME = WatchTuner; SWIFT_VERSION = 6.0; }}; name = {name}; }};')
s=s.replace('objects = {\n','objects = {\n'+'\n'.join(ui)+'\n')
pbx.write_text(s)
scheme=root/'WatchTuner.xcodeproj/xcshareddata/xcschemes/WatchTuner.xcscheme'
s=scheme.read_text().replace('<LaunchAction', f'<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(30)}" BuildableName="WatchTunerUITests.xctest" BlueprintName="WatchTunerUITests" ReferencedContainer="container:WatchTuner.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction')
scheme.write_text(s)
