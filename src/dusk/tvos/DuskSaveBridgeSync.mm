#import "DuskSaveBridgeSync.h"

#import <Foundation/Foundation.h>

#include <cstring>

namespace {

NSString* const kServiceType = @"_linkzenic-savebridge._tcp.";
NSString* const kTokenKey = @"DusklightSaveBridgeToken";
NSString* const kHostKey = @"DusklightSaveBridgeHost";
NSString* const kPortKey = @"DusklightSaveBridgePort";
NSString* gDataDirectory = nil;
NSString* gStatus = @"Save Bridge is not paired.";
BOOL gQuestLogReloadRequested = NO;
BOOL gReturnToTitleRequested = NO;
NSObject* gLock = [[NSObject alloc] init];

dispatch_queue_t SyncQueue() {
    static dispatch_queue_t queue = dispatch_queue_create("com.linkzenic.dusklight.save-bridge", DISPATCH_QUEUE_SERIAL);
    return queue;
}

void WriteStatus(NSString* value) { @synchronized(gLock) { gStatus = [value copy]; } }
NSString* ReadStatus() { @synchronized(gLock) { return [gStatus copy]; } }
NSString* DataDirectory() { @synchronized(gLock) { return [gDataDirectory copy]; } }

NSURL* BridgeURL(NSString* path) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* host = [defaults stringForKey:kHostKey];
    NSInteger port = [defaults integerForKey:kPortKey];
    if (host.length == 0 || port <= 0) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld%@", host, (long)port, path]];
}

typedef void (^EndpointCompletion)(NSString*, NSInteger, NSString*);
}  // namespace

@interface DuskSaveBridgeDiscovery : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property(nonatomic) NSNetServiceBrowser* browser;
@property(nonatomic) NSNetService* service;
@property(nonatomic, copy) EndpointCompletion completion;
@property(nonatomic) BOOL finished;
@end

@implementation DuskSaveBridgeDiscovery
- (void)finish:(NSString*)host port:(NSInteger)port error:(NSString*)error {
    if (_finished) return;
    _finished = YES;
    [_browser stop]; [_service stop];
    EndpointCompletion completion = _completion; _completion = nil;
    if (completion != nil) completion(host, port, error);
}
- (void)netServiceBrowser:(NSNetServiceBrowser*)browser didFindService:(NSNetService*)service moreComing:(BOOL)moreComing {
    if (_service != nil) return;
    _service = service; _service.delegate = self; [_service resolveWithTimeout:5];
}
- (void)netServiceDidResolveAddress:(NSNetService*)service {
    NSString* host = [service.hostName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
    if (host.length == 0 || service.port <= 0) { [self finish:nil port:0 error:@"Save Bridge did not provide a usable address."]; return; }
    [self finish:host port:service.port error:nil];
}
- (void)netService:(NSNetService*)service didNotResolve:(NSDictionary*)error { [self finish:nil port:0 error:@"Could not resolve Save Bridge on this network."]; }
@end

namespace {

void DiscoverBridge(EndpointCompletion completion) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DuskSaveBridgeDiscovery* discovery = [[DuskSaveBridgeDiscovery alloc] init];
        discovery.completion = completion;
        discovery.browser = [[NSNetServiceBrowser alloc] init];
        discovery.browser.delegate = discovery;
        [discovery.browser searchForServicesOfType:kServiceType inDomain:@""];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [discovery finish:nil port:0 error:@"Save Bridge was not found. Keep the Mac app open and use the same Wi-Fi network."]; });
    });
}

void Request(NSString* method, NSString* path, NSData* body, void (^completion)(NSData*, NSHTTPURLResponse*, NSError*)) {
    NSURL* url = BridgeURL(path);
    if (url == nil) { completion(nil, nil, [NSError errorWithDomain:@"SaveBridge" code:1 userInfo:nil]); return; }
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method; request.HTTPBody = body;
    NSString* token = [NSUserDefaults.standardUserDefaults stringForKey:kTokenKey];
    if (token.length > 0) [request setValue:token forHTTPHeaderField:@"X-SaveBridge-Token"];
    if (body != nil) [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        completion(data, [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse*)response : nil, error);
    }] resume];
}

bool SafeRelativePath(NSString* path) {
    if (path.length == 0 || [path hasPrefix:@"/"] || ![path.pathExtension.lowercaseString isEqualToString:@"gci"]) return false;
    for (NSString* component in path.pathComponents) if ([component isEqualToString:@".."]) return false;
    return true;
}

NSString* CanonicalSaveFile(NSString* region) {
    if ([region isEqualToString:@"USA"]) return @"01-GZ2E-gczelda2.gci";
    if ([region isEqualToString:@"EUR"]) return @"01-GZ2P-gczelda2.gci";
    if ([region isEqualToString:@"JAP"]) return @"01-GZ2J-gczelda2.gci";
    return nil;
}

NSString* RegionRoot(NSString* region) {
    return [[DataDirectory() stringByAppendingPathComponent:region] stringByAppendingPathComponent:@"Card A"];
}
NSString* EncodedPath(NSString* path) { return [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]; }
double ModifiedAt(NSString* path) { NSDate* date = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate]; return date.timeIntervalSince1970; }

NSDictionary<NSString*, NSString*>* LocalFiles(NSString* root, NSString* canonicalFile) {
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    for (NSString* relative in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        NSString* path = [root stringByAppendingPathComponent:relative];
        if ([relative isEqualToString:canonicalFile] && [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileType] isEqualToString:NSFileTypeRegular]) result[relative] = path;
    }
    return result;
}

void ReplaceLocalFile(NSString* root, NSString* relative, NSData* data, double modified) {
    NSString* destination = [root stringByAppendingPathComponent:relative];
    NSFileManager* files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* local = [NSData dataWithContentsOfFile:destination];
    if (local != nil && ![local isEqualToData:data]) [files copyItemAtPath:destination toPath:[destination stringByAppendingFormat:@".save-bridge-conflict-%.0f", NSDate.date.timeIntervalSince1970] error:nil];
    [data writeToFile:destination options:NSDataWritingAtomic error:nil];
    if (modified > 0) [files setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:modified]} ofItemAtPath:destination error:nil];
}

void SyncManifest(NSDictionary* manifest, NSString* region) {
    NSString* root = RegionRoot(region);
    NSString* canonicalFile = CanonicalSaveFile(region);
    if (canonicalFile == nil) { WriteStatus(@"Choose USA, EUR, or JAP first."); return; }
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary* remote = [NSMutableDictionary dictionary];
    for (NSDictionary* item in manifest[@"files"]) if ([item[@"path"] isEqual:canonicalFile]) remote[item[@"path"]] = item;
    NSDictionary* local = LocalFiles(root, canonicalFile);
    NSMutableSet* allPaths = [NSMutableSet setWithArray:remote.allKeys]; [allPaths addObjectsFromArray:local.allKeys];
    dispatch_group_t group = dispatch_group_create(); __block NSInteger uploads = 0, downloads = 0;
    for (NSString* relative in allPaths) {
        NSDictionary* remoteInfo = remote[relative]; NSString* localPath = local[relative];
        double remoteModified = [remoteInfo[@"modifiedAt"] doubleValue], localModified = localPath ? ModifiedAt(localPath) : 0;
        NSString* endpoint = [@"/v1/games/dusklight/files/" stringByAppendingString:EncodedPath(relative)];
        if (remoteInfo != nil && (localPath == nil || remoteModified > localModified)) {
            dispatch_group_enter(group); Request(@"GET", endpoint, nil, ^(NSData* data, NSHTTPURLResponse* response, NSError* error) { if (error == nil && response.statusCode == 200 && data != nil) { ReplaceLocalFile(root, relative, data, remoteModified); downloads++; } dispatch_group_leave(group); });
        } else if (localPath != nil && localModified > remoteModified) {
            NSData* data = [NSData dataWithContentsOfFile:localPath]; if (data == nil) continue;
            dispatch_group_enter(group); Request(@"PUT", endpoint, data, ^(NSData* data, NSHTTPURLResponse* response, NSError* error) { if (error == nil && response.statusCode == 200) uploads++; dispatch_group_leave(group); });
        }
    }
    dispatch_group_notify(group, SyncQueue(), ^{
        @synchronized(gLock) {
            gQuestLogReloadRequested = YES;
            // The game's virtual card is established by the title scene. A
            // title transition is the reliable way to make a downloaded GCI
            // the active card, even when the sync was started in-game.
            gReturnToTitleRequested = YES;
        }
        if (downloads > 0) {
            WriteStatus([NSString stringWithFormat:@"%ld save%@ downloaded; %ld uploaded. Returning to the title screen to load it.", (long)downloads, downloads == 1 ? @"" : @"s", (long)uploads]);
        } else {
            WriteStatus(uploads == 0 ? @"Dusklight saves are up to date. Returning to the title screen." : [NSString stringWithFormat:@"0 saves downloaded; %ld uploaded. Returning to the title screen.", (long)uploads]);
        }
    });
}
}  // namespace

extern "C" void DuskSaveBridgeSync_Configure(const char* directory) { @synchronized(gLock) { gDataDirectory = directory ? [NSString stringWithUTF8String:directory] : nil; } }
extern "C" void DuskSaveBridgeSync_Pair(const char* code) {
    NSString* pairingCode = code ? [NSString stringWithUTF8String:code] : @"";
    if (pairingCode.length != 6) { WriteStatus(@"Enter the six-digit code shown in Save Bridge."); return; }
    WriteStatus(@"Looking for Save Bridge…"); DiscoverBridge(^(NSString* host, NSInteger port, NSString* error) {
        if (error != nil) { WriteStatus(error); return; }
        [NSUserDefaults.standardUserDefaults setObject:host forKey:kHostKey]; [NSUserDefaults.standardUserDefaults setInteger:port forKey:kPortKey];
        NSData* body = [NSJSONSerialization dataWithJSONObject:@{@"code": pairingCode, @"device": @"Dusklight Apple TV"} options:0 error:nil];
        Request(@"POST", @"/v1/pair", body, ^(NSData* data, NSHTTPURLResponse* response, NSError* requestError) { NSDictionary* result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; NSString* token = result[@"token"]; if (requestError != nil || response.statusCode != 200 || ![token isKindOfClass:NSString.class]) { WriteStatus(@"Save Bridge pairing failed. Check the code and try again."); return; } [NSUserDefaults.standardUserDefaults setObject:token forKey:kTokenKey]; WriteStatus(@"Paired with Save Bridge. You can now sync saves."); });
    });
}
extern "C" void DuskSaveBridgeSync_SyncNow(const char* region) {
    NSString* selected = region ? [NSString stringWithUTF8String:region] : @"";
    if (![(@[@"USA", @"EUR", @"JAP"]) containsObject:selected]) { WriteStatus(@"Choose USA, EUR, or JAP first."); return; }
    if ([NSUserDefaults.standardUserDefaults stringForKey:kTokenKey].length == 0) { WriteStatus(@"Pair with Save Bridge first."); return; }
    WriteStatus(@"Checking Save Bridge saves…"); Request(@"GET", @"/v1/games/dusklight/manifest", nil, ^(NSData* data, NSHTTPURLResponse* response, NSError* error) { NSDictionary* manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; if (error != nil || response.statusCode != 200 || ![manifest isKindOfClass:NSDictionary.class]) { WriteStatus(@"Could not contact Save Bridge. Keep the Mac app open and use the same Wi-Fi network."); return; } dispatch_async(SyncQueue(), ^{ SyncManifest(manifest, selected); }); });
}
extern "C" void DuskSaveBridgeSync_GetStatus(char* buffer, size_t size) { if (buffer == nullptr || size == 0) return; std::strncpy(buffer, ReadStatus().UTF8String ?: "Save Bridge is ready.", size - 1); buffer[size - 1] = '\0'; }
extern "C" bool DuskSaveBridgeSync_ConsumeQuestLogReloadRequest() { @synchronized(gLock) { const BOOL requested = gQuestLogReloadRequested; gQuestLogReloadRequested = NO; return requested; } }
extern "C" bool DuskSaveBridgeSync_ConsumeReturnToTitleRequest() { @synchronized(gLock) { const BOOL requested = gReturnToTitleRequested; gReturnToTitleRequested = NO; return requested; } }
