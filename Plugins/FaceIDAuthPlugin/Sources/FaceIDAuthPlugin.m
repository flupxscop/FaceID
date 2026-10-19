// FaceIDAuthPlugin — authorization plugin mechanism "FaceIDAuthPlugin:face".
//
// Runs inside Apple's SecurityAgentHelper (as _securityagent). It never touches the camera: it asks
// FaceIDBroker (a system-wide LaunchDaemon), which relays to the user's FaceIDAgent in the same
// audit session. The helper cannot reach the agent's per-user service directly (seen in a VM).
// and maps the answer to an authorization result.
//
// Safety rules (CLAUDE.md §7):
//   * Fail closed: only an explicit "match" relayed by a correctly signed broker yields Allow.
//     Errors, timeouts, an unsigned plugin, a missing or impostor agent: all yield
//     kNotAcceptedResult, and the k-of-n rule moves on to the password.
//   * Never block SecurityAgent: MechanismInvoke returns at once; the result is set later.
//   * SetResult / DidDeactivate are called at most once each, and never after MechanismDestroy.
//   * No exceptions escape into SecurityAgent; no fatal errors.
//
// Threading: all mechanism state is confined to the main queue. XPC replies and timers hop
// onto it, so no locks are needed. The engine calls into the plugin on the main thread; if it
// ever does not, the entry points below hop to main as well.

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Security/AuthorizationPlugin.h>
#import <Security/AuthorizationTags.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <os/log.h>
#import <pwd.h>

#import "FaceIDBrokerAuthProtocol.h"

static NSString *const kMachServiceName = @"com.example.faceid.broker.auth";
static NSString *const kBrokerIdentifier = @"com.example.faceid.broker";
static NSString *const kPluginBundleIdentifier = @"com.example.faceid.authplugin";
/// Info.plist key written by Scripts/build-plugin.sh: SHA-1 of the certificate that signed the
/// plugin and the agent. Sealed by the bundle's signature; the bundle itself is root-owned.
static NSString *const kPinnedCertificateKey = @"FaceIDAgentCertificateSHA1";
/// Info.plist key written by Scripts/build-plugin.sh (via build-app.sh): code hash of the exact
/// broker build. Preferred over the certificate: inside SecurityAgentHelper certificate-based
/// requirements always fail (seen in a VM: error 4102), code hashes need no certificate parsing.
static NSString *const kPinnedBrokerCDHashKey = @"FaceIDBrokerCDHash";
static const char *const kFaceMechanismId = "face";
/// Where install.sh puts the broker; used only by the diagnostics below.
static NSString *const kBrokerInstallPath = @"/Library/Application Support/FaceID/FaceIDBroker";

/// The agent gives up after FaceIDConfig.scanTimeout (5 s); allow margin for model warm-up.
static const int64_t kScanTimeoutSeconds = 7;
static const NSInteger kAuthResultCodeMatch = 0;

/// Result when the face is not accepted. Deny makes only this sub-rule fail, so the
/// `k-of-n = 1` screensaver rule goes on to `authenticate-session-owner-or-admin` (password).
/// VM experiment: confirm Undefined is NOT needed (the header says Undefined stops retries).
static const AuthorizationResult kNotAcceptedResult = kAuthorizationResultDeny;

/// After a match, record the session owner in the context, as builtin:authenticate would.
/// VM experiment: check whether loginwindow needs this to actually unlock.
static const BOOL kSetSessionOwnerContext = YES;

static os_log_t FIDLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.example.faceid", "authplugin"); });
    return log;
}

static void FIDOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

// MARK: - Signing

/// URL of this plugin's own bundle.
///
/// SecurityAgentHelper may load the plugin without registering it with NSBundle (seen in a VM:
/// `bundleWithIdentifier:` returned nil), so fall back to the path of the loaded image itself.
static NSURL *_Nullable FIDPluginBundleURL(void) {
    NSBundle *registered = [NSBundle bundleWithIdentifier:kPluginBundleIdentifier];
    if (registered != nil) {
        return registered.bundleURL;
    }
    Dl_info image;
    if (dladdr((const void *)&FIDPluginBundleURL, &image) == 0 || image.dli_fname == NULL) {
        return nil;
    }
    // .../FaceIDAuthPlugin.bundle/Contents/MacOS/FaceIDAuthPlugin -> .../FaceIDAuthPlugin.bundle
    NSURL *executable = [NSURL fileURLWithFileSystemRepresentation:image.dli_fname isDirectory:NO relativeToURL:nil];
    NSURL *bundle = executable.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    return [bundle.pathExtension isEqualToString:@"bundle"] ? bundle : nil;
}

static NSString *FIDRequirementForCertificate(NSString *sha1) {
    return [NSString stringWithFormat:@"identifier \"%@\" and certificate leaf = H\"%@\"", kBrokerIdentifier, sha1];
}

static NSString *FIDRequirementForCDHash(NSString *cdhash) {
    return [NSString stringWithFormat:@"identifier \"%@\" and cdhash H\"%@\"", kBrokerIdentifier, cdhash];
}

/// A 40-digit hex value pinned in Info.plist at build time, or nil if absent or malformed.
static NSString *_Nullable FIDPinnedHash(NSURL *bundleURL, NSString *key) {
    NSURL *infoURL = [bundleURL URLByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:infoURL error:NULL];
    id value = info[key];
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *hash = [(NSString *)value uppercaseString];
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    if (hash.length != CC_SHA1_DIGEST_LENGTH * 2 || [hash rangeOfCharacterFromSet:notHex].location != NSNotFound) {
        return nil;
    }
    return hash;
}

/// The requirement the broker must meet, or nil when nothing is pinned (ad-hoc build): then the
/// broker cannot be verified and the plugin always fails closed. In order of preference:
///   1. `identifier <broker> and cdhash H"<pinned cdhash>"` — works inside SecurityAgentHelper;
///   2. `identifier <broker> and certificate leaf = H"<pinned sha1>"` — for hosts that can read certificates;
///   3. the certificate read from this plugin's own signature (harness / other hosts only).
static NSString *_Nullable FIDCopyAgentRequirement(void) {
    NSURL *bundleURL = FIDPluginBundleURL();
    if (bundleURL == nil) {
        os_log_error(FIDLog(), "signing: cannot locate the plugin bundle");
        return nil;
    }
    NSString *cdhash = FIDPinnedHash(bundleURL, kPinnedBrokerCDHashKey);
    if (cdhash != nil) {
        os_log(FIDLog(), "signing: verifying the broker by pinned code hash");
        return FIDRequirementForCDHash(cdhash);
    }
    NSString *pinned = FIDPinnedHash(bundleURL, kPinnedCertificateKey);
    if (pinned != nil) {
        os_log(FIDLog(), "signing: verifying the broker by pinned certificate");
        return FIDRequirementForCertificate(pinned);
    }
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &code);
    if (status != errSecSuccess || code == NULL) {
        os_log_error(FIDLog(), "signing: static code unavailable (%d)", (int)status);
        return nil;
    }
    CFDictionaryRef info = NULL;
    status = SecCodeCopySigningInformation(code, (SecCSFlags)kSecCSSigningInformation, &info);
    CFRelease(code);
    if (status != errSecSuccess || info == NULL) {
        os_log_error(FIDLog(), "signing: signing information unavailable (%d)", (int)status);
        return nil;
    }
    NSDictionary *signing = CFBridgingRelease(info);
    NSArray *certificates = signing[(__bridge NSString *)kSecCodeInfoCertificates];
    if (certificates.count == 0) {
        os_log_error(FIDLog(), "signing: plugin has no signing certificate (ad-hoc)");
        return nil;
    }
    SecCertificateRef leaf = (__bridge SecCertificateRef)certificates.firstObject;
    NSData *der = CFBridgingRelease(SecCertificateCopyData(leaf));
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(der.bytes, (CC_LONG)der.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02X", digest[i]];
    }
    return FIDRequirementForCertificate(hex);
}

// MARK: - Diagnostics

/// Diagnostics only — never changes a result. When the broker fails the code-signing requirement
/// (XPC error 4102), log *why* from inside this host process: whether it can read the broker's
/// file, see its certificates and code hash, and what OSStatus the static and dynamic checks give.
/// Runs off the main thread. Logs no personal or biometric data.
static void FIDLogBrokerSignatureDiagnostics(pid_t pid, NSString *_Nullable requirementText) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SecRequirementRef requirement = NULL;
        OSStatus status = requirementText == nil
            ? errSecParam
            : SecRequirementCreateWithString((__bridge CFStringRef)requirementText, kSecCSDefaultFlags, &requirement);
        os_log(FIDLog(), "diagnostic: requirement compile status %d", (int)status);

        SecStaticCodeRef staticCode = NULL;
        status = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:kBrokerInstallPath],
                                             kSecCSDefaultFlags, &staticCode);
        os_log(FIDLog(), "diagnostic: broker file open status %d", (int)status);
        if (staticCode != NULL) {
            CFDictionaryRef info = NULL;
            status = SecCodeCopySigningInformation(staticCode, (SecCSFlags)kSecCSSigningInformation, &info);
            NSDictionary *signing = info != NULL ? CFBridgingRelease(info) : nil;
            NSArray *certificates = signing[(__bridge NSString *)kSecCodeInfoCertificates];
            NSData *cdhash = signing[(__bridge NSString *)kSecCodeInfoUnique];
            os_log(FIDLog(), "diagnostic: broker signing info status %d, certificates %lu, cdhash %{public}@",
                   (int)status, (unsigned long)certificates.count,
                   cdhash != nil ? [cdhash.description stringByReplacingOccurrencesOfString:@" " withString:@""] : @"none");
            if (requirement != NULL) {
                status = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, requirement);
                os_log(FIDLog(), "diagnostic: broker static requirement check %d", (int)status);
                status = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, NULL);
                os_log(FIDLog(), "diagnostic: broker static signature validity %d", (int)status);
            }
            CFRelease(staticCode);
        }

        if (pid > 0) {
            SecCodeRef code = NULL;
            NSDictionary *attributes = @{ (__bridge NSString *)kSecGuestAttributePid: @(pid) };
            status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
            os_log(FIDLog(), "diagnostic: broker process lookup (pid %d) status %d", (int)pid, (int)status);
            if (code != NULL) {
                if (requirement != NULL) {
                    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
                    os_log(FIDLog(), "diagnostic: broker dynamic requirement check %d", (int)status);
                }
                CFRelease(code);
            }
        } else {
            os_log(FIDLog(), "diagnostic: broker pid unknown");
        }
        if (requirement != NULL) {
            CFRelease(requirement);
        }
    });
}

// MARK: - Mechanism

@interface FIDMechanism : NSObject
- (instancetype)initWithCallbacks:(const AuthorizationCallbacks *)callbacks
                           engine:(AuthorizationEngineRef)engine
                 agentRequirement:(nullable NSString *)agentRequirement;
- (void)invoke;
- (void)deactivate;
- (void)destroy;
@end

@implementation FIDMechanism {
    const AuthorizationCallbacks *_callbacks;
    AuthorizationEngineRef _engine;
    NSString *_agentRequirement;
    NSString *_requestID;
    NSXPCConnection *_connection;
    BOOL _invoked;
    BOOL _agentReplied;
    BOOL _resultSet;
    BOOL _deactivated;
    BOOL _destroyed;
}

- (instancetype)initWithCallbacks:(const AuthorizationCallbacks *)callbacks
                           engine:(AuthorizationEngineRef)engine
                 agentRequirement:(NSString *)agentRequirement {
    if ((self = [super init])) {
        _callbacks = callbacks;
        _engine = engine;
        _agentRequirement = [agentRequirement copy];
    }
    return self;
}

/// Main queue only.
- (void)invoke {
    if (_invoked || _deactivated || _destroyed) {
        return;
    }
    _invoked = YES;
    _requestID = [NSUUID UUID].UUIDString;

    if (_agentRequirement == nil) {
        os_log_error(FIDLog(), "plugin is not certificate-signed; cannot verify the broker");
        [self finishWithResult:kNotAcceptedResult agentUID:0 reason:"unsigned plugin"];
        return;
    }

    @try {
        // Privileged: the broker's service lives in the system domain (a LaunchDaemon).
        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:kMachServiceName
                                                                               options:NSXPCConnectionPrivileged];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FaceIDBrokerAuthProtocol)];
        // An impostor service registered under our name fails this check, and its replies never arrive.
        [connection setCodeSigningRequirement:_agentRequirement];

        __weak FIDMechanism *weakSelf = self;
        connection.invalidationHandler = ^{
            // Give the pending call's error handler a moment to log *why* (e.g. code 4102,
            // signature check failed) before the result is set and the connection torn down.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [weakSelf finishWithResult:kNotAcceptedResult agentUID:0 reason:"connection invalidated"];
            });
        };
        connection.interruptionHandler = ^{
            FIDOnMain(^{ [weakSelf finishWithResult:kNotAcceptedResult agentUID:0 reason:"connection interrupted"]; });
        };
        _connection = connection;
        [connection resume];

        __weak NSXPCConnection *diagnosticConnection = connection;
        NSString *diagnosticRequirement = _agentRequirement;
        id<FaceIDBrokerAuthProtocol> agent = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            // Domain and code only: 4097 interrupted, 4099 invalid (lookup failed or peer gone),
            // 4102 code signing requirement failed.
            os_log(FIDLog(), "xpc error %{public}@ %ld", error.domain, (long)error.code);
            if (error.code == NSXPCConnectionCodeSigningRequirementFailure) {
                FIDLogBrokerSignatureDiagnostics(diagnosticConnection.processIdentifier, diagnosticRequirement);
            }
            FIDOnMain(^{ [weakSelf finishWithResult:kNotAcceptedResult agentUID:0 reason:"xpc error"]; });
        }];
        [agent authenticateWithRequestID:_requestID reply:^(NSInteger code, uint32_t sessionOwner) {
            // The broker (verified above) takes this uid from the agent's verified connection.
            uid_t agentUID = (uid_t)sessionOwner;
            FIDOnMain(^{
                FIDMechanism *strongSelf = weakSelf;
                if (strongSelf != nil) {
                    strongSelf->_agentReplied = YES;
                }
                if (code == kAuthResultCodeMatch) {
                    [weakSelf finishWithResult:kAuthorizationResultAllow agentUID:agentUID reason:"match"];
                } else {
                    [weakSelf finishWithResult:kNotAcceptedResult agentUID:0 reason:"no match"];
                }
            });
        }];
    } @catch (NSException *exception) {
        (void)exception;
        [self finishWithResult:kNotAcceptedResult agentUID:0 reason:"exception"];
        return;
    }

    __weak FIDMechanism *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kScanTimeoutSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf finishWithResult:kNotAcceptedResult agentUID:0 reason:"timeout"];
    });
}

/// Main queue only. Sets the result exactly once.
- (void)finishWithResult:(AuthorizationResult)result agentUID:(uid_t)agentUID reason:(const char *)reason {
    if (_resultSet || _deactivated || _destroyed) {
        return;
    }
    _resultSet = YES;
    os_log(FIDLog(), "face mechanism finished: %{public}s", reason);

    if (result == kAuthorizationResultAllow && kSetSessionOwnerContext && ![self setSessionOwnerContext:agentUID]) {
        result = kNotAcceptedResult;   // could not describe who authenticated: fail closed
    }
    [self stopAgentScan];
    _callbacks->SetResult(_engine, result);
}

/// Mirrors what builtin:authenticate records for the authenticated user.
- (BOOL)setSessionOwnerContext:(uid_t)uid {
    if (uid == 0) {
        return NO;   // root never owns a GUI session; treat as unknown
    }
    struct passwd *entry = getpwuid(uid);
    if (entry == NULL || entry->pw_name == NULL) {
        return NO;
    }
    AuthorizationValue uidValue = { sizeof(uid), &uid };
    AuthorizationValue nameValue = { strlen(entry->pw_name) + 1, entry->pw_name };
    return _callbacks->SetContextValue(_engine, kAuthorizationEnvironmentUsername, kAuthorizationContextFlagExtractable, &nameValue) == errAuthorizationSuccess
        && _callbacks->SetContextValue(_engine, "uid", kAuthorizationContextFlagExtractable, &uidValue) == errAuthorizationSuccess;
}

/// Main queue only.
- (void)deactivate {
    if (_destroyed) {
        return;
    }
    if (!_resultSet && !_deactivated) {
        _deactivated = YES;
        [self stopAgentScan];
    }
    _callbacks->DidDeactivate(_engine);
}

/// Main queue only. After this, the engine reference is invalid and nothing may call back.
- (void)destroy {
    _destroyed = YES;
    [self stopAgentScan];
    _engine = NULL;
}

- (void)stopAgentScan {
    NSXPCConnection *connection = _connection;
    _connection = nil;
    if (connection == nil) {
        return;
    }
    @try {
        if (!_agentReplied) {
            // Timeout, deactivation or teardown while the scan runs: turn the camera off now.
            id<FaceIDBrokerAuthProtocol> agent = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { (void)error; }];
            [agent cancelAuthenticationWithRequestID:_requestID];
        }
        connection.invalidationHandler = nil;
        connection.interruptionHandler = nil;
        [connection invalidate];
    } @catch (NSException *exception) {
        (void)exception;
    }
}

@end

// MARK: - Plugin entry points (C API)

typedef struct {
    const AuthorizationCallbacks *callbacks;
    CFTypeRef agentRequirement;   // NSString, retained; may be NULL
} FIDPlugin;

static OSStatus FIDPluginDestroy(AuthorizationPluginRef inPlugin) {
    FIDPlugin *plugin = (FIDPlugin *)inPlugin;
    if (plugin != NULL) {
        if (plugin->agentRequirement != NULL) {
            CFRelease(plugin->agentRequirement);
        }
        free(plugin);
    }
    return errAuthorizationSuccess;
}

static OSStatus FIDMechanismCreate(AuthorizationPluginRef inPlugin,
                                   AuthorizationEngineRef inEngine,
                                   AuthorizationMechanismId mechanismId,
                                   AuthorizationMechanismRef *outMechanism) {
    FIDPlugin *plugin = (FIDPlugin *)inPlugin;
    if (plugin == NULL || inEngine == NULL || outMechanism == NULL || mechanismId == NULL) {
        return errAuthorizationInternal;
    }
    if (strcmp(mechanismId, kFaceMechanismId) != 0) {
        os_log_error(FIDLog(), "unknown mechanism %{public}s", mechanismId);
        return errAuthorizationInternal;
    }
    FIDMechanism *mechanism = [[FIDMechanism alloc] initWithCallbacks:plugin->callbacks
                                                               engine:inEngine
                                                     agentRequirement:(__bridge NSString *)plugin->agentRequirement];
    *outMechanism = (AuthorizationMechanismRef)CFBridgingRetain(mechanism);
    return errAuthorizationSuccess;
}

static OSStatus FIDMechanismInvoke(AuthorizationMechanismRef inMechanism) {
    if (inMechanism == NULL) {
        return errAuthorizationInternal;
    }
    FIDMechanism *mechanism = (__bridge FIDMechanism *)inMechanism;
    // Return immediately; the result is set asynchronously (allowed by AuthorizationPlugin.h).
    dispatch_async(dispatch_get_main_queue(), ^{ [mechanism invoke]; });
    return errAuthorizationSuccess;
}

static OSStatus FIDMechanismDeactivate(AuthorizationMechanismRef inMechanism) {
    if (inMechanism == NULL) {
        return errAuthorizationInternal;
    }
    FIDMechanism *mechanism = (__bridge FIDMechanism *)inMechanism;
    FIDOnMain(^{ [mechanism deactivate]; });
    return errAuthorizationSuccess;
}

static OSStatus FIDMechanismDestroy(AuthorizationMechanismRef inMechanism) {
    if (inMechanism == NULL) {
        return errAuthorizationInternal;
    }
    FIDMechanism *mechanism = CFBridgingRelease(inMechanism);
    if ([NSThread isMainThread]) {
        [mechanism destroy];
    } else {
        // Must be marked destroyed before returning, so no queued block calls back afterwards.
        dispatch_sync(dispatch_get_main_queue(), ^{ [mechanism destroy]; });
    }
    return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface kFIDPluginInterface = {
    kAuthorizationPluginInterfaceVersion,
    FIDPluginDestroy,
    FIDMechanismCreate,
    FIDMechanismInvoke,
    FIDMechanismDeactivate,
    FIDMechanismDestroy,
};

__attribute__((visibility("default")))
OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks,
                                   AuthorizationPluginRef *outPlugin,
                                   const AuthorizationPluginInterface **outPluginInterface) {
    if (callbacks == NULL || outPlugin == NULL || outPluginInterface == NULL) {
        return errAuthorizationInternal;
    }
    // We use SetResult, DidDeactivate and SetContextValue, all present since version 1.
    if (callbacks->version < 1) {
        return errAuthorizationInternal;
    }
    FIDPlugin *plugin = calloc(1, sizeof(FIDPlugin));
    if (plugin == NULL) {
        return errAuthorizationInternal;
    }
    plugin->callbacks = callbacks;
    NSString *requirement = FIDCopyAgentRequirement();
    plugin->agentRequirement = requirement != nil ? CFBridgingRetain(requirement) : NULL;

    *outPlugin = plugin;
    *outPluginInterface = &kFIDPluginInterface;
    os_log(FIDLog(), "FaceIDAuthPlugin loaded (broker verification %{public}s)", requirement != nil ? "on" : "unavailable");
    return errAuthorizationSuccess;
}
