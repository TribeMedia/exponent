/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI9_0_0RCTBridge+Private.h"

#import <objc/runtime.h>

#import "ABI9_0_0RCTConvert.h"
#import "ABI9_0_0RCTEventDispatcher.h"
#import "ABI9_0_0RCTKeyCommands.h"
#import "ABI9_0_0RCTLog.h"
#import "ABI9_0_0RCTModuleData.h"
#import "ABI9_0_0RCTPerformanceLogger.h"
#import "ABI9_0_0RCTUtils.h"

NSString *const ABI9_0_0RCTReloadNotification = @"ABI9_0_0RCTReloadNotification";
NSString *const ABI9_0_0RCTJavaScriptWillStartLoadingNotification = @"ABI9_0_0RCTJavaScriptWillStartLoadingNotification";
NSString *const ABI9_0_0RCTJavaScriptDidLoadNotification = @"ABI9_0_0RCTJavaScriptDidLoadNotification";
NSString *const ABI9_0_0RCTJavaScriptDidFailToLoadNotification = @"ABI9_0_0RCTJavaScriptDidFailToLoadNotification";
NSString *const ABI9_0_0RCTDidInitializeModuleNotification = @"ABI9_0_0RCTDidInitializeModuleNotification";

static NSMutableArray<Class> *ABI9_0_0RCTModuleClasses;
NSArray<Class> *ABI9_0_0RCTGetModuleClasses(void);
NSArray<Class> *ABI9_0_0RCTGetModuleClasses(void)
{
  return ABI9_0_0RCTModuleClasses;
}

/**
 * Register the given class as a bridge module. All modules must be registered
 * prior to the first bridge initialization.
 */
void ABI9_0_0RCTRegisterModule(Class);
void ABI9_0_0RCTRegisterModule(Class moduleClass)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    ABI9_0_0RCTModuleClasses = [NSMutableArray new];
  });

  ABI9_0_0RCTAssert([moduleClass conformsToProtocol:@protocol(ABI9_0_0RCTBridgeModule)],
            @"%@ does not conform to the ABI9_0_0RCTBridgeModule protocol",
            moduleClass);

  // Register module
  [ABI9_0_0RCTModuleClasses addObject:moduleClass];
}

/**
 * This function returns the module name for a given class.
 */
NSString *ABI9_0_0RCTBridgeModuleNameForClass(Class cls)
{
#if ABI9_0_0RCT_DEV
  ABI9_0_0RCTAssert([cls conformsToProtocol:@protocol(ABI9_0_0RCTBridgeModule)],
            @"Bridge module `%@` does not conform to ABI9_0_0RCTBridgeModule", cls);
#endif

  NSString *name = [cls moduleName];
  if (name.length == 0) {
    name = NSStringFromClass(cls);
  }
  if ([name hasPrefix:@"RK"]) {
    name = [name stringByReplacingCharactersInRange:(NSRange){0,@"RK".length} withString:@"RCT"];
  }
  return ABI9_0_0EX_REMOVE_VERSION(name);
}

@implementation ABI9_0_0RCTBridge
{
  NSURL *_delegateBundleURL;
}

dispatch_queue_t ABI9_0_0RCTJSThread;

+ (void)initialize
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{

    // Set up JS thread
    ABI9_0_0RCTJSThread = (id)kCFNull;
  });
}

static ABI9_0_0RCTBridge *ABI9_0_0RCTCurrentBridgeInstance = nil;

/**
 * The last current active bridge instance. This is set automatically whenever
 * the bridge is accessed. It can be useful for static functions or singletons
 * that need to access the bridge for purposes such as logging, but should not
 * be relied upon to return any particular instance, due to race conditions.
 */
+ (instancetype)currentBridge
{
  return ABI9_0_0RCTCurrentBridgeInstance;
}

+ (void)setCurrentBridge:(ABI9_0_0RCTBridge *)currentBridge
{
  ABI9_0_0RCTCurrentBridgeInstance = currentBridge;
}

- (instancetype)initWithDelegate:(id<ABI9_0_0RCTBridgeDelegate>)delegate
                   launchOptions:(NSDictionary *)launchOptions
{
  return [self initWithDelegate:delegate
                      bundleURL:nil
                 moduleProvider:nil
                  launchOptions:launchOptions];
}

- (instancetype)initWithBundleURL:(NSURL *)bundleURL
                   moduleProvider:(ABI9_0_0RCTBridgeModuleProviderBlock)block
                    launchOptions:(NSDictionary *)launchOptions
{
  return [self initWithDelegate:nil
                      bundleURL:bundleURL
                 moduleProvider:block
                  launchOptions:launchOptions];
}

- (instancetype)initWithDelegate:(id<ABI9_0_0RCTBridgeDelegate>)delegate
                       bundleURL:(NSURL *)bundleURL
                  moduleProvider:(ABI9_0_0RCTBridgeModuleProviderBlock)block
                   launchOptions:(NSDictionary *)launchOptions
{
  if (self = [super init]) {
    _performanceLogger = [ABI9_0_0RCTPerformanceLogger new];
    [_performanceLogger markStartForTag:ABI9_0_0RCTPLBridgeStartup];
    [_performanceLogger markStartForTag:ABI9_0_0RCTPLTTI];

    _delegate = delegate;
    _bundleURL = bundleURL;
    _moduleProvider = block;
    _launchOptions = [launchOptions copy];
    [self setUp];
    ABI9_0_0RCTExecuteOnMainQueue(^{ [self bindKeys]; });
  }
  return self;
}

ABI9_0_0RCT_NOT_IMPLEMENTED(- (instancetype)init)

- (void)dealloc
{
  /**
   * This runs only on the main thread, but crashes the subclass
   * ABI9_0_0RCTAssertMainQueue();
   */
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self invalidate];
}

- (void)bindKeys
{
  ABI9_0_0RCTAssertMainQueue();

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(reload)
                                               name:ABI9_0_0RCTReloadNotification
                                             object:self.baseBridge];

#if TARGET_IPHONE_SIMULATOR
  ABI9_0_0RCTKeyCommands *commands = [ABI9_0_0RCTKeyCommands sharedInstance];

  // reload in current mode
  __weak typeof(self) weakSelf = self;
  [commands registerKeyCommandWithInput:@"r"
                          modifierFlags:UIKeyModifierCommand
                                 action:^(__unused UIKeyCommand *command) {
    ABI9_0_0RCTBridge *baseBridge = weakSelf.baseBridge;
    if (baseBridge) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ABI9_0_0RCTReloadNotification
                                                            object:baseBridge
                                                         userInfo:nil];
    }
  }];

#endif
}

- (NSArray<Class> *)moduleClasses
{
  return self.batchedBridge.moduleClasses;
}

- (id)moduleForName:(NSString *)moduleName
{
  return [self.batchedBridge moduleForName:moduleName];
}

- (id)moduleForClass:(Class)moduleClass
{
  return [self moduleForName:ABI9_0_0RCTBridgeModuleNameForClass(moduleClass)];
}

- (NSArray *)modulesConformingToProtocol:(Protocol *)protocol
{
  NSMutableArray *modules = [NSMutableArray new];
  for (Class moduleClass in self.moduleClasses) {
    if ([moduleClass conformsToProtocol:protocol]) {
      id module = [self moduleForClass:moduleClass];
      if (module) {
        [modules addObject:module];
      }
    }
  }
  return [modules copy];
}

- (BOOL)moduleIsInitialized:(Class)moduleClass
{
  return [self.batchedBridge moduleIsInitialized:moduleClass];
}

- (void)reload
{
  /**
   * Any thread
   */
  dispatch_async(dispatch_get_main_queue(), ^{
    [self invalidate];
    [self setUp];
  });
}

- (void)setUp
{
  // Only update bundleURL from delegate if delegate bundleURL has changed
  NSURL *previousDelegateURL = _delegateBundleURL;
  _delegateBundleURL = [self.delegate sourceURLForBridge:self];
  if (_delegateBundleURL && ![_delegateBundleURL isEqual:previousDelegateURL]) {
    _bundleURL = _delegateBundleURL;
  }

  // Sanitize the bundle URL
  _bundleURL = [ABI9_0_0RCTConvert NSURL:_bundleURL.absoluteString];

  [self createBatchedBridge];
}

- (void)createBatchedBridge
{
  self.batchedBridge = [[ABI9_0_0RCTBatchedBridge alloc] initWithParentBridge:self];
}

- (BOOL)isLoading
{
  return self.batchedBridge.loading;
}

- (BOOL)isValid
{
  return self.batchedBridge.valid;
}

- (BOOL)isBatchActive
{
  return [_batchedBridge isBatchActive];
}

- (ABI9_0_0RCTBridge *)baseBridge
{
  return self;
}

- (void)invalidate
{
  ABI9_0_0RCTBridge *batchedBridge = self.batchedBridge;
  self.batchedBridge = nil;

  if (batchedBridge) {
    ABI9_0_0RCTExecuteOnMainQueue(^{
      [batchedBridge invalidate];
    });
  }
}

- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args
{
  NSArray<NSString *> *ids = [moduleDotMethod componentsSeparatedByString:@"."];
  NSString *module = ids[0];
  NSString *method = ids[1];
  [self enqueueJSCall:module method:method args:args completion:NULL];
}

- (void)enqueueJSCall:(NSString *)module method:(NSString *)method args:(NSArray *)args completion:(dispatch_block_t)completion
{
  [self.batchedBridge enqueueJSCall:module method:method args:args completion:completion];
}

- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args
{
  [self.batchedBridge enqueueCallback:cbID args:args];
}

@end
