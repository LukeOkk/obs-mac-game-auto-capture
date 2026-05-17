#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

#include <obs-module.h>
#include <util/threading.h>
#include <stdatomic.h>
#include <libproc.h>
#include <sys/sysctl.h>

#define PLUGIN_LOG(level, fmt, ...) blog(level, "[mac-game-auto] " fmt, ##__VA_ARGS__)

// Settings keys
#define S_STRICT_GAME_MODE       "strict_game_mode_only"
#define S_FULLSCREEN_FALLBACK    "allow_fullscreen_fallback"
#define S_USE_CATEGORY_HINT      "use_category_hint"
#define S_TREAT_IOS_AS_GAMES     "treat_ios_apps_as_games"
#define S_KEEP_CAPTURING         "keep_capturing_on_alt_tab"
#define S_CAPTURE_AUDIO          "capture_audio"
#define S_WHITELIST              "whitelist"             // editable_list (array)
#define S_RUNNING_APP_PICKER     "running_app_picker"    // transient
#define S_ADD_BUTTON             "add_running_app_btn"

// Localized labels
#define T_STRICT_GAME_MODE       obs_module_text("StrictGameModeOnly")
#define T_FULLSCREEN_FALLBACK    obs_module_text("AllowFullscreenFallback")
#define T_USE_CATEGORY_HINT      obs_module_text("UseCategoryHint")
#define T_TREAT_IOS_AS_GAMES     obs_module_text("TreatIOSAsGames")
#define T_KEEP_CAPTURING         obs_module_text("KeepCapturingOnAltTab")
#define T_CAPTURE_AUDIO          obs_module_text("CaptureAudio")
#define T_WHITELIST              obs_module_text("Whitelist")
#define T_PICKER                 obs_module_text("PickRunningApp")
#define T_ADD_BUTTON             obs_module_text("AddToWhitelist")
#define T_SOURCE_NAME            obs_module_text("SourceName")

@class GameAutoCapture;

typedef struct game_auto_data {
    obs_source_t *source;
    void *capture;
    pthread_mutex_t mutex;

    bool strict_game_mode_only;
    bool allow_fullscreen_fallback;
    bool use_category_hint;
    bool treat_ios_apps_as_games;
    bool keep_capturing_on_alt_tab;
    bool capture_audio;
} game_auto_data_t;

static NSArray<NSString *> *kLauncherBundleHints = nil;
static NSArray<NSString *> *kKnownGameBundles = nil;
static NSArray<NSString *> *kCrossOverHelperPrefixes = nil;
static NSArray<NSString *> *kCrossOverLauncherNames = nil;
static NSArray<NSString *> *kWindowTitleGamePrefixes = nil;
static NSArray<NSString *> *kIOSUtilityBlocklist = nil;
static NSArray<NSString *> *kGameWrapperPathHints = nil;
static NSArray<NSString *> *kWineLauncherExes = nil;

static void init_launcher_hints(void) {
    if (kLauncherBundleHints) return;
    kLauncherBundleHints = @[
        @"com.valvesoftware.steam",
        @"com.epicgames.EpicGamesLauncher",
        @"com.heroicgameslauncher.hgl",
        @"io.itch.itch",
        @"com.gog.galaxy",
        @"com.blizzard.BattleNet",
        @"com.apple.dock",
        @"com.apple.finder",
        @"com.apple.systempreferences",
        @"com.obsproject.obs-studio"
    ];

    // Hardcoded bundle IDs of well-known games that don't declare
    // LSSupportsGameMode or a games LSApplicationCategoryType.
    kKnownGameBundles = @[
        // Wine / CrossOver / wrapper runtimes (when running, almost certainly
        // hosting a Windows game). The CrossOver UI windows are filtered out
        // in isCrossOverRunningGame below so opening CrossOver-the-launcher
        // alone is not treated as a game.
        @"com.codeweavers.CrossOver",
        @"com.codeweavers.wine",
        @"com.kegworks-app.Kegworks",
        @"com.kegworks.Wineskin",
        @"com.heroicgameslauncher.hgl.runner",
        @"com.tkashkin.gamehub",
        @"com.gamehub.GameHub",
        @"org.dosbox-x.dosbox-x",
        @"com.utmapp.UTM",

        // Native Mac and Apple Arcade games
        @"com.roblox.RobloxPlayer",
        @"com.mojang.minecraftlauncher",
        @"com.epicgames.fortnite",
        @"com.riotgames.LeagueOfLegends",
        @"com.riotgames.valorant",
        @"com.valvesoftware.dota2",
        @"com.blizzard.worldofwarcraft",
        @"com.blizzard.overwatch",
        @"com.blizzard.diablo4",
        @"com.blizzard.hearthstone",
        @"com.activision.callofduty.modernwarfare",
        @"com.ea.eaapp",
        @"com.feralinteractive.dirt-rally",

        // iOS apps running on Apple Silicon
        @"com.innersloth.amongus",
        @"com.kitkagames.fallbuddies",       // Stumble Guys

        // Emulators (treat as games for capture purposes)
        @"org.openemu.OpenEmu",
        @"org.ryujinx.Ryujinx",              // also caught by category
        @"moe.ryujinx",
        @"net.rpcs3.rpcs3-mac",
        @"org.dolphin-emu.dolphin",
        @"com.libretro.RetroArch",
        @"org.scummvm.scummvm",
        @"org.citra-emu.citra",
        @"io.github.lime3ds.Lime3DS",
        @"org.duckstation.DuckStation",
        @"net.pcsx2.PCSX2",
        @"org.mednafen.Mednafen",
        @"org.ppsspp.ppsspp",
        @"org.cemu.cemu",
        @"com.cemu.cemu",
        @"com.provenance-emu.provenance",
        @"io.azahar-emu.Azahar",
        @"io.shadps4.shadPS4",
        @"app.suyu.Suyu",
        @"com.snes9x.macos.snes9x"
    ];

    // CrossOver wraps Windows games as helper .apps whose bundle ID begins
    // with this prefix. The trailing hash varies per game per install.
    kCrossOverHelperPrefixes = @[
        @"com.codeweavers.CrossOverHelper."
    ];

    // CrossOver helper apps that are launchers, not games. Matched by
    // CFBundleName since the bundle ID hash is per-install-unique.
    kCrossOverLauncherNames = @[
        @"Steam",
        @"Epic Games Launcher",
        @"Battle.net",
        @"GOG Galaxy",
        @"Origin",
        @"Ubisoft Connect",
        @"EA app"
    ];

    // Window-title prefixes used to identify games whose host process is
    // a generic JVM / runtime (no bundle ID, e.g. Minecraft Java edition).
    // Matched as a prefix; pick patterns conservative enough not to false-positive.
    kWindowTitleGamePrefixes = @[
        @"Minecraft"  // "Minecraft 1.21.1", "Minecraft* 26.1.2", etc.
    ];

    // Lowercased substrings that, when found in any ancestor process's
    // executable path, mark the running process as a child of a known game
    // runtime / wrapper. The wine .exe processes themselves have nil
    // bundleIdentifier, so we identify them via their parent process.
    kGameWrapperPathHints = @[
        @"crossover.app",
        @"/wine",                  // wine binaries inside CrossOver / Whisky
        @"/whisky.app",
        @"whisky-wineserver",
        @"wineskin",
        @"kegworks",
        @"heroic",
        @"gamehub",
        @"gamehubkmp",
        @"playcover",
        @"/portingkit",
        @"/utm.app"
    ];

    // Wine .exe processes that are launcher UIs, not games.
    kWineLauncherExes = @[
        @"steam.exe", @"steamwebhelper.exe",
        @"epicgameslauncher.exe", @"epicwebhelper.exe",
        @"galaxyclient.exe", @"gog galaxy.exe",
        @"battle.net.exe", @"agent.exe",
        @"origin.exe", @"originwebhelperservice.exe",
        @"eadesktop.exe", @"eadesktopfileexec.exe",
        @"upc.exe", @"ubisoftgamelauncher.exe", @"ubisoftconnect.exe",
        @"rockstar games launcher.exe", @"launcherpatcher.exe",
        @"riotclientservices.exe", @"riotclientux.exe",
        @"itchio.exe",
        @"crashpad_handler.exe", @"crashreportclient.exe",
        @"winecfg.exe", @"wineboot.exe", @"winemenubuilder.exe",
        @"services.exe", @"explorer.exe", @"plugplay.exe",
        @"winedevice.exe", @"rpcss.exe", @"svchost.exe", @"conhost.exe",
        @"dllhost.exe", @"taskhost.exe", @"lsass.exe", @"smss.exe",
        @"csrss.exe", @"winlogon.exe", @"spoolsv.exe", @"fontdrvhost.exe"
    ];

    // iOS apps that should NOT be treated as games even though they ship as
    // iOS Mac Catalyst / iPhone-on-Mac. Most iOS apps installed on Mac are
    // games, so the default is to accept; this list rejects the obvious
    // utilities to avoid auto-capturing non-game iOS apps.
    kIOSUtilityBlocklist = @[
        @"com.tranzmate.tranzmate1",         // Moovit (transit)
        @"com.waze.iphone",
        @"com.ubercab.UberClient",
        @"com.ubercab.UberEats",
        @"com.facebook.Messenger",
        @"com.facebook.Facebook",
        @"com.toyopagroup.picaboo",          // Snapchat
        @"net.whatsapp.WhatsApp",
        @"com.skype.skype",
        @"com.spotify.client",
        @"com.netflix.Netflix",
        @"com.disney.disneyplus",
        @"com.google.ios.youtube",
        @"com.google.Maps",
        @"com.apple.tv",
        @"com.apple.iCloudDriveApp",
        @"com.amazon.AmazonShopping",
        @"com.ebay.iphone",
        @"com.mercadolibre.MeLi",
        @"com.airbnb.app"
    ];
}

#pragma mark - GameAutoCapture (Objective-C core)

@interface GameAutoCapture : NSObject <SCStreamDelegate, SCStreamOutput>
@property (nonatomic, assign) game_auto_data_t *owner;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) SCRunningApplication *targetApp;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) id workspaceObserver;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) SCWindow *currentWindow;
@property (nonatomic, assign) BOOL running;
- (instancetype)initWithOwner:(game_auto_data_t *)owner;
- (void)start;
- (void)stop;
- (void)reevaluate;
@end

@implementation GameAutoCapture

- (instancetype)initWithOwner:(game_auto_data_t *)owner {
    if ((self = [super init])) {
        _owner = owner;
        _videoQueue = dispatch_queue_create("plugin.mac-game-auto.video",
                                            DISPATCH_QUEUE_SERIAL);
        init_launcher_hints();
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.running) return;
    self.running = YES;

    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    self.workspaceObserver = [nc addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                             object:nil
                                              queue:[NSOperationQueue mainQueue]
                                         usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        [weakSelf reevaluate];
    }];

    // Poll every 3s to catch windowed-game changes that don't trigger
    // workspace activation (Minecraft launcher → game world window appears
    // in same process; game switches between menu and play screens; etc.).
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                          repeats:YES
                                                            block:^(NSTimer * _Nonnull t) {
            (void)t;
            [weakSelf reevaluate];
        }];
    });

    [self reevaluate];
}

- (void)stop {
    self.running = NO;
    if (self.workspaceObserver) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self.workspaceObserver];
        self.workspaceObserver = nil;
    }
    [self teardownStream];
}

- (void)teardownStream {
    SCStream *s = self.stream;
    if (s) {
        [s stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) PLUGIN_LOG(LOG_WARNING, "stream stop error: %s",
                                  error.localizedDescription.UTF8String);
        }];
        self.stream = nil;
    }
    self.targetApp = nil;
    self.currentWindow = nil;
}

#pragma mark - Detection signals

- (BOOL)appDeclaresGameMode:(NSRunningApplication *)app {
    if (!app.bundleURL) return NO;
    NSBundle *b = [NSBundle bundleWithURL:app.bundleURL];
    id v = [b objectForInfoDictionaryKey:@"LSSupportsGameMode"];
    return ([v isKindOfClass:[NSNumber class]] && [v boolValue]);
}

// Apple's app categories for games. Any category that ends in "-games" or is
// literally "public.app-category.games" counts. macOS Game Mode auto-activates
// for apps in these categories when they go fullscreen.
- (BOOL)appCategoryIsGame:(NSRunningApplication *)app {
    if (!app.bundleURL) return NO;
    NSBundle *b = [NSBundle bundleWithURL:app.bundleURL];
    id raw = [b objectForInfoDictionaryKey:@"LSApplicationCategoryType"];
    if (![raw isKindOfClass:[NSString class]]) return NO;
    NSString *cat = (NSString *)raw;
    if (![cat hasPrefix:@"public.app-category."]) return NO;
    return [cat hasSuffix:@"-games"] || [cat isEqualToString:@"public.app-category.games"];
}

- (BOOL)isKnownLauncher:(NSString *)bundleID {
    return bundleID && [kLauncherBundleHints containsObject:bundleID];
}

- (BOOL)bundleIsKnownGame:(NSString *)bundleID {
    return bundleID && [kKnownGameBundles containsObject:bundleID];
}

// True if the app is an iOS app running on Apple Silicon (Mac Catalyst /
// iPhone-and-iPad-app-on-Mac). Reads DTPlatformName from Info.plist.
- (BOOL)appIsIOSApp:(NSRunningApplication *)app {
    if (!app.bundleURL) return NO;
    NSBundle *b = [NSBundle bundleWithURL:app.bundleURL];
    NSString *platform = [b objectForInfoDictionaryKey:@"DTPlatformName"];
    if (![platform isKindOfClass:[NSString class]]) return NO;
    return [platform isEqualToString:@"iphoneos"] || [platform isEqualToString:@"ipados"];
}

- (BOOL)isIOSUtility:(NSString *)bundleID {
    return bundleID && [kIOSUtilityBlocklist containsObject:bundleID];
}

// Process-tree helpers — walk parent PIDs to detect children of CrossOver,
// Whisky, Wineskin, Kegworks, GameHub, etc.

static pid_t parent_pid(pid_t pid) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return 0;
    return info.kp_eproc.e_ppid;
}

static NSString *exec_path_for_pid(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int n = proc_pidpath(pid, path, sizeof(path));
    if (n <= 0) return nil;
    return [NSString stringWithUTF8String:path];
}

// True if the running app's name ends in ".exe" — Windows binary under wine.
- (BOOL)appIsWineExecutable:(NSRunningApplication *)app {
    NSString *name = app.localizedName;
    return name && [name.lowercaseString hasSuffix:@".exe"];
}

// Walk up the process tree from `pid` looking for an executable whose path
// contains any wrapper-hint substring (CrossOver, Whisky, Wineskin,
// Kegworks, Heroic, GameHub, etc.). Returns the matching wrapper's
// substring on hit, nil otherwise.
- (NSString *)gameWrapperAncestorFromPID:(pid_t)pid {
    pid_t cur = pid;
    for (int depth = 0; depth < 20 && cur > 1; depth++) {
        NSString *path = exec_path_for_pid(cur);
        if (path) {
            NSString *lower = path.lowercaseString;
            for (NSString *hint in kGameWrapperPathHints) {
                if ([lower containsString:hint]) return hint;
            }
        }
        pid_t next = parent_pid(cur);
        if (next == 0 || next == cur) break;
        cur = next;
    }
    return nil;
}

// True if a wine .exe filename is a launcher we want to skip (Steam, Epic,
// GOG, Battle.net, etc.) so the user doesn't accidentally stream the
// launcher UI instead of the game.
- (BOOL)isWineLauncherExe:(NSString *)name {
    if (!name) return NO;
    return [kWineLauncherExes containsObject:name.lowercaseString];
}

// CrossOver wrapped Windows games carry a stable bundle-ID prefix. We accept
// any such helper unless its CFBundleName matches a known launcher (Steam,
// Epic Games Launcher, Battle.net, GOG Galaxy, etc.).
- (BOOL)isCrossOverWrappedGame:(NSRunningApplication *)app withBundleID:(NSString *)bid {
    if (!bid) return NO;
    BOOL prefixHit = NO;
    for (NSString *pfx in kCrossOverHelperPrefixes) {
        if ([bid hasPrefix:pfx]) { prefixHit = YES; break; }
    }
    if (!prefixHit) return NO;

    NSString *name = nil;
    if (app.bundleURL) {
        NSBundle *b = [NSBundle bundleWithURL:app.bundleURL];
        name = [b objectForInfoDictionaryKey:@"CFBundleName"];
    }
    if (name && [kCrossOverLauncherNames containsObject:name]) return NO;
    return YES;
}

// Window title fallback for apps with no bundle ID (e.g. Minecraft Java
// running inside a JVM).
- (BOOL)windowTitleLooksLikeGame:(SCWindow *)w {
    if (!w.title || w.title.length == 0) return NO;
    for (NSString *prefix in kWindowTitleGamePrefixes) {
        if ([w.title hasPrefix:prefix]) return YES;
    }
    return NO;
}

// True if any of the app's windows (not just the frontmost one) has a game-
// like title. Useful because reevaluate's frontWindow heuristic can latch
// onto a tiny empty-titled menu window even when the real game window exists.
- (BOOL)appHasGameWindow:(NSRunningApplication *)app inContent:(SCShareableContent *)content {
    if (!app) return NO;
    pid_t pid = app.processIdentifier;
    for (SCWindow *w in content.windows) {
        if (!w.owningApplication) continue;
        if (w.owningApplication.processID != pid) continue;
        if ([self windowTitleLooksLikeGame:w]) return YES;
    }
    return NO;
}

- (BOOL)windowIsFullscreen:(SCWindow *)w {
    if (!w) return NO;
    for (NSScreen *screen in [NSScreen screens]) {
        if (CGRectEqualToRect(screen.frame, w.frame)) return YES;
    }
    return NO;
}

- (NSArray<NSString *> *)currentWhitelist {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    obs_data_t *settings = obs_source_get_settings(self.owner->source);
    obs_data_array_t *arr = obs_data_get_array(settings, S_WHITELIST);
    if (arr) {
        size_t n = obs_data_array_count(arr);
        for (size_t i = 0; i < n; i++) {
            obs_data_t *item = obs_data_array_item(arr, i);
            const char *v = obs_data_get_string(item, "value");
            if (v && *v) {
                [out addObject:[NSString stringWithUTF8String:v]];
            }
            obs_data_release(item);
        }
        obs_data_array_release(arr);
    }
    obs_data_release(settings);
    return out;
}

- (BOOL)isLikelyGame:(NSRunningApplication *)app
     withFrontWindow:(SCWindow *)frontWindow
           inContent:(SCShareableContent *)content {
    if (!app) {
        PLUGIN_LOG(LOG_INFO, "reject: nil app");
        return NO;
    }
    NSString *bid = app.bundleIdentifier;
    const char *cbid = bid.UTF8String ?: "(no-bundle-id)";

    // 0. No bundle ID. This covers:
    //    - Minecraft Java via JVM ("java" process) — match by window title.
    //    - Wine .exe games under CrossOver/Whisky/Wineskin — match by walking
    //      parent process tree to find a known wrapper ancestor.
    if (!bid) {
        const char *cname = app.localizedName.UTF8String ?: "?";

        // (a) Window title looks like a known game (Minecraft etc.)
        if ([self appHasGameWindow:app inContent:content]) {
            PLUGIN_LOG(LOG_INFO, "accept: %s (matching window title)", cname);
            return YES;
        }

        // (b) Child of CrossOver / Whisky / Wineskin / GameHub / Heroic /
        //     PortingKit / PlayCover / UTM. We require both a wrapper
        //     ancestor AND that the .exe filename is not a known launcher
        //     (so streaming the Steam UI isn't accidental).
        NSString *wrapper = [self gameWrapperAncestorFromPID:app.processIdentifier];
        if (wrapper) {
            if ([self appIsWineExecutable:app] &&
                [self isWineLauncherExe:app.localizedName]) {
                PLUGIN_LOG(LOG_INFO, "reject: %s (wine launcher, child of %s)",
                           cname, wrapper.UTF8String);
                return NO;
            }
            PLUGIN_LOG(LOG_INFO, "accept: %s (child of %s)", cname, wrapper.UTF8String);
            return YES;
        }

        PLUGIN_LOG(LOG_INFO, "reject: %s (no bundleID, no matching window, no wrapper)", cname);
        return NO;
    }

    // 1. Manual whitelist always wins.
    NSArray<NSString *> *whitelist = [self currentWhitelist];
    if ([whitelist containsObject:bid]) {
        PLUGIN_LOG(LOG_INFO, "accept: %s (whitelist)", cbid);
        return YES;
    }

    // 2. App declares LSSupportsGameMode → Apple's strongest game signal.
    if ([self appDeclaresGameMode:app]) {
        PLUGIN_LOG(LOG_INFO, "accept: %s (LSSupportsGameMode)", cbid);
        return YES;
    }

    // 3. App declares a games category in LSApplicationCategoryType.
    if (self.owner->use_category_hint && [self appCategoryIsGame:app]) {
        PLUGIN_LOG(LOG_INFO, "accept: %s (game category)", cbid);
        return YES;
    }

    // 4. CrossOver-wrapped Windows game (CFBundleName not in launcher list).
    if ([self isCrossOverWrappedGame:app withBundleID:bid]) {
        PLUGIN_LOG(LOG_INFO, "accept: %s (CrossOver wrapped game)", cbid);
        return YES;
    }

    // 5. Bundle ID is in hardcoded known-games list.
    if ([self bundleIsKnownGame:bid]) {
        PLUGIN_LOG(LOG_INFO, "accept: %s (known game)", cbid);
        return YES;
    }

    // 5b. iOS app running on Apple Silicon. Most iOS apps installed on Mac
    //     are games; we accept unless explicitly blocklisted as a utility.
    if (self.owner->treat_ios_apps_as_games && [self appIsIOSApp:app]) {
        if ([self isIOSUtility:bid]) {
            PLUGIN_LOG(LOG_INFO, "reject: %s (iOS utility blocklist)", cbid);
            return NO;
        }
        PLUGIN_LOG(LOG_INFO, "accept: %s (iOS app)", cbid);
        return YES;
    }

    // 6. Window title fallback (some games rename themselves). Scan all
    //    of the app's windows, not just frontWindow.
    if ([self appHasGameWindow:app inContent:content]) {
        PLUGIN_LOG(LOG_INFO, "accept: %s (matching window title)", cbid);
        return YES;
    }

    // 7. Strict mode → reject.
    if (self.owner->strict_game_mode_only) {
        PLUGIN_LOG(LOG_INFO, "reject: %s (strict, no game signal)", cbid);
        return NO;
    }

    // 8. Loose mode + fullscreen fallback for un-declared games.
    if (self.owner->allow_fullscreen_fallback) {
        if ([self isKnownLauncher:bid]) {
            PLUGIN_LOG(LOG_INFO, "reject: %s (known launcher)", cbid);
            return NO;
        }
        if ([self windowIsFullscreen:frontWindow]) {
            PLUGIN_LOG(LOG_INFO, "accept: %s (fullscreen fallback)", cbid);
            return YES;
        }
        PLUGIN_LOG(LOG_INFO, "reject: %s (fallback on, not fullscreen)", cbid);
        return NO;
    }

    PLUGIN_LOG(LOG_INFO, "reject: %s (no rule, fallback off)", cbid);
    return NO;
}

- (BOOL)targetStillAliveInContent:(SCShareableContent *)content {
    if (!self.targetApp) return NO;
    pid_t targetPid = self.targetApp.processID;
    for (SCRunningApplication *a in content.applications) {
        if (a.processID == targetPid) return YES;
    }
    return NO;
}

- (void)reevaluate {
    if (!self.running) return;

    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent * _Nullable content,
                                                                     NSError * _Nullable error) {
        if (error || !content) {
            PLUGIN_LOG(LOG_WARNING, "getShareableContent failed: %s — "
                                    "check System Settings → Privacy → "
                                    "Screen & System Audio Recording.",
                       error.localizedDescription.UTF8String ?: "(nil)");
            return;
        }

        NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
        SCRunningApplication *scFront = nil;
        if (front) {
            for (SCRunningApplication *a in content.applications) {
                if (a.processID == front.processIdentifier) { scFront = a; break; }
            }
        }

        // Pick the largest onscreen window of the frontmost app for the
        // fullscreen heuristic. Empty-titled menu windows are usually small,
        // so largest tends to be the real game window.
        SCWindow *frontWindow = nil;
        CGFloat frontMaxArea = 0;
        if (front) {
            for (SCWindow *w in content.windows) {
                if (!w.owningApplication) continue;
                if (w.owningApplication.processID != front.processIdentifier) continue;
                if (!w.isOnScreen) continue;
                CGFloat area = w.frame.size.width * w.frame.size.height;
                if (area > frontMaxArea) { frontMaxArea = area; frontWindow = w; }
            }
        }

        BOOL frontIsGame = front && scFront &&
                           [self isLikelyGame:front
                              withFrontWindow:frontWindow
                                    inContent:content];

        if (frontIsGame) {
            // Same target app → consider rebinding only if a meaningfully better
            // window has appeared. We must NOT rebind to a smaller window just
            // because a transient menu popped up (e.g. Ryujinx briefly shows a
            // 500x500 dialog over a 1920x1080 game window).
            if (self.targetApp && self.targetApp.processID == scFront.processID) {
                SCWindow *best = [self bestCaptureWindowForApp:scFront inContent:content];
                CGWindowID curID = self.currentWindow ? self.currentWindow.windowID : 0;
                CGWindowID bestID = best ? best.windowID : 0;

                if (best && bestID != curID) {
                    // Is the current window still alive in content.windows?
                    SCWindow *currentStillThere = nil;
                    for (SCWindow *w in content.windows) {
                        if (w.windowID == curID) { currentStillThere = w; break; }
                    }

                    CGFloat curArea = currentStillThere
                        ? currentStillThere.frame.size.width * currentStillThere.frame.size.height
                        : 0;
                    CGFloat bestArea = best.frame.size.width * best.frame.size.height;

                    BOOL curGameTitle = currentStillThere &&
                        [self windowTitleLooksLikeGame:currentStillThere];
                    BOOL newGameTitle = [self windowTitleLooksLikeGame:best];

                    BOOL currentGone        = (currentStillThere == nil);
                    BOOL currentTooSmall    = currentStillThere &&
                        (currentStillThere.frame.size.width  < 400 ||
                         currentStillThere.frame.size.height < 300);
                    BOOL significantlyBigger = (bestArea > curArea * 1.5);
                    BOOL titleUpgrade       = newGameTitle && !curGameTitle;

                    if (currentGone || currentTooSmall || significantlyBigger || titleUpgrade) {
                        PLUGIN_LOG(LOG_INFO,
                                   "rebinding %s: window changed (was id=%u area=%.0f -> '%s' %.0fx%.0f id=%u, reason=%s)",
                                   scFront.bundleIdentifier.UTF8String ?: "(no bid)",
                                   curID, curArea,
                                   best.title.UTF8String ?: "(no title)",
                                   best.frame.size.width, best.frame.size.height, bestID,
                                   currentGone ? "current-gone" :
                                   currentTooSmall ? "current-too-small" :
                                   significantlyBigger ? "bigger-window" : "title-upgrade");
                        [self bindStreamToApp:scFront inContent:content];
                    }
                    // else: stay on current window
                }
                return;
            }
            [self bindStreamToApp:scFront inContent:content];
            return;
        }

        // Frontmost is NOT a game.
        if (self.owner->keep_capturing_on_alt_tab && self.targetApp &&
            [self targetStillAliveInContent:content]) {
            // Keep capturing the previously bound game even if user alt-tabs
            // to a chat window, the OBS preview, etc.
            return;
        }

        [self teardownStream];
    }];
}

#pragma mark - Stream lifecycle

- (SCWindow *)bestCaptureWindowForApp:(SCRunningApplication *)app inContent:(SCShareableContent *)content {
    // Pick the best capture window in 3 passes:
    //   1. Largest window whose title matches a known game pattern
    //      (e.g. "Minecraft* 26.1.2" beats untitled menu windows).
    //   2. Largest window at least 400x300 (real game/app window).
    //   3. Largest window of any size (last-resort fallback).
    SCWindow *targetWindow = nil;
    CGFloat maxArea = 0;
    const CGFloat kMinW = 400, kMinH = 300;

    for (SCWindow *w in content.windows) {
        if (!w.owningApplication) continue;
        if (w.owningApplication.processID != app.processID) continue;
        if (w.windowLayer != 0) continue;
        if (![self windowTitleLooksLikeGame:w]) continue;
        CGFloat area = w.frame.size.width * w.frame.size.height;
        if (area > maxArea) { maxArea = area; targetWindow = w; }
    }
    if (!targetWindow) {
        for (SCWindow *w in content.windows) {
            if (!w.owningApplication) continue;
            if (w.owningApplication.processID != app.processID) continue;
            if (w.windowLayer != 0) continue;
            if (w.frame.size.width < kMinW || w.frame.size.height < kMinH) continue;
            CGFloat area = w.frame.size.width * w.frame.size.height;
            if (area > maxArea) { maxArea = area; targetWindow = w; }
        }
    }
    if (!targetWindow) {
        for (SCWindow *w in content.windows) {
            if (!w.owningApplication) continue;
            if (w.owningApplication.processID != app.processID) continue;
            if (w.windowLayer != 0) continue;
            CGFloat area = w.frame.size.width * w.frame.size.height;
            if (area > maxArea) { maxArea = area; targetWindow = w; }
        }
    }
    return targetWindow;
}

- (void)bindStreamToApp:(SCRunningApplication *)app inContent:(SCShareableContent *)content {
    [self teardownStream];

    SCWindow *targetWindow = [self bestCaptureWindowForApp:app inContent:content];

    SCDisplay *display = content.displays.firstObject;

    SCContentFilter *filter = nil;
    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.colorSpaceName = kCGColorSpaceSRGB;
    cfg.queueDepth = 5;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.showsCursor = NO;

    // Audio: capture system audio for the same app the video filter targets.
    // Browser/chat/etc. running in background are NOT in this filter so their
    // audio doesn't enter the stream — only the captured game's audio.
    cfg.capturesAudio = self.owner->capture_audio;
    cfg.excludesCurrentProcessAudio = YES;  // never bleed OBS's own audio
    cfg.sampleRate = 48000;
    cfg.channelCount = 2;

    // Output at a fixed 1920x1080 (or display-native if smaller), with
    // scalesToFit=YES so SCStream scales the captured window content to fill
    // the output frame (aspect-preserved, letterboxed). Without this, small
    // launcher windows like Stumble Guys (154x144) render as a tiny icon on
    // OBS's 1920x1080 canvas. With this, the game fills the OBS canvas.
    size_t outW = MIN((size_t)1920, (size_t)display.width);
    size_t outH = MIN((size_t)1080, (size_t)display.height);
    cfg.width  = outW;
    cfg.height = outH;
    cfg.scalesToFit = YES;

    if (targetWindow) {
        filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
        PLUGIN_LOG(LOG_INFO,
                   "binding via window '%s' (window %.0fx%.0f → output %zux%zu, scaled)",
                   targetWindow.title.UTF8String ?: "(no title)",
                   targetWindow.frame.size.width, targetWindow.frame.size.height,
                   outW, outH);
    } else {
        filter = [[SCContentFilter alloc] initWithDisplay:display
                                    includingApplications:@[app]
                                         exceptingWindows:@[]];
        PLUGIN_LOG(LOG_INFO, "binding via display+app (output %zux%zu)", outW, outH);
    }

    NSError *err = nil;
    SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:cfg
                                               delegate:self];

    if (![stream addStreamOutput:self
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:self.videoQueue
                           error:&err]) {
        PLUGIN_LOG(LOG_WARNING, "addStreamOutput (screen) failed: %s",
                   err.localizedDescription.UTF8String);
        return;
    }
    if (self.owner->capture_audio) {
        NSError *aerr = nil;
        if (![stream addStreamOutput:self
                                type:SCStreamOutputTypeAudio
                  sampleHandlerQueue:self.videoQueue
                               error:&aerr]) {
            PLUGIN_LOG(LOG_WARNING, "addStreamOutput (audio) FAILED: %s",
                       aerr.localizedDescription.UTF8String);
        } else {
            PLUGIN_LOG(LOG_INFO, "audio output registered (sample=%u ch=%u)",
                       (uint32_t)cfg.sampleRate, (uint32_t)cfg.channelCount);
        }
    } else {
        PLUGIN_LOG(LOG_INFO, "audio disabled by setting");
    }

    [stream startCaptureWithCompletionHandler:^(NSError * _Nullable startErr) {
        if (startErr) {
            PLUGIN_LOG(LOG_WARNING, "startCapture failed: %s",
                       startErr.localizedDescription.UTF8String);
            return;
        }
        PLUGIN_LOG(LOG_INFO, "capturing app: %s (pid=%d)",
                   app.applicationName.UTF8String, app.processID);
    }];

    self.stream = stream;
    self.targetApp = app;
    self.currentWindow = targetWindow;
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    (void)stream;
    if (!CMSampleBufferIsValid(sampleBuffer)) return;

    if (type == SCStreamOutputTypeScreen) {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pb) return;
        CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

        struct obs_source_frame frame = {0};
        frame.width  = (uint32_t)CVPixelBufferGetWidth(pb);
        frame.height = (uint32_t)CVPixelBufferGetHeight(pb);
        frame.format = VIDEO_FORMAT_BGRA;
        frame.timestamp = (uint64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1.0e9);
        frame.linesize[0] = (uint32_t)CVPixelBufferGetBytesPerRow(pb);
        frame.data[0]     = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        frame.full_range  = true;

        obs_source_output_video(self.owner->source, &frame);

        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return;
    }

    if (type == SCStreamOutputTypeAudio) {
        static int audio_count = 0;
        AudioStreamBasicDescription asbd = {0};
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmt) {
            const AudioStreamBasicDescription *fmt_asbd =
                CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
            if (fmt_asbd) asbd = *fmt_asbd;
        }

        CMItemCount numFrames = CMSampleBufferGetNumSamples(sampleBuffer);
        if (numFrames <= 0) return;

        // Two-step: first call queries needed size (returns ArrayTooSmall).
        size_t neededSize = 0;
        OSStatus status =
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                                                                    &neededSize,
                                                                    NULL, 0,
                                                                    NULL, NULL,
                                                                    0, NULL);
        if (neededSize == 0) {
            PLUGIN_LOG(LOG_WARNING, "audio: size-query returned 0 (status=%d)",
                       (int)status);
            return;
        }
        AudioBufferList *abl = alloca(neededSize);
        CMBlockBufferRef blockBuffer = NULL;
        status =
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                                                                    NULL,
                                                                    abl,
                                                                    neededSize,
                                                                    kCFAllocatorDefault,
                                                                    kCFAllocatorDefault,
                                                                    0,
                                                                    &blockBuffer);
        if (status != noErr || !abl || abl->mNumberBuffers == 0) {
            PLUGIN_LOG(LOG_WARNING, "audio extract failed: status=%d nb=%u size=%zu",
                       (int)status, abl ? abl->mNumberBuffers : 0, neededSize);
            if (blockBuffer) CFRelease(blockBuffer);
            return;
        }

        // Log only the first frame to confirm audio stream is alive.
        audio_count++;
        if (audio_count == 1) {
            PLUGIN_LOG(LOG_INFO,
                       "first audio frame: %lld samples, %u ch @ %.0f Hz (fmt=%c%c%c%c planar=%s nb=%u)",
                       (long long)numFrames,
                       (uint32_t)asbd.mChannelsPerFrame,
                       asbd.mSampleRate,
                       (char)((asbd.mFormatID >> 24) & 0xFF),
                       (char)((asbd.mFormatID >> 16) & 0xFF),
                       (char)((asbd.mFormatID >>  8) & 0xFF),
                       (char)((asbd.mFormatID      ) & 0xFF),
                       (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? "yes" : "no",
                       abl->mNumberBuffers);
        }

        BOOL nonInterleaved =
            (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        BOOL isFloat =
            (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;

        struct obs_source_audio audio = {0};
        audio.frames = (uint32_t)numFrames;
        audio.samples_per_sec = asbd.mSampleRate ? (uint32_t)asbd.mSampleRate : 48000;
        audio.timestamp = (uint64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1.0e9);

        uint32_t channels = (uint32_t)asbd.mChannelsPerFrame;
        if (channels == 0) channels = (uint32_t)abl->mNumberBuffers;
        audio.speakers = (channels >= 2) ? SPEAKERS_STEREO : SPEAKERS_MONO;

        if (nonInterleaved && isFloat) {
            audio.format = AUDIO_FORMAT_FLOAT_PLANAR;
            uint32_t maxCh = abl->mNumberBuffers;
            if (maxCh > 8) maxCh = 8;
            for (uint32_t i = 0; i < maxCh; i++) {
                audio.data[i] = (uint8_t *)abl->mBuffers[i].mData;
            }
        } else if (isFloat) {
            // Interleaved Float32 — single buffer holding L R L R ...
            audio.format = AUDIO_FORMAT_FLOAT;
            audio.data[0] = (uint8_t *)abl->mBuffers[0].mData;
        } else {
            // Fallback: 16-bit interleaved (rare from SC).
            audio.format = AUDIO_FORMAT_16BIT;
            audio.data[0] = (uint8_t *)abl->mBuffers[0].mData;
        }

        obs_source_output_audio(self.owner->source, &audio);

        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    PLUGIN_LOG(LOG_WARNING, "stream stopped: %s",
               error.localizedDescription.UTF8String ?: "(no error)");
    dispatch_async(dispatch_get_main_queue(), ^{
        self.stream = nil;
        self.targetApp = nil;
        [self reevaluate];
    });
}

@end

#pragma mark - OBS Source vtable (C side)

static const char *gas_get_name(void *unused) {
    UNUSED_PARAMETER(unused);
    return T_SOURCE_NAME;
}

static void gas_update(void *data, obs_data_t *settings) {
    game_auto_data_t *d = data;
    pthread_mutex_lock(&d->mutex);
    d->strict_game_mode_only      = obs_data_get_bool(settings, S_STRICT_GAME_MODE);
    d->allow_fullscreen_fallback  = obs_data_get_bool(settings, S_FULLSCREEN_FALLBACK);
    d->use_category_hint          = obs_data_get_bool(settings, S_USE_CATEGORY_HINT);
    d->treat_ios_apps_as_games    = obs_data_get_bool(settings, S_TREAT_IOS_AS_GAMES);
    d->keep_capturing_on_alt_tab  = obs_data_get_bool(settings, S_KEEP_CAPTURING);
    d->capture_audio              = obs_data_get_bool(settings, S_CAPTURE_AUDIO);
    pthread_mutex_unlock(&d->mutex);

    GameAutoCapture *cap = (__bridge GameAutoCapture *)d->capture;
    [cap reevaluate];
}

static void *gas_create(obs_data_t *settings, obs_source_t *source) {
    game_auto_data_t *d = bzalloc(sizeof(game_auto_data_t));
    d->source = source;
    pthread_mutex_init(&d->mutex, NULL);

    GameAutoCapture *cap = [[GameAutoCapture alloc] initWithOwner:d];
    d->capture = (__bridge_retained void *)cap;

    // If this source has zero audio-mixer tracks assigned (which happens when
    // a pre-existing scene saved the source before OBS_SOURCE_AUDIO was added
    // to output_flags), route it to all 6 OBS tracks so the captured audio
    // actually reaches the recording / streaming output. We run this on a
    // delay because OBS overwrites the source's mixers AFTER gas_create with
    // the value stored in the scene config — if we set it inside gas_create
    // OBS will reset it to 0 right after.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (obs_source_get_audio_mixers(source) == 0) {
            obs_source_set_audio_mixers(source, 0x3F);
            PLUGIN_LOG(LOG_INFO, "audio mixers were 0 — set to all 6 tracks (0x3F)");
        }
    });

    gas_update(d, settings);
    [cap start];
    return d;
}

static void gas_destroy(void *data) {
    game_auto_data_t *d = data;
    GameAutoCapture *cap = (__bridge_transfer GameAutoCapture *)d->capture;
    [cap stop];
    cap = nil;
    pthread_mutex_destroy(&d->mutex);
    bfree(d);
}

static void gas_defaults(obs_data_t *settings) {
    obs_data_set_default_bool(settings, S_STRICT_GAME_MODE, true);
    obs_data_set_default_bool(settings, S_FULLSCREEN_FALLBACK, false);
    obs_data_set_default_bool(settings, S_USE_CATEGORY_HINT, true);
    obs_data_set_default_bool(settings, S_TREAT_IOS_AS_GAMES, true);
    obs_data_set_default_bool(settings, S_KEEP_CAPTURING, true);
    obs_data_set_default_bool(settings, S_CAPTURE_AUDIO, true);
}

// Button: append the picker's selected bundle ID to the whitelist array.
static bool gas_add_running_app(obs_properties_t *props, obs_property_t *prop, void *data) {
    UNUSED_PARAMETER(props);
    UNUSED_PARAMETER(prop);
    game_auto_data_t *d = data;
    if (!d || !d->source) return false;

    obs_data_t *settings = obs_source_get_settings(d->source);
    const char *picked = obs_data_get_string(settings, S_RUNNING_APP_PICKER);
    bool changed = false;
    if (picked && *picked) {
        obs_data_array_t *arr = obs_data_get_array(settings, S_WHITELIST);
        if (!arr) arr = obs_data_array_create();
        // dedupe
        bool exists = false;
        size_t n = obs_data_array_count(arr);
        for (size_t i = 0; i < n; i++) {
            obs_data_t *it = obs_data_array_item(arr, i);
            const char *v = obs_data_get_string(it, "value");
            if (v && strcmp(v, picked) == 0) exists = true;
            obs_data_release(it);
            if (exists) break;
        }
        if (!exists) {
            obs_data_t *it = obs_data_create();
            obs_data_set_string(it, "value", picked);
            obs_data_array_push_back(arr, it);
            obs_data_release(it);
            obs_data_set_array(settings, S_WHITELIST, arr);
            obs_data_set_string(settings, S_RUNNING_APP_PICKER, "");
            obs_source_update(d->source, settings);
            changed = true;
        }
        obs_data_array_release(arr);
    }
    obs_data_release(settings);
    return changed;  // true → OBS refreshes properties pane
}

static obs_properties_t *gas_properties(void *data) {
    obs_properties_t *p = obs_properties_create();

    obs_properties_add_bool(p, S_STRICT_GAME_MODE, T_STRICT_GAME_MODE);
    obs_properties_add_bool(p, S_USE_CATEGORY_HINT, T_USE_CATEGORY_HINT);
    obs_properties_add_bool(p, S_TREAT_IOS_AS_GAMES, T_TREAT_IOS_AS_GAMES);
    obs_properties_add_bool(p, S_FULLSCREEN_FALLBACK, T_FULLSCREEN_FALLBACK);
    obs_properties_add_bool(p, S_KEEP_CAPTURING, T_KEEP_CAPTURING);
    obs_properties_add_bool(p, S_CAPTURE_AUDIO, T_CAPTURE_AUDIO);

    // Dropdown listing currently-running regular apps with windows.
    obs_property_t *picker = obs_properties_add_list(p, S_RUNNING_APP_PICKER,
                                                     T_PICKER,
                                                     OBS_COMBO_TYPE_LIST,
                                                     OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(picker, "—", "");
    NSArray<NSRunningApplication *> *apps =
        [[NSWorkspace sharedWorkspace] runningApplications];
    NSMutableArray *sortable = [NSMutableArray array];
    for (NSRunningApplication *app in apps) {
        if (!app.bundleIdentifier) continue;
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        [sortable addObject:app];
    }
    [sortable sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        return [(a.localizedName ?: @"") caseInsensitiveCompare:(b.localizedName ?: @"")];
    }];
    for (NSRunningApplication *app in sortable) {
        NSString *display = [NSString stringWithFormat:@"%@  ·  %@",
                             app.localizedName ?: @"?",
                             app.bundleIdentifier];
        obs_property_list_add_string(picker, display.UTF8String,
                                     app.bundleIdentifier.UTF8String);
    }

    obs_properties_add_button(p, S_ADD_BUTTON, T_ADD_BUTTON, gas_add_running_app);

    obs_properties_add_editable_list(p, S_WHITELIST, T_WHITELIST,
                                     OBS_EDITABLE_LIST_TYPE_STRINGS,
                                     NULL, NULL);

    (void)data;
    return p;
}

struct obs_source_info game_auto_source_info = {
    .id           = "mac_game_auto_capture",
    .type         = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE,
    .get_name     = gas_get_name,
    .create       = gas_create,
    .destroy      = gas_destroy,
    .update       = gas_update,
    .get_defaults = gas_defaults,
    .get_properties = gas_properties,
    .icon_type    = OBS_ICON_TYPE_GAME_CAPTURE,
};
