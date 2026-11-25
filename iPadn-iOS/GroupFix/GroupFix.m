// GroupFix: makes a re-signed app find the App Groups and keychain groups it
// was built for.
//
// A re-signed app only holds the groups of the signing certificate, so a call
// like containerURL(forSecurityApplicationGroupIdentifier: "group.vendor.app")
// returns nil and many apps crash on the force-unwrap. iPadn injects this
// library while signing and writes GroupFix.plist next to it:
//
//   groups:  { "group.vendor.app": "group.<granted by certificate>" }
//   oldTeam: original team ID (keychain groups are "TEAMID.something")
//   newTeam: the signing certificate's team ID
//
// Each app group gets its own sub-folder inside the granted container, named
// after the original group, so two re-signed apps never share files.
// Nothing is sent anywhere; it only rewrites identifiers in-process.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "fishhook.h"

static NSDictionary<NSString *, NSString *> *gGroups;
static NSString *gFallbackGroup;   // granted group for any app group not listed in gGroups
static NSString *gOldTeam;
static NSString *gNewTeam;

// Resolve an app-group identifier to one the certificate grants.
static NSString *GFResolveGroup(NSString *group) {
    NSString *mapped = gGroups[group];
    if (mapped) return mapped;
    // Any app group the app asks for that we have no explicit mapping for goes
    // to the fallback: the app's own original name isolates its files below it.
    if (gFallbackGroup.length && [group hasPrefix:@"group."]) return gFallbackGroup;
    return group;
}

// Resolve any identifier used as a shared suite / keychain access group.
static NSString *GFMapGroup(id value) {
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *group = value;
    NSString *mapped = gGroups[group];
    if (mapped) return mapped;
    // Keychain access groups are "TEAMID.something"; swap to the signing team so
    // the wildcard "<newTeam>.*" the certificate grants accepts them.
    if (gOldTeam.length && gNewTeam.length && ![gOldTeam isEqualToString:gNewTeam]) {
        NSString *prefix = [gOldTeam stringByAppendingString:@"."];
        if ([group hasPrefix:prefix]) {
            return [[gNewTeam stringByAppendingString:@"."] stringByAppendingString:[group substringFromIndex:prefix.length]];
        }
    }
    if (gFallbackGroup.length && [group hasPrefix:@"group."]) return gFallbackGroup;
    return group;
}

#pragma mark - App Group containers

static NSURL *(*gOrigContainer)(id, SEL, NSString *);

static NSURL *GFContainer(id self, SEL _cmd, NSString *identifier) {
    NSString *mapped = GFResolveGroup(identifier);
    if ([mapped isEqualToString:identifier]) return gOrigContainer(self, _cmd, identifier);
    NSURL *root = gOrigContainer(self, _cmd, mapped);
    if (!root) return nil;
    // Isolate by the original identifier: app and its extensions agree on it,
    // other re-signed apps mapped to the same granted group do not.
    NSURL *isolated = [[root URLByAppendingPathComponent:@"GroupFix" isDirectory:YES]
                       URLByAppendingPathComponent:identifier isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:isolated withIntermediateDirectories:YES attributes:nil error:nil];
    return isolated;
}

#pragma mark - Shared preferences

static id (*gOrigSuite)(id, SEL, NSString *);

static id GFInitSuite(id self, SEL _cmd, NSString *suite) {
    return gOrigSuite(self, _cmd, suite ? GFMapGroup(suite) : suite);
}

#pragma mark - Keychain

static NSDictionary *GFFixQuery(CFDictionaryRef raw) {
    NSDictionary *query = (__bridge NSDictionary *)raw;
    if (![query isKindOfClass:[NSDictionary class]]) return query;
    id group = query[(__bridge NSString *)kSecAttrAccessGroup];
    if (!group) return query;
    id mapped = GFMapGroup(group);
    if (mapped == group || [mapped isEqual:group]) return query;
    NSMutableDictionary *copy = [query mutableCopy];
    copy[(__bridge NSString *)kSecAttrAccessGroup] = mapped;
    return copy;
}

static OSStatus (*gOrigAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*gOrigCopy)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*gOrigUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*gOrigDelete)(CFDictionaryRef);

static OSStatus GFAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return gOrigAdd((__bridge CFDictionaryRef)GFFixQuery(attributes), result);
}

static OSStatus GFCopy(CFDictionaryRef query, CFTypeRef *result) {
    return gOrigCopy((__bridge CFDictionaryRef)GFFixQuery(query), result);
}

static OSStatus GFUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    return gOrigUpdate((__bridge CFDictionaryRef)GFFixQuery(query), (__bridge CFDictionaryRef)GFFixQuery(attributes));
}

static OSStatus GFDelete(CFDictionaryRef query) {
    return gOrigDelete((__bridge CFDictionaryRef)GFFixQuery(query));
}

#pragma mark - Setup

static void GFSwizzle(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method) *original = method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void GFInit(void) {
    @autoreleasepool {
        Dl_info info;
        if (!dladdr((const void *)&GFInit, &info) || !info.dli_fname) return;
        NSString *folder = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"GroupFix.plist"]];
        if (!config) return;
        NSDictionary *groups = config[@"groups"];
        gGroups = [groups isKindOfClass:[NSDictionary class]] ? groups : @{};
        gFallbackGroup = [config[@"fallbackGroup"] isKindOfClass:[NSString class]] ? config[@"fallbackGroup"] : nil;
        gOldTeam = [config[@"oldTeam"] isKindOfClass:[NSString class]] ? config[@"oldTeam"] : nil;
        gNewTeam = [config[@"newTeam"] isKindOfClass:[NSString class]] ? config[@"newTeam"] : nil;

        GFSwizzle([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:),
                  (IMP)GFContainer, (IMP *)&gOrigContainer);
        GFSwizzle([NSUserDefaults class], @selector(initWithSuiteName:),
                  (IMP)GFInitSuite, (IMP *)&gOrigSuite);

        gOrigAdd = SecItemAdd;
        gOrigCopy = SecItemCopyMatching;
        gOrigUpdate = SecItemUpdate;
        gOrigDelete = SecItemDelete;
        struct rebinding rebindings[] = {
            {"SecItemAdd", (void *)GFAdd, (void **)&gOrigAdd},
            {"SecItemCopyMatching", (void *)GFCopy, (void **)&gOrigCopy},
            {"SecItemUpdate", (void *)GFUpdate, (void **)&gOrigUpdate},
            {"SecItemDelete", (void *)GFDelete, (void **)&gOrigDelete},
        };
        rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
        NSLog(@"[GroupFix] active: %lu group(s), team %@ -> %@", (unsigned long)gGroups.count, gOldTeam, gNewTeam);
    }
}
