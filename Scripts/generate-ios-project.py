#!/usr/bin/env python3
"""Generate the independent iOS app; never rewrites the Watch project."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'WatchTunerIOS.xcodeproj'
SOURCES = sorted([*ROOT.glob('IOS/*.swift'), *ROOT.glob('Sources/TunerDSP/*.swift')])
uid = lambda n: f'{n:024X}'
entries = []

def obj(number, body):
    entries.append(f'{uid(number)} = {{{body}}};')

for i, path in enumerate(SOURCES):
    obj(100+i, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.relative_to(ROOT)}"; sourceTree = SOURCE_ROOT;')
    obj(200+i, f'isa = PBXBuildFile; fileRef = {uid(100+i)};')
obj(1, f'isa = PBXProject; attributes = {{LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid(8)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {uid(2)}; productRefGroup = {uid(3)}; projectDirPath = ""; projectRoot = ""; targets = ({uid(4)});')
obj(2, f'isa = PBXGroup; children = ({", ".join(uid(100+i) for i in range(len(SOURCES)))}, {uid(14)}, {uid(17)}, {uid(3)}); sourceTree = "<group>";')
obj(3, f'isa = PBXGroup; children = ({uid(5)}); name = Products; sourceTree = "<group>";')
obj(4, f'isa = PBXNativeTarget; buildConfigurationList = {uid(9)}; buildPhases = ({uid(6)}, {uid(7)}, {uid(16)}); buildRules = (); dependencies = (); name = WatchTunerIOS; productName = WatchTunerIOS; productReference = {uid(5)}; productType = "com.apple.product-type.application";')
obj(5, 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Watch Tuner.app"; sourceTree = BUILT_PRODUCTS_DIR;')
obj(6, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(uid(200+i) for i in range(len(SOURCES)))}); runOnlyForDeploymentPostprocessing = 0;')
obj(7, 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj(14, 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = IOS/Assets.xcassets; sourceTree = SOURCE_ROOT;')
obj(15, f'isa = PBXBuildFile; fileRef = {uid(14)};')
obj(16, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid(15)}, {uid(18)}); runOnlyForDeploymentPostprocessing = 0;')
obj(17, 'isa = PBXFileReference; lastKnownFileType = text; path = ThirdParty/Pitchy-4.1.0-LICENSE.txt; sourceTree = SOURCE_ROOT;')
obj(18, f'isa = PBXBuildFile; fileRef = {uid(17)};')
obj(8, f'isa = XCConfigurationList; buildConfigurations = ({uid(10)}, {uid(11)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj(9, f'isa = XCConfigurationList; buildConfigurations = ({uid(12)}, {uid(13)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for number, name in [(10, 'Debug'), (11, 'Release')]:
    optimization = '-Onone' if name == 'Debug' else '-O'
    obj(number, f'isa = XCBuildConfiguration; buildSettings = {{CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "{optimization}"; SDKROOT = iphoneos; }}; name = {name};')
settings = '''ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = IOS/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 18.0; MARKETING_VERSION = 0.1; PRODUCT_BUNDLE_IDENTIFIER = local.watchtuner.ios; PRODUCT_NAME = "Watch Tuner"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = NO; SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO; TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_STRICT_CONCURRENCY = complete; ENABLE_USER_SCRIPT_SANDBOXING = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'''
for number, name in [(12, 'Debug'), (13, 'Release')]:
    obj(number, f'isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name};')
PROJECT.mkdir(exist_ok=True)
(PROJECT / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(entries) + f'\n}}; rootObject = {uid(1)}; }}\n')
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(4)}" BuildableName="Watch Tuner.app" BlueprintName="WatchTunerIOS" ReferencedContainer="container:WatchTunerIOS.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_path = PROJECT / 'xcshareddata/xcschemes'
scheme_path.mkdir(parents=True, exist_ok=True)
(scheme_path / 'WatchTunerIOS.xcscheme').write_text(scheme)
print(f'Generated {PROJECT.name} with {len(SOURCES)} Swift source files')
