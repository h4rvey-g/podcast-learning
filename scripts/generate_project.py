#!/usr/bin/env python3
"""Generate the Xcode app/share project without third-party tooling. Run after adding Swift files."""
import hashlib
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def add(key, isa, **values):
    identifier = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
    objects[identifier] = dict(isa=isa, **values)
    return identifier


def ref(path, kind):
    return add(path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')


config = ref('Config.xcconfig', 'text.xcconfig')
local = add('local-package', 'XCLocalSwiftPackageReference', relativePath='.')
remote = add('openai-package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/MacPaw/OpenAI.git', requirement={'kind': 'revision', 'revision': '8baf4aaf00d87c6bb58e73b85107b7864cea11d4'})
products, groups, targets = [], [], []


def configs(name, settings, base=True):
    ids = []
    for mode in ['Debug', 'Release']:
        values = dict(settings, SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
        if mode == 'Debug': values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        args = {'baseConfigurationReference': config} if base else {}
        ids.append(add(name + mode, 'XCBuildConfiguration', name=mode, buildSettings=values, **args))
    return add(name + '-configs', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')


for name, bundle, product_type in [('ShareExtension', '$(SHARE_BUNDLE_ID)', 'com.apple.product-type.app-extension'), ('PodcastLearning', '$(APP_BUNDLE_ID)', 'com.apple.product-type.application')]:
    source_refs = [ref(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in sorted((ROOT / name).rglob('*.swift'))]
    others = [ref(name+'/Info.plist', 'text.plist.xml'), ref(name+'/'+name+'.entitlements', 'text.plist.entitlements')]
    sources = add(name+'-sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=[add(f+'-build', 'PBXBuildFile', fileRef=f) for f in source_refs], runOnlyForDeploymentPostprocessing='0')
    resources = []
    if name == 'PodcastLearning':
        asset = ref(name+'/Assets.xcassets', 'folder.assetcatalog'); others += [asset, ref(name+'/Cloud.entitlements','text.plist.entitlements')]
        resources.append(add('asset-build','PBXBuildFile',fileRef=asset))
    resource_phase = add(name+'-resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=resources,runOnlyForDeploymentPostprocessing='0')
    dependencies = [add(name+'-core','XCSwiftPackageProductDependency',package=local,productName='PodcastCore')]
    if name == 'PodcastLearning': dependencies.append(add('app-openai','XCSwiftPackageProductDependency',package=remote,productName='OpenAI'))
    frameworks = add(name+'-frameworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[add(d+'-link','PBXBuildFile',productRef=d) for d in dependencies],runOnlyForDeploymentPostprocessing='0')
    product = add(name+'-product','PBXFileReference',explicitFileType='wrapper.app-extension' if name == 'ShareExtension' else 'wrapper.application',path=name+('.appex' if name == 'ShareExtension' else '.app'),sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    groups.append(add(name+'-group','PBXGroup',children=source_refs+others,name=name,sourceTree='<group>'))
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER=bundle,INFOPLIST_FILE=name+'/Info.plist',CODE_SIGN_ENTITLEMENTS=name+'/'+name+'.entitlements',CODE_SIGN_STYLE='Automatic',SWIFT_VERSION='5.0',IPHONEOS_DEPLOYMENT_TARGET='18.0',TARGETED_DEVICE_FAMILY='1,2',SDKROOT='iphoneos',SUPPORTED_PLATFORMS='iphoneos iphonesimulator',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks',GENERATE_INFOPLIST_FILE='NO')
    if name == 'ShareExtension': settings.update(APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks')
    else: settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
    targets.append(add(name+'-target','PBXNativeTarget',name=name,productName=name,productReference=product,productType=product_type,buildConfigurationList=configs(name,settings),buildPhases=[sources,frameworks,resource_phase],buildRules=[],dependencies=[],packageProductDependencies=dependencies))

project_id = hashlib.sha256(b'project').hexdigest()[:24].upper()
proxy = add('share-proxy','PBXContainerItemProxy',containerPortal=project_id,proxyType='1',remoteGlobalIDString=targets[0],remoteInfo='ShareExtension')
objects[targets[1]]['dependencies'] = [add('share-dependency','PBXTargetDependency',target=targets[0],targetProxy=proxy)]
embed = add('embed-share','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[add('embed-share-file','PBXBuildFile',fileRef=products[0],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})],name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0')
objects[targets[1]]['buildPhases'].append(embed)
product_group = add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main = add('main','PBXGroup',children=[config]+groups+[product_group],sourceTree='<group>')
add('project','PBXProject',attributes={'LastUpgradeCheck':'1600','TargetAttributes':{t:{'CreatedOnToolsVersion':'16.0'} for t in targets}},buildConfigurationList=configs('project',{'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'18.0'},False),compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=main,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=targets,packageReferences=[local,remote])
project = ROOT / 'PodcastLearning.xcodeproj'; project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project_id},sort_keys=False))
scheme = project / 'xcshareddata/xcschemes'; scheme.mkdir(parents=True,exist_ok=True)
(scheme / 'PodcastLearning.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[1]}" BuildableName="PodcastLearning.app" BlueprintName="PodcastLearning" ReferencedContainer="container:PodcastLearning.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[1]}" BuildableName="PodcastLearning.app" BlueprintName="PodcastLearning" ReferencedContainer="container:PodcastLearning.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project.relative_to(ROOT))
