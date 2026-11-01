import hashlib, os, sys, plistlib
root = sys.argv[1]  # .../ios
src = os.path.join(root, "ServerMonitor")
def uid(s): return hashlib.md5(s.encode()).hexdigest()[:24].upper()
swift = sorted(os.path.relpath(os.path.join(d,f), src) for d,_,fs in os.walk(src) for f in fs if f.endswith(".swift"))
objs = []
def add(k, body): objs.append((k, body))
P = uid("project"); T = uid("target"); MG = uid("maingroup"); SG = uid("srcgroup"); PG = uid("products")
APP = uid("app.ref"); SRCP = uid("phase.src"); RESP = uid("phase.res"); FWP = uid("phase.fw")
PCL = uid("cfglist.proj"); TCL = uid("cfglist.target")
PD, PR, TD, TR = uid("cfg.pd"), uid("cfg.pr"), uid("cfg.td"), uid("cfg.tr")
PKG = uid("pkg.citadel"); PKGP = uid("pkgprod.citadel"); PKGBF = uid("pkgbf.citadel")
PKG2 = uid("pkg.swiftterm"); PKGP2 = uid("pkgprod.swiftterm"); PKGBF2 = uid("pkgbf.swiftterm")
files = []  # (ref, build, name, type, phase)
for f in swift: files.append((uid("ref"+f), uid("bf"+f), f, "sourcecode.swift", "src"))
for f, t in [("Assets.xcassets","folder.assetcatalog"),("Resources/Agent","folder")]:
    files.append((uid("ref"+f), uid("bf"+f), f, t, "res"))
extra = [("Info.plist","text.plist.xml"),("ServerMonitor.entitlements","text.plist.entitlements")]
for f,t in extra: files.append((uid("ref"+f), None, f, t, None))
q = lambda s: '"%s"' % s
lines = []
for ref,_,f,t,_ in files:
    lines.append(f'\t\t{ref} = {{isa = PBXFileReference; lastKnownFileType = {t}; path = {q(f)}; sourceTree = "<group>"; }};')
lines.append(f'\t\t{APP} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ServerMonitor.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
for ref,bf,f,_,ph in files:
    if bf: lines.append(f'\t\t{bf} = {{isa = PBXBuildFile; fileRef = {ref}; }};')
lines.append(f'\t\t{PKGBF} = {{isa = PBXBuildFile; productRef = {PKGP}; }};')
lines.append(f'\t\t{PKGBF2} = {{isa = PBXBuildFile; productRef = {PKGP2}; }};')
ch = ", ".join(r for r,*_ in files)
lines.append(f'\t\t{MG} = {{isa = PBXGroup; children = ({SG}, {PG}); sourceTree = "<group>"; }};')
lines.append(f'\t\t{SG} = {{isa = PBXGroup; children = ({ch}); path = ServerMonitor; sourceTree = "<group>"; }};')
lines.append(f'\t\t{PG} = {{isa = PBXGroup; children = ({APP}); name = Products; sourceTree = "<group>"; }};')
srcs = ", ".join(bf for _,bf,_,_,ph in files if ph=="src")
ress = ", ".join(bf for _,bf,_,_,ph in files if ph=="res")
lines.append(f'\t\t{SRCP} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({srcs}); runOnlyForDeploymentPostprocessing = 0; }};')
lines.append(f'\t\t{RESP} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ress}); runOnlyForDeploymentPostprocessing = 0; }};')
lines.append(f'\t\t{FWP} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({PKGBF}, {PKGBF2}); runOnlyForDeploymentPostprocessing = 0; }};')
lines.append(f'\t\t{PKG} = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/orlandos-nl/Citadel.git"; requirement = {{kind = upToNextMinorVersion; minimumVersion = 0.12.0; }}; }};')
lines.append(f'\t\t{PKGP} = {{isa = XCSwiftPackageProductDependency; package = {PKG}; productName = Citadel; }};')
lines.append(f'\t\t{PKG2} = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/migueldeicaza/SwiftTerm.git"; requirement = {{kind = exactVersion; version = 1.10.1; }}; }};')
lines.append(f'\t\t{PKGP2} = {{isa = XCSwiftPackageProductDependency; package = {PKG2}; productName = SwiftTerm; }};')
lines.append(f'\t\t{T} = {{isa = PBXNativeTarget; buildConfigurationList = {TCL}; buildPhases = ({SRCP}, {FWP}, {RESP}); buildRules = (); dependencies = (); name = ServerMonitor; packageProductDependencies = ({PKGP}, {PKGP2}); productName = ServerMonitor; productReference = {APP}; productType = "com.apple.product-type.application"; }};')
lines.append(f'\t\t{P} = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }}; buildConfigurationList = {PCL}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {MG}; packageReferences = ({PKG}, {PKG2}); productRefGroup = {PG}; projectDirPath = ""; projectRoot = ""; targets = ({T}); }};')
common = 'ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; ENABLE_USER_SCRIPT_SANDBOXING = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = minimal;'
lines.append(f'\t\t{PD} = {{isa = XCBuildConfiguration; buildSettings = {{{common} DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; GCC_OPTIMIZATION_LEVEL = 0; ONLY_ACTIVE_ARCH = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; }}; name = Debug; }};')
lines.append(f'\t\t{PR} = {{isa = XCBuildConfiguration; buildSettings = {{{common} DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; SWIFT_COMPILATION_MODE = wholemodule; VALIDATE_PRODUCT = YES; }}; name = Release; }};')
ts = 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; CODE_SIGN_ENTITLEMENTS = ServerMonitor/ServerMonitor.entitlements; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 3; DEVELOPMENT_TEAM = 3DML5X8547; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = ServerMonitor/Info.plist; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks"); MARKETING_VERSION = 0.3.0; PRODUCT_BUNDLE_IDENTIFIER = eu.appinsource.servermonitor; PRODUCT_NAME = "$(TARGET_NAME)"; TARGETED_DEVICE_FAMILY = 1;'
lines.append(f'\t\t{TD} = {{isa = XCBuildConfiguration; buildSettings = {{{ts}}}; name = Debug; }};')
lines.append(f'\t\t{TR} = {{isa = XCBuildConfiguration; buildSettings = {{{ts}}}; name = Release; }};')
lines.append(f'\t\t{PCL} = {{isa = XCConfigurationList; buildConfigurations = ({PD}, {PR}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
lines.append(f'\t\t{TCL} = {{isa = XCConfigurationList; buildConfigurations = ({TD}, {TR}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
out = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 60;\n\tobjects = {\n" + "\n".join(lines) + f"\n\t}};\n\trootObject = {P};\n}}\n"
pd = os.path.join(root, "ServerMonitor.xcodeproj"); os.makedirs(pd, exist_ok=True)
open(os.path.join(pd, "project.pbxproj"), "w").write(out)
# Info.plist + entitlements
info = {"CFBundleDevelopmentRegion":"$(DEVELOPMENT_LANGUAGE)","CFBundleExecutable":"$(EXECUTABLE_NAME)","CFBundleIdentifier":"$(PRODUCT_BUNDLE_IDENTIFIER)",
 "CFBundleInfoDictionaryVersion":"6.0","CFBundleName":"$(PRODUCT_NAME)","CFBundleDisplayName":"Server Monitor","CFBundlePackageType":"$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
 "CFBundleShortVersionString":"$(MARKETING_VERSION)","CFBundleVersion":"$(CURRENT_PROJECT_VERSION)","LSRequiresIPhoneOS":True,"UILaunchScreen":{},
 "UIUserInterfaceStyle":"Dark","UISupportedInterfaceOrientations":["UIInterfaceOrientationPortrait"],"UIBackgroundModes":["remote-notification"],
 "NSFaceIDUsageDescription":"Unlock Server Monitor, which holds SSH access to your servers.","ITSAppUsesNonExemptEncryption":False,
 "UIApplicationSceneManifest":{"UIApplicationSupportsMultipleScenes":False},
 "CFBundleURLTypes":[{"CFBundleURLName":"eu.appinsource.servermonitor.join","CFBundleURLSchemes":["srvmon"]}]}
plistlib.dump(info, open(os.path.join(src,"Info.plist"),"wb"))
plistlib.dump({}, open(os.path.join(src,"ServerMonitor.entitlements"),"wb"))  # personal team: no push
# shared scheme
sd = os.path.join(pd, "xcshareddata", "xcschemes"); os.makedirs(sd, exist_ok=True)
br = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{T}" BuildableName="ServerMonitor.app" BlueprintName="ServerMonitor" ReferencedContainer="container:ServerMonitor.xcodeproj"></BuildableReference>'
open(os.path.join(sd,"ServerMonitor.xcscheme"),"w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{br}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"></TestAction>
<LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{br}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{br}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
''')
print(len(swift), "swift files")
