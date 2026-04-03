//
//  PreviewHostGenerator.swift
//  SwiftUIPreviewKit
//
//  Generates a minimal Xcode project that renders a single #Preview body expression.
//

import CryptoKit
import Foundation

public actor PreviewHostGenerator: PreviewHostGeneratorProtocol {

  public init() {}

  // MARK: - PreviewHostGeneratorProtocol

  public func generateHostProject(
    for preview: PreviewDeclaration,
    userDerivedDataPath: String,
    scheme: String
  ) async throws -> GeneratedPreviewHost {
    let hostDir = try Self.hostDirectory(for: preview, scheme: scheme)
    let projectDir = (hostDir as NSString).appendingPathComponent("PreviewHost.xcodeproj")
    let bundleIdentifier = Self.bundleIdentifier(for: preview, scheme: scheme)
    let derivedDataPath = (hostDir as NSString).appendingPathComponent("DerivedData")

    try await Task.detached(priority: .utility) {
      let fm = FileManager.default

      // Create directories
      try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
      try fm.createDirectory(atPath: derivedDataPath, withIntermediateDirectories: true)

      // Write PreviewHostApp.swift
      let appSwift = Self.generateAppSwift(for: preview, scheme: scheme)
      let appSwiftPath = (hostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
      try appSwift.write(toFile: appSwiftPath, atomically: true, encoding: .utf8)

      // Write project.pbxproj
      let pbxproj = Self.generatePbxproj(
        bundleIdentifier: bundleIdentifier,
        userDerivedDataPath: userDerivedDataPath,
        scheme: scheme
      )
      let pbxprojPath = (projectDir as NSString).appendingPathComponent("project.pbxproj")
      try pbxproj.write(toFile: pbxprojPath, atomically: true, encoding: .utf8)
    }.value

    return GeneratedPreviewHost(
      projectPath: projectDir,
      scheme: "PreviewHost",
      bundleIdentifier: bundleIdentifier,
      derivedDataPath: derivedDataPath
    )
  }

  // MARK: - Path helpers

  static func hostDirectory(for preview: PreviewDeclaration, scheme: String) throws -> String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let hostsDir = appSupport
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("PreviewHosts", isDirectory: true)
    let hashInput = "\(preview.filePath):\(preview.lineNumber):\(scheme)"
    let digest = SHA256.hash(data: Data(hashInput.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let hostDir = hostsDir.appendingPathComponent(String(digest.prefix(16)), isDirectory: true)
    return hostDir.path
  }

  static func bundleIdentifier(for preview: PreviewDeclaration, scheme: String) -> String {
    let hashInput = "\(preview.filePath):\(preview.lineNumber):\(scheme)"
    let digest = SHA256.hash(data: Data(hashInput.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "com.agenthub.previewhost.\(String(digest.prefix(12)))"
  }

  // MARK: - Code generation

  static func generateAppSwift(for preview: PreviewDeclaration, scheme: String) -> String {
    let moduleName = preview.moduleName ?? scheme
    return """
    import SwiftUI
    import \(moduleName)

    @main
    struct PreviewHostApp: App {
      var body: some Scene {
        WindowGroup {
          \(preview.bodyExpression)
        }
      }
    }
    """
  }

  // MARK: - pbxproj generation

  static func generatePbxproj(
    bundleIdentifier: String,
    userDerivedDataPath: String,
    scheme: String
  ) -> String {
    let productsPath = "\(userDerivedDataPath)/Build/Products/Debug-iphonesimulator"
    // Minimal pbxproj with a single Swift file targeting iOS Simulator
    return """
    // !$*UTF8*$!
    {
      archiveVersion = 1;
      classes = {
      };
      objectVersion = 56;
      objects = {

    /* Begin PBXBuildFile section */
        A1000001 /* PreviewHostApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000002; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
        A1000002 /* PreviewHostApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreviewHostApp.swift; sourceTree = "<group>"; };
        A1000003 /* PreviewHost.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PreviewHost.app; sourceTree = BUILT_PRODUCTS_DIR; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
        A1000010 = {
          isa = PBXGroup;
          children = (
            A1000002,
            A1000011,
          );
          sourceTree = "<group>";
        };
        A1000011 /* Products */ = {
          isa = PBXGroup;
          children = (
            A1000003,
          );
          name = Products;
          sourceTree = "<group>";
        };
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
        A1000020 /* PreviewHost */ = {
          isa = PBXNativeTarget;
          buildConfigurationList = A1000030;
          buildPhases = (
            A1000021,
          );
          buildRules = (
          );
          dependencies = (
          );
          name = PreviewHost;
          productName = PreviewHost;
          productReference = A1000003;
          productType = "com.apple.product-type.application";
        };
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
        A1000040 /* Project object */ = {
          isa = PBXProject;
          attributes = {
            BuildIndependentTargetsInParallel = 1;
            LastSwiftUpdateCheck = 1540;
            LastUpgradeCheck = 1540;
          };
          buildConfigurationList = A1000041;
          compatibilityVersion = "Xcode 14.0";
          developmentRegion = en;
          hasScannedForEncodings = 0;
          knownRegions = (
            en,
            Base,
          );
          mainGroup = A1000010;
          productRefGroup = A1000011;
          projectDirPath = "";
          projectRoot = "";
          targets = (
            A1000020,
          );
        };
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
        A1000021 /* Sources */ = {
          isa = PBXSourcesBuildPhase;
          buildActionMask = 2147483647;
          files = (
            A1000001,
          );
          runOnlyForDeploymentPostprocessing = 0;
        };
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
        A1000050 /* Debug */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            ALWAYS_SEARCH_USER_PATHS = NO;
            ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
            CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
            CLANG_ENABLE_MODULES = YES;
            CLANG_ENABLE_OBJC_ARC = YES;
            COPY_PHASE_STRIP = NO;
            DEBUG_INFORMATION_FORMAT = dwarf;
            ENABLE_STRICT_OBJC_MSGSEND = YES;
            ENABLE_TESTABILITY = YES;
            GCC_C_LANGUAGE_STANDARD = gnu17;
            GCC_DYNAMIC_NO_PIC = NO;
            GCC_OPTIMIZATION_LEVEL = 0;
            GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
            GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
            IPHONEOS_DEPLOYMENT_TARGET = 17.0;
            MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
            ONLY_ACTIVE_ARCH = YES;
            SDKROOT = iphoneos;
            SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
            SWIFT_OPTIMIZATION_LEVEL = "-Onone";
          };
          name = Debug;
        };
        A1000051 /* Release */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            ALWAYS_SEARCH_USER_PATHS = NO;
            ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
            CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
            CLANG_ENABLE_MODULES = YES;
            CLANG_ENABLE_OBJC_ARC = YES;
            COPY_PHASE_STRIP = NO;
            DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
            ENABLE_NS_ASSERTIONS = NO;
            ENABLE_STRICT_OBJC_MSGSEND = YES;
            GCC_C_LANGUAGE_STANDARD = gnu17;
            GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
            GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
            IPHONEOS_DEPLOYMENT_TARGET = 17.0;
            MTL_ENABLE_DEBUG_INFO = NO;
            SDKROOT = iphoneos;
            SWIFT_COMPILATION_MODE = wholemodule;
            VALIDATE_PRODUCT = YES;
          };
          name = Release;
        };
        A1000060 /* Debug */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
            CODE_SIGN_STYLE = Automatic;
            CURRENT_PROJECT_VERSION = 1;
            FRAMEWORK_SEARCH_PATHS = (
              "$(inherited)",
              "\(productsPath)",
            );
            GENERATE_INFOPLIST_FILE = YES;
            INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
            INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
            INFOPLIST_KEY_UILaunchScreen_Generation = YES;
            LD_RUNPATH_SEARCH_PATHS = (
              "$(inherited)",
              "@executable_path/Frameworks",
            );
            MARKETING_VERSION = 1.0;
            PRODUCT_BUNDLE_IDENTIFIER = "\(bundleIdentifier)";
            PRODUCT_NAME = "$(TARGET_NAME)";
            SWIFT_EMIT_LOC_STRINGS = YES;
            SWIFT_INCLUDE_PATHS = (
              "$(inherited)",
              "\(productsPath)",
            );
            SWIFT_VERSION = 5.0;
            TARGETED_DEVICE_FAMILY = "1,2";
          };
          name = Debug;
        };
        A1000061 /* Release */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
            CODE_SIGN_STYLE = Automatic;
            CURRENT_PROJECT_VERSION = 1;
            FRAMEWORK_SEARCH_PATHS = (
              "$(inherited)",
              "\(productsPath)",
            );
            GENERATE_INFOPLIST_FILE = YES;
            INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
            INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
            INFOPLIST_KEY_UILaunchScreen_Generation = YES;
            LD_RUNPATH_SEARCH_PATHS = (
              "$(inherited)",
              "@executable_path/Frameworks",
            );
            MARKETING_VERSION = 1.0;
            PRODUCT_BUNDLE_IDENTIFIER = "\(bundleIdentifier)";
            PRODUCT_NAME = "$(TARGET_NAME)";
            SWIFT_EMIT_LOC_STRINGS = YES;
            SWIFT_INCLUDE_PATHS = (
              "$(inherited)",
              "\(productsPath)",
            );
            SWIFT_VERSION = 5.0;
            TARGETED_DEVICE_FAMILY = "1,2";
          };
          name = Release;
        };
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
        A1000041 /* Build configuration list for PBXProject "PreviewHost" */ = {
          isa = XCConfigurationList;
          buildConfigurations = (
            A1000050,
            A1000051,
          );
          defaultConfigurationIsVisible = 0;
          defaultConfigurationName = Debug;
        };
        A1000030 /* Build configuration list for PBXNativeTarget "PreviewHost" */ = {
          isa = XCConfigurationList;
          buildConfigurations = (
            A1000060,
            A1000061,
          );
          defaultConfigurationIsVisible = 0;
          defaultConfigurationName = Debug;
        };
    /* End XCConfigurationList section */
      };
      rootObject = A1000040 /* Project object */;
    }
    """
  }
}
