// Now Playing bridge for OmniFlow's direct build. Since macOS 15.4, MediaRemote
// only answers Apple-signed processes, so this library is loaded into
// /usr/bin/perl (see nowplaying.pl) and talks to OmniFlow over stdio:
//   stdout: one JSON object per change {"title","artist","album","duration",
//           "elapsed","rate","sampledAt","artwork"(base64, only when it changes)}
//   stdin:  one command per line: toggle | play | pause | next | previous
// Private API: excluded from the App Store build; OmniFlow treats any failure
// as "Now Playing unavailable".
// Technique credit: ungive/mediaremote-adapter (loading into perl). No code copied.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);

static MRGetInfo getInfo;
static MRSendCommand sendCommand;
static NSData *lastArtwork;
static NSString *lastLine;

static void emit(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSDictionary *keys = @{@"title": @"kMRMediaRemoteNowPlayingInfoTitle", @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
                               @"album": @"kMRMediaRemoteNowPlayingInfoAlbum", @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
                               @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime", @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate"};
        for (NSString *name in keys) {
            id value = info[keys[name]];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) out[name] = value;
        }
        NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        out[@"sampledAt"] = @([stamp isKindOfClass:NSDate.class] ? stamp.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artwork isKindOfClass:NSData.class] && artwork.length < 2000000 && ![artwork isEqualToData:lastArtwork]) {
            lastArtwork = artwork;
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
        NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        if (out[@"artwork"] == nil && [line isEqualToString:lastLine]) return;
        lastLine = line;
        fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout);
    });
}

// Called by perl as an XSUB; its arguments are ignored. Never returns while stdin is open.
void omniflow_nowplaying_run(void *unusedPerl, void *unusedCV) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (MRGetInfo)dlsym(framework, "MRMediaRemoteGetNowPlayingInfo");
    MRRegister registerForNotifications = (MRRegister)dlsym(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
    sendCommand = (MRSendCommand)dlsym(framework, "MRMediaRemoteSendCommand");
    if (!getInfo || !registerForNotifications || !sendCommand) { fputs("{\"unavailable\":true}\n", stdout); fflush(stdout); exit(3); }
    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { emit(); }];
    }
    emit();
    // The first answer can arrive before MediaRemote has connected; ask again shortly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[64];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *command = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            // MRMediaRemoteCommand: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
            NSDictionary *codes = @{@"play": @0, @"pause": @1, @"toggle": @2, @"next": @4, @"previous": @5};
            NSNumber *code = codes[command];
            if (code) dispatch_async(dispatch_get_main_queue(), ^{ sendCommand(code.intValue, nil); });
        }
        exit(0);   // OmniFlow closed the pipe.
    });
    CFRunLoopRun();
}
