// Loads FaceIDAuthPlugin.bundle with a fake authorization engine and checks its lifecycle
// rules — no SecurityAgent, no sudo, no authorizationdb changes, no camera.
//
// Usage: PluginHarness <path-to-FaceIDAuthPlugin.bundle>
// Exit status 0 when every check passes.

#import <Foundation/Foundation.h>
#import <Security/AuthorizationPlugin.h>
#import <dlfcn.h>
#import <stdio.h>

typedef OSStatus (*PluginCreateFunction)(const AuthorizationCallbacks *, AuthorizationPluginRef *, const AuthorizationPluginInterface **);

static int gSetResultCount;
static AuthorizationResult gLastResult;
static int gDidDeactivateCount;
static int gAllowCount;
static int gFailures;

static OSStatus FakeSetResult(AuthorizationEngineRef engine, AuthorizationResult result) {
    gSetResultCount++;
    gLastResult = result;
    if (result == kAuthorizationResultAllow) {
        gAllowCount++;
    }
    return errAuthorizationSuccess;
}

static OSStatus FakeRequestInterrupt(AuthorizationEngineRef engine) { return errAuthorizationSuccess; }

static OSStatus FakeDidDeactivate(AuthorizationEngineRef engine) {
    gDidDeactivateCount++;
    return errAuthorizationSuccess;
}

static OSStatus FakeSetContextValue(AuthorizationEngineRef engine, AuthorizationString key,
                                    AuthorizationContextFlags flags, const AuthorizationValue *value) {
    return errAuthorizationSuccess;
}

static void reset(void) {
    gSetResultCount = 0;
    gDidDeactivateCount = 0;
    gLastResult = kAuthorizationResultUndefined;
}

static void check(BOOL condition, const char *what) {
    printf("%s %s\n", condition ? "  ok  " : "  FAIL", what);
    if (!condition) {
        gFailures++;
    }
}

/// Runs the main run loop (which drains the main dispatch queue) for `seconds`, or until `done`.
static void runLoop(double seconds, BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        if (done != nil && done()) {
            return;
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <FaceIDAuthPlugin.bundle>\n", argv[0]);
            return 2;
        }
        // Load with dlopen only (no NSBundle registration), the harder case seen in SecurityAgentHelper.
        NSString *bundlePath = [NSString stringWithUTF8String:argv[1]];
        NSString *executable = [[bundlePath stringByAppendingPathComponent:@"Contents/MacOS"]
            stringByAppendingPathComponent:@"FaceIDAuthPlugin"];
        void *image = dlopen(executable.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (image == NULL) {
            fprintf(stderr, "cannot load plugin: %s\n", dlerror());
            return 2;
        }
        PluginCreateFunction create = (PluginCreateFunction)dlsym(image, "AuthorizationPluginCreate");
        if (create == NULL) {
            fprintf(stderr, "AuthorizationPluginCreate not exported\n");
            return 2;
        }

        static AuthorizationCallbacks callbacks = {
            .version = kAuthorizationCallbacksVersion,
            .SetResult = FakeSetResult,
            .RequestInterrupt = FakeRequestInterrupt,
            .DidDeactivate = FakeDidDeactivate,
            .SetContextValue = FakeSetContextValue,
        };
        AuthorizationPluginRef plugin = NULL;
        const AuthorizationPluginInterface *interface = NULL;
        check(create(&callbacks, &plugin, &interface) == errAuthorizationSuccess && interface != NULL, "plugin creates");
        check(interface->version == kAuthorizationPluginInterfaceVersion, "interface version 0");

        AuthorizationEngineRef engine = (AuthorizationEngineRef)(uintptr_t)0x1;
        AuthorizationMechanismRef mechanism = NULL;

        printf("unknown mechanism\n");
        check(interface->MechanismCreate(plugin, engine, "other", &mechanism) != errAuthorizationSuccess,
              "is refused");

        printf("invoke without a reachable, verified agent\n");
        reset();
        check(interface->MechanismCreate(plugin, engine, "face", &mechanism) == errAuthorizationSuccess, "mechanism creates");
        NSDate *start = [NSDate date];
        check(interface->MechanismInvoke(mechanism) == errAuthorizationSuccess, "invoke returns success");
        check([[NSDate date] timeIntervalSinceDate:start] < 0.1, "invoke returns immediately (does not block)");
        runLoop(9, ^{ return (BOOL)(gSetResultCount > 0); });
        check(gSetResultCount == 1, "sets exactly one result");
        check(gLastResult == kAuthorizationResultDeny, "result is Deny (fail closed, password rule runs next)");
        runLoop(8, nil);   // past the plugin's own 7 s timeout
        check(gSetResultCount == 1, "timeout does not set a second result");
        interface->MechanismDestroy(mechanism);

        printf("deactivate right after invoke\n");
        reset();
        interface->MechanismCreate(plugin, engine, "face", &mechanism);
        interface->MechanismInvoke(mechanism);
        interface->MechanismDeactivate(mechanism);
        runLoop(8, nil);
        check(gDidDeactivateCount == 1, "acknowledges with DidDeactivate once");
        check(gSetResultCount == 0, "sets no result after deactivation");
        interface->MechanismDestroy(mechanism);

        printf("destroy right after invoke\n");
        reset();
        interface->MechanismCreate(plugin, engine, "face", &mechanism);
        interface->MechanismInvoke(mechanism);
        interface->MechanismDestroy(mechanism);
        runLoop(8, nil);
        check(gSetResultCount == 0 && gDidDeactivateCount == 0, "never calls back after destroy");

        check(interface->PluginDestroy(plugin) == errAuthorizationSuccess, "plugin destroys");
        check(gAllowCount == 0, "never allowed without a verified agent match");

        printf("%s\n", gFailures == 0 ? "ALL CHECKS PASSED" : "CHECKS FAILED");
        return gFailures == 0 ? 0 : 1;
    }
}
