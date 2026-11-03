#import <ctype.h>
#import <malloc/malloc.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>

#import <React/RCTBlobManager.h>
#import <React/RCTBridgeModule.h>

static IMP invokeWithTarget;
static IMP resolveBlob;

static os_log_t guardLog(void)
{
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("io.nekohasekai.swipt", "SwipletModules");
  });
  return log;
}

static BOOL isBlock(NSMethodSignature *signature, NSUInteger index)
{
  return strcmp([signature getArgumentTypeAtIndex:index], "@?") == 0;
}

@interface StructArgument : NSObject
@end

@implementation StructArgument
@end

static BOOL isHeapPointer(const void *pointer)
{
  return pointer != NULL && malloc_zone_from_ptr(pointer) != NULL;
}

// ObjCTurboModule fills the slot of a C++ struct argument with the raw bits of a JavaScript number,
// boolean, null or non-object value; only an object becomes a pointer to a struct holding an NSDictionary.
static BOOL isStructArgument(NSInvocation *invocation, NSUInteger index)
{
  void *pointer = NULL;
  [invocation getArgument:&pointer atIndex:index];
  if (!isHeapPointer(pointer) || malloc_size(pointer) < sizeof(void *)) {
    return NO;
  }
  void *dictionary = *(void **)pointer;
  return isHeapPointer(dictionary) && [(__bridge id)dictionary isKindOfClass:NSDictionary.class];
}

static Class argumentClassOf(NSString *type)
{
  if (![type containsString:@"*"]) {
    return nil;
  }
  NSRange generics = [type rangeOfString:@"<"];
  if (generics.location != NSNotFound) {
    type = [type substringToIndex:generics.location];
  }
  for (NSString *word in [type componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" *"]]) {
    if ([word hasPrefix:@"NS"]) {
      Class argumentClass = NSClassFromString([word stringByReplacingOccurrencesOfString:@"NSMutable" withString:@"NS"]);
      for (Class checked in @[ NSString.class, NSNumber.class, NSArray.class, NSDictionary.class ]) {
        if (argumentClass == checked) {
          return checked;
        }
      }
      return nil;
    }
  }
  return nil;
}

static void addExport(NSMutableDictionary<NSString *, NSArray *> *exports, const char *method)
{
  NSMutableString *selector = [NSMutableString string];
  NSMutableArray *classes = [NSMutableArray array];
  const char *cursor = method;
  for (;;) {
    while (isspace(*cursor)) {
      cursor++;
    }
    const char *word = cursor;
    while (isalnum(*cursor) || *cursor == '_' || *cursor == '$') {
      cursor++;
    }
    size_t length = (size_t)(cursor - word);
    while (isspace(*cursor)) {
      cursor++;
    }
    if (length == 0 || *cursor != ':') {
      break;
    }
    [selector appendFormat:@"%.*s:", (int)length, word];
    cursor++;
    while (isspace(*cursor)) {
      cursor++;
    }
    if (*cursor != '(') {
      return;
    }
    const char *type = ++cursor;
    for (int depth = 1; depth > 0; cursor++) {
      if (*cursor == '\0') {
        return;
      }
      depth += *cursor == '(' ? 1 : *cursor == ')' ? -1 : 0;
    }
    NSString *typeName = [[NSString alloc] initWithBytes:type length:(NSUInteger)(cursor - 1 - type) encoding:NSUTF8StringEncoding];
    Class argumentClass = [typeName containsString:@"&"] ? StructArgument.class : argumentClassOf(typeName);
    [classes addObject:argumentClass ?: (id)NSNull.null];
    while (isspace(*cursor)) {
      cursor++;
    }
    while (isalnum(*cursor) || *cursor == '_' || *cursor == '$') {
      cursor++;
    }
  }
  if (selector.length > 0) {
    exports[selector] = classes;
  }
}

static NSDictionary<NSString *, NSArray *> *exportsOf(Class moduleClass)
{
  static NSMutableDictionary<NSString *, NSDictionary *> *cache;
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  NSString *name = NSStringFromClass(moduleClass);
  os_unfair_lock_lock(&lock);
  NSDictionary *cached = cache[name];
  os_unfair_lock_unlock(&lock);
  if (cached != nil) {
    return cached;
  }
  NSMutableDictionary *exports = [NSMutableDictionary dictionary];
  for (Class current = moduleClass; current != nil && current != NSObject.class; current = class_getSuperclass(current)) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(current), &count);
    for (unsigned int index = 0; index < count; index++) {
      SEL selector = method_getName(methods[index]);
      if (strncmp(sel_getName(selector), "__rct_export__", 14) == 0) {
        const RCTMethodInfo *info = ((const RCTMethodInfo *(*)(id, SEL))method_getImplementation(methods[index]))(current, selector);
        addExport(exports, info->objcName);
      }
    }
    free(methods);
  }
  os_unfair_lock_lock(&lock);
  if (cache == nil) {
    cache = [NSMutableDictionary dictionary];
  }
  cache[name] = exports;
  os_unfair_lock_unlock(&lock);
  return exports;
}

// ObjCTurboModule passes a JavaScript value to an exported method without checking it against the
// Objective-C class the method declares.
static void checkArguments(NSInvocation *invocation, id target)
{
  NSArray *classes = exportsOf([target class])[NSStringFromSelector(invocation.selector)];
  NSMethodSignature *signature = invocation.methodSignature;
  if (classes == nil || classes.count + 2 != signature.numberOfArguments) {
    return;
  }
  for (NSUInteger index = 0; index < classes.count; index++) {
    Class expected = classes[index];
    if (expected == StructArgument.class && [signature getArgumentTypeAtIndex:index + 2][0] == '^') {
      if (!isStructArgument(invocation, index + 2)) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:[NSString stringWithFormat:@"argument %lu must be an object", (unsigned long)index + 1]
                                     userInfo:nil];
      }
      continue;
    }
    if (expected == (id)NSNull.null || expected == StructArgument.class || [signature getArgumentTypeAtIndex:index + 2][0] != '@') {
      continue;
    }
    __unsafe_unretained id value = nil;
    [invocation getArgument:&value atIndex:index + 2];
    if (value != nil && ![value isKindOfClass:expected]) {
      @throw [NSException exceptionWithName:NSInvalidArgumentException
                                     reason:[NSString stringWithFormat:@"argument %lu must be %@", (unsigned long)index + 1, NSStringFromClass(expected)]
                                   userInfo:nil];
    }
  }
}

// ObjCTurboModule rethrows an NSException raised by a void or promise method on the module's
// method queue, outside any handler, which terminates the process.
static void guardedInvokeWithTarget(NSInvocation *invocation, SEL selector, id target)
{
  auto invoke = (void (*)(NSInvocation *, SEL, id))invokeWithTarget;
  if (![target conformsToProtocol:@protocol(RCTBridgeModule)]) {
    invoke(invocation, selector, target);
    return;
  }
  NSMethodSignature *signature = invocation.methodSignature;
  if (signature.methodReturnLength != 0) {
    checkArguments(invocation, target);
    invoke(invocation, selector, target);
    return;
  }
  @try {
    checkArguments(invocation, target);
    invoke(invocation, selector, target);
  } @catch (NSException *exception) {
    os_log_error(guardLog(), "%{public}@ %{public}@ raised %{public}@: %{public}@", NSStringFromClass([target class]),
        NSStringFromSelector(invocation.selector), exception.name, exception.reason);
    NSUInteger count = signature.numberOfArguments;
    if (count >= 4 && isBlock(signature, count - 1) && isBlock(signature, count - 2)) {
      __unsafe_unretained RCTPromiseRejectBlock reject = nil;
      [invocation getArgument:&reject atIndex:count - 1];
      if (reject != nil) {
        reject(exception.name, exception.reason ?: exception.name, nil);
      }
    }
  }
}

// RCTBlobManager hands the offset and size of a blob: URL to subdataWithRange: unchecked.
static NSData *guardedResolveBlob(RCTBlobManager *self, SEL selector, NSString *blobId, NSInteger offset, NSInteger size)
{
  NSInteger length = (NSInteger)[self lengthOfBlobWithId:blobId];
  if (offset < 0 || offset > length) {
    return nil;
  }
  if (size == -1) {
    size = length - offset;
  }
  if (size < 0 || size > length - offset) {
    return nil;
  }
  return ((NSData * (*)(RCTBlobManager *, SEL, NSString *, NSInteger, NSInteger)) resolveBlob)(self, selector, blobId, offset, size);
}

static void ignore(id self, SEL selector) {}

static NSDictionary *noSettings(id self, SEL selector)
{
  return @{@"settings" : @{}};
}

static void replace(NSString *className, NSArray<NSString *> *selectors, IMP implementation)
{
  Class moduleClass = NSClassFromString(className);
  for (NSString *selector in selectors) {
    method_setImplementation(class_getInstanceMethod(moduleClass, NSSelectorFromString(selector)), implementation);
  }
}

__attribute__((constructor)) static void guardSwipletModules(void)
{
  invokeWithTarget = method_setImplementation(class_getInstanceMethod(NSInvocation.class, @selector(invokeWithTarget:)), (IMP)guardedInvokeWithTarget);
  resolveBlob = method_setImplementation(class_getInstanceMethod(RCTBlobManager.class, @selector(resolve:offset:size:)), (IMP)guardedResolveBlob);
  replace(@"RCTI18nManager", @[ @"allowRTL:", @"forceRTL:", @"swapLeftAndRightInRTL:" ], (IMP)ignore);
  replace(@"RCTAppearance", @[ @"setColorScheme:" ], (IMP)ignore);
  replace(@"RCTSettingsManager", @[ @"setValues:", @"deleteValues:", @"userDefaultsDidChange:" ], (IMP)ignore);
  replace(@"RCTSettingsManager", @[ @"getConstants", @"constantsToExport" ], (IMP)noSettings);
}
