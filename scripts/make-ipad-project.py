#!/usr/bin/env python3
"""Writes iPad/XRay.xcodeproj: the iPad app target, built from the iPad's own files in iPad/XRay
and the macOS app's views in Sources/S2AClaudeXRay (all but the files listed in MAC_ONLY), with
XRayCore from this repository's Swift package.

Run it after adding, removing or renaming a Swift file in either folder:
    python3 scripts/make-ipad-project.py
CI fails when the committed project is out of date.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "iPad", "XRay.xcodeproj")
SHARED = os.path.join(ROOT, "Sources", "S2AClaudeXRay")
IPAD = os.path.join(ROOT, "iPad", "XRay")

VERSION = "0.9.0"
BUNDLE_ID = "com.s2a.claude-xray.ipad"
DEPLOYMENT = "17.0"

# macOS only: the app and menu bar scenes, the receiver, the status line, FSEvents, panels.
MAC_ONLY = {
    "S2AClaudeXRayApp.swift",
    "App/AppEntry.swift",
    "App/DirectoryWatcher.swift",
    "App/SnapshotRunner.swift",
    "App/StatusLine.swift",
    "App/TailscaleAddress.swift",
    "App/TranscriptReceiver.swift",
    "Views/CloudReceiverView.swift",
    "Views/IPadAccessView.swift",
    "Views/MenuBarView.swift",
    "Views/ReportsView.swift",
    "Views/SourcesHelpView.swift",
}


def uid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def swift_files(base):
    found = []
    for folder, dirs, files in os.walk(base):
        dirs.sort()
        for name in sorted(files):
            if name.endswith(".swift"):
                found.append(os.path.relpath(os.path.join(folder, name), base).replace(os.sep, "/"))
    return found


def quote(value):
    if value and all(c.isalnum() or c in "._/" for c in value) and not value[0].isdigit():
        return value
    if value.replace(".", "").isdigit() and value.count(".") <= 1:
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def settings(values, indent="\t\t\t\t"):
    lines = []
    for key in sorted(values):
        value = values[key]
        if isinstance(value, list):
            lines.append(f"{indent}{key} = (")
            lines += [f"{indent}\t{quote(v)}," for v in value]
            lines.append(f"{indent});")
        else:
            lines.append(f"{indent}{key} = {quote(value)};")
    return "\n".join(lines)


def main():
    shared = [f for f in swift_files(SHARED) if f not in MAC_ONLY]
    missing = sorted(MAC_ONLY - set(swift_files(SHARED)))
    if missing:
        raise SystemExit(f"MAC_ONLY lists files that do not exist: {missing}")
    ipad = swift_files(IPAD)

    app = uid("product", "XRay.app")
    target = uid("target", "XRay")
    project = uid("project")
    main_group = uid("group", "main")
    products = uid("group", "Products")
    ipad_group = uid("group", "XRay")
    shared_group = uid("group", "Shared")
    sources_phase = uid("phase", "sources")
    frameworks_phase = uid("phase", "frameworks")
    resources_phase = uid("phase", "resources")
    package = uid("package", "..")
    product_dep = uid("product-dependency", "XRayCore")
    core_build = uid("build", "XRayCore")
    assets_ref = uid("file", "XRay/Assets.xcassets")
    assets_build = uid("build", "XRay/Assets.xcassets")
    plist_ref = uid("file", "XRay/Info.plist")
    project_list = uid("config-list", "project")
    target_list = uid("config-list", "target")
    configs = {(scope, name): uid("config", scope, name) for scope in ("project", "target") for name in ("Debug", "Release")}

    build_files, file_refs, source_entries = [], [], []

    def add_source(group, path):
        ref, build = uid("file", group, path), uid("build", group, path)
        name = os.path.basename(path)
        file_refs.append(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(name)}; sourceTree = \"<group>\"; }};")
        build_files.append(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
        source_entries.append(f"\t\t\t\t{build} /* {name} in Sources */,")
        return ref, name

    # Groups mirror the folders: every subfolder of a group is a group of its own.
    groups = {}

    def place(group_key, root_ref, files):
        children = {"": []}
        for path in files:
            ref, name = add_source(group_key, path)
            folder = os.path.dirname(path)
            children.setdefault(folder, []).append((ref, name))
            parent = folder
            while parent:
                upper = os.path.dirname(parent)
                children.setdefault(upper, [])
                entry = (uid("group", group_key, parent), os.path.basename(parent) + "/")
                if entry not in children[upper]:
                    children[upper].append(entry)
                parent = upper
        for folder, entries in children.items():
            ref = root_ref if folder == "" else uid("group", group_key, folder)
            groups[ref] = (folder, sorted(entries, key=lambda e: (not e[1].endswith("/"), e[1].lower())))

    place("Shared", shared_group, shared)
    place("XRay", ipad_group, ipad)

    build_files.append(f"\t\t{core_build} /* XRayCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {product_dep} /* XRayCore */; }};")
    build_files.append(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};")
    file_refs.append(f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};")
    file_refs.append(f"\t\t{plist_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    file_refs.append(f"\t\t{app} /* XRay.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = XRay.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

    group_lines = []

    def group_block(ref, comment, children, extra):
        lines = [f"\t\t{ref} /* {comment} */ = {{", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
        lines += [f"\t\t\t\t{child} /* {name} */," for child, name in children]
        lines += ["\t\t\t);"] + [f"\t\t\t{k} = {v};" for k, v in extra] + ['\t\t\tsourceTree = "<group>";', "\t\t};"]
        group_lines.extend(lines)

    group_block(main_group, "main", [(ipad_group, "XRay"), (shared_group, "Shared"), (products, "Products")], [])
    for ref, (folder, entries) in sorted(groups.items()):
        children = [(child, name.rstrip("/")) for child, name in entries]
        if ref == ipad_group:
            children = children + [(assets_ref, "Assets.xcassets"), (plist_ref, "Info.plist")]
            group_block(ref, "XRay", children, [("path", "XRay")])
        elif ref == shared_group:
            group_block(ref, "Shared", children, [("name", "Shared"), ("path", quote("../Sources/S2AClaudeXRay"))])
        else:
            name = os.path.basename(folder)
            group_block(ref, name, children, [("path", quote(name))])
    group_block(products, "Products", [(app, "XRay.app")], [("name", "Products")])

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    project_debug = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    })
    target_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "XRay/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "X-Ray",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.developer-tools",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "2",
    }

    def config(ref, name, values):
        return "\n".join([
            f"\t\t{ref} /* {name} */ = {{",
            "\t\t\tisa = XCBuildConfiguration;",
            "\t\t\tbuildSettings = {",
            settings(values),
            "\t\t\t};",
            f"\t\t\tname = {name};",
            "\t\t};",
        ])

    out = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {",
        "\t};",
        "\tobjectVersion = 60;",
        "\tobjects = {",
        "",
        "/* Begin PBXBuildFile section */",
        *sorted(build_files),
        "/* End PBXBuildFile section */",
        "",
        "/* Begin PBXFileReference section */",
        *sorted(file_refs),
        "/* End PBXFileReference section */",
        "",
        "/* Begin PBXFrameworksBuildPhase section */",
        f"\t\t{frameworks_phase} /* Frameworks */ = {{",
        "\t\t\tisa = PBXFrameworksBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        f"\t\t\t\t{core_build} /* XRayCore in Frameworks */,",
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXFrameworksBuildPhase section */",
        "",
        "/* Begin PBXGroup section */",
        *group_lines,
        "/* End PBXGroup section */",
        "",
        "/* Begin PBXNativeTarget section */",
        f"\t\t{target} /* XRay */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {target_list} /* Build configuration list for PBXNativeTarget \"XRay\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{sources_phase} /* Sources */,",
        f"\t\t\t\t{frameworks_phase} /* Frameworks */,",
        f"\t\t\t\t{resources_phase} /* Resources */,",
        "\t\t\t);",
        "\t\t\tbuildRules = (",
        "\t\t\t);",
        "\t\t\tdependencies = (",
        "\t\t\t);",
        "\t\t\tname = XRay;",
        "\t\t\tpackageProductDependencies = (",
        f"\t\t\t\t{product_dep} /* XRayCore */,",
        "\t\t\t);",
        "\t\t\tproductName = XRay;",
        f"\t\t\tproductReference = {app} /* XRay.app */;",
        "\t\t\tproductType = \"com.apple.product-type.application\";",
        "\t\t};",
        "/* End PBXNativeTarget section */",
        "",
        "/* Begin PBXProject section */",
        f"\t\t{project} /* Project object */ = {{",
        "\t\t\tisa = PBXProject;",
        "\t\t\tattributes = {",
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
        "\t\t\t\tLastSwiftUpdateCheck = 1500;",
        "\t\t\t\tLastUpgradeCheck = 1500;",
        "\t\t\t\tTargetAttributes = {",
        f"\t\t\t\t\t{target} = {{",
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;",
        "\t\t\t\t\t};",
        "\t\t\t\t};",
        "\t\t\t};",
        f"\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject \"XRay\" */;",
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";",
        "\t\t\tdevelopmentRegion = en;",
        "\t\t\thasScannedForEncodings = 0;",
        "\t\t\tknownRegions = (",
        "\t\t\t\ten,",
        "\t\t\t\tBase,",
        "\t\t\t\tde,",
        "\t\t\t\tru,",
        "\t\t\t);",
        f"\t\t\tmainGroup = {main_group};",
        "\t\t\tpackageReferences = (",
        f"\t\t\t\t{package} /* XCLocalSwiftPackageReference \"..\" */,",
        "\t\t\t);",
        f"\t\t\tproductRefGroup = {products} /* Products */;",
        "\t\t\tprojectDirPath = \"\";",
        "\t\t\tprojectRoot = \"\";",
        "\t\t\ttargets = (",
        f"\t\t\t\t{target} /* XRay */,",
        "\t\t\t);",
        "\t\t};",
        "/* End PBXProject section */",
        "",
        "/* Begin PBXResourcesBuildPhase section */",
        f"\t\t{resources_phase} /* Resources */ = {{",
        "\t\t\tisa = PBXResourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,",
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXResourcesBuildPhase section */",
        "",
        "/* Begin PBXSourcesBuildPhase section */",
        f"\t\t{sources_phase} /* Sources */ = {{",
        "\t\t\tisa = PBXSourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        *source_entries,
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXSourcesBuildPhase section */",
        "",
        "/* Begin XCBuildConfiguration section */",
        config(configs[("project", "Debug")], "Debug", project_debug),
        config(configs[("project", "Release")], "Release", project_release),
        config(configs[("target", "Debug")], "Debug", target_settings),
        config(configs[("target", "Release")], "Release", target_settings),
        "/* End XCBuildConfiguration section */",
        "",
        "/* Begin XCConfigurationList section */",
        f"\t\t{project_list} /* Build configuration list for PBXProject \"XRay\" */ = {{",
        "\t\t\tisa = XCConfigurationList;",
        "\t\t\tbuildConfigurations = (",
        f"\t\t\t\t{configs[('project', 'Debug')]} /* Debug */,",
        f"\t\t\t\t{configs[('project', 'Release')]} /* Release */,",
        "\t\t\t);",
        "\t\t\tdefaultConfigurationIsVisible = 0;",
        "\t\t\tdefaultConfigurationName = Release;",
        "\t\t};",
        f"\t\t{target_list} /* Build configuration list for PBXNativeTarget \"XRay\" */ = {{",
        "\t\t\tisa = XCConfigurationList;",
        "\t\t\tbuildConfigurations = (",
        f"\t\t\t\t{configs[('target', 'Debug')]} /* Debug */,",
        f"\t\t\t\t{configs[('target', 'Release')]} /* Release */,",
        "\t\t\t);",
        "\t\t\tdefaultConfigurationIsVisible = 0;",
        "\t\t\tdefaultConfigurationName = Release;",
        "\t\t};",
        "/* End XCConfigurationList section */",
        "",
        "/* Begin XCLocalSwiftPackageReference section */",
        f"\t\t{package} /* XCLocalSwiftPackageReference \"..\" */ = {{",
        "\t\t\tisa = XCLocalSwiftPackageReference;",
        "\t\t\trelativePath = ..;",
        "\t\t};",
        "/* End XCLocalSwiftPackageReference section */",
        "",
        "/* Begin XCSwiftPackageProductDependency section */",
        f"\t\t{product_dep} /* XRayCore */ = {{",
        "\t\t\tisa = XCSwiftPackageProductDependency;",
        f"\t\t\tpackage = {package} /* XCLocalSwiftPackageReference \"..\" */;",
        "\t\t\tproductName = XRayCore;",
        "\t\t};",
        "/* End XCSwiftPackageProductDependency section */",
        "\t};",
        f"\trootObject = {project} /* Project object */;",
        "}",
        "",
    ]
    os.makedirs(PROJECT, exist_ok=True)
    with open(os.path.join(PROJECT, "project.pbxproj"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))

    reference = "\n".join([
        "            <BuildableReference",
        '               BuildableIdentifier = "primary"',
        f'               BlueprintIdentifier = "{target}"',
        '               BuildableName = "XRay.app"',
        '               BlueprintName = "XRay"',
        '               ReferencedContainer = "container:XRay.xcodeproj">',
        "            </BuildableReference>",
    ])
    runnable = reference.replace("\n            ", "\n         ").replace("            <Buildable", "         <Buildable", 1)
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{reference}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Release"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{runnable}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{runnable}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    schemes = os.path.join(PROJECT, "xcshareddata", "xcschemes")
    os.makedirs(schemes, exist_ok=True)
    with open(os.path.join(schemes, "XRay.xcscheme"), "w", encoding="utf-8") as f:
        f.write(scheme)
    print(f"iPad/XRay.xcodeproj: {len(shared)} shared and {len(ipad)} iPad source files")


if __name__ == "__main__":
    main()
