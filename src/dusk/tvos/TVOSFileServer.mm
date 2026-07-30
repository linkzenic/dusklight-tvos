#import "TVOSFileServer.h"

#import <Foundation/Foundation.h>
#import <Network/Network.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <sys/socket.h>

#include <atomic>
#include <cstring>

namespace {

constexpr uint64_t kMaximumUploadBytes = 4ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr size_t kMaximumHeaderBytes = 64 * 1024;

dispatch_queue_t ServerQueue() {
    static dispatch_queue_t queue =
        dispatch_queue_create("com.linkzenic.dusklight.tvos-file-transfer",
                              DISPATCH_QUEUE_SERIAL);
    return queue;
}

NSObject* gStateLock = [[NSObject alloc] init];
NSString* gStatus = @"Apple TV disc transfer is off.";
NSString* gUploadDirectory = nil;
NSString* gUploadedPath = nil;
nw_listener_t gListener = nullptr;
std::atomic_bool gRunning(false);

NSString* ReadStatus() {
    @synchronized(gStateLock) {
        return [gStatus copy];
    }
}

void WriteStatus(NSString* status) {
    @synchronized(gStateLock) {
        gStatus = [status copy];
    }
}

NSString* ReadUploadDirectory() {
    @synchronized(gStateLock) {
        return [gUploadDirectory copy];
    }
}

void WriteUploadedPath(NSString* path) {
    @synchronized(gStateLock) {
        gUploadedPath = [path copy];
    }
}

NSString* TransferURL() {
    struct ifaddrs* interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) {
        return @"http://Apple-TV.local:8080";
    }

    NSString* result = nil;
    for (struct ifaddrs* current = interfaces; current != nullptr; current = current->ifa_next) {
        if (current->ifa_addr == nullptr || current->ifa_addr->sa_family != AF_INET ||
            (current->ifa_flags & IFF_UP) == 0 || (current->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        char host[NI_MAXHOST] = {};
        if (getnameinfo(current->ifa_addr, sizeof(struct sockaddr_in), host, sizeof(host),
                        nullptr, 0, NI_NUMERICHOST) == 0) {
            result = [NSString stringWithFormat:@"http://%s:8080", host];
            break;
        }
    }
    freeifaddrs(interfaces);
    return result ?: @"http://Apple-TV.local:8080";
}

bool IsAllowedExtension(NSString* filename) {
    static NSSet<NSString*>* allowed = [NSSet setWithArray:@[
        @"iso", @"gcm", @"ciso", @"gcz", @"nfs", @"rvz", @"wbfs", @"wia", @"tgc"
    ]];
    return [allowed containsObject:filename.pathExtension.lowercaseString];
}

NSData* HTTPResponse(NSInteger status, NSString* reason, NSString* contentType, NSData* body) {
    NSString* header = [NSString
        stringWithFormat:@"HTTP/1.1 %ld %@\r\n"
                         "Content-Type: %@\r\n"
                         "Content-Length: %lu\r\n"
                         "Cache-Control: no-store\r\n"
                         "Connection: close\r\n\r\n",
                         (long)status, reason, contentType, (unsigned long)body.length];
    NSMutableData* response =
        [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [response appendData:body];
    return response;
}

NSData* TextResponse(NSInteger status, NSString* reason, NSString* text) {
    return HTTPResponse(status, reason, @"text/plain; charset=utf-8",
                        [text dataUsingEncoding:NSUTF8StringEncoding]);
}

NSData* TransferPage() {
    NSString* html =
        @"<!doctype html><html><head><meta name=viewport "
         "content='width=device-width,initial-scale=1'>"
         "<title>Dusklight Disc Transfer</title><style>"
         "body{font-family:-apple-system,system-ui;background:#100d18;color:#f7f3ff;max-width:760px;"
         "margin:48px auto;padding:0 24px}h1{color:#c4b5ff}section{background:#211a31;padding:24px;"
         "border:1px solid #4b3f68;border-radius:16px}input,button{font:inherit;margin:8px 0;"
         "padding:12px;border-radius:8px;border:0}button{background:#7562bd;color:white;"
         "font-weight:700}progress{width:100%;height:22px}#status{white-space:pre-wrap;"
         "margin-top:14px;color:#d9d0ff}</style></head><body>"
         "<h1>Dusklight</h1><section><p>Upload your own Twilight Princess GameCube disc image "
         "to this Apple TV. Supported formats: ISO/GCM, RVZ, WIA, WBFS, CISO, GCZ, NFS, and TGC."
         "</p><input id=file type=file accept='.iso,.gcm,.rvz,.wia,.wbfs,.ciso,.gcz,.nfs,.tgc'><br>"
         "<button onclick=uploadFile()>Upload Disc Image</button>"
         "<progress id=progress max=100 value=0></progress><div id=status>Ready.</div>"
         "</section><script>const fileInput=document.getElementById('file'),"
         "progressBar=document.getElementById('progress'),statusText=document.getElementById('status');"
         "function uploadFile(){const f=fileInput.files[0];"
         "if(!f){statusText.textContent='Choose a disc image first.';return;}"
         "const x=new XMLHttpRequest();x.open('PUT','/upload/'+encodeURIComponent(f.name));"
         "x.upload.onprogress=e=>{if(e.lengthComputable)progressBar.value=e.loaded/e.total*100};"
         "x.onload=()=>{statusText.textContent=x.responseText||('Upload failed (HTTP '+x.status+').')};"
         "x.onerror=()=>statusText.textContent='Network connection interrupted.';"
         "statusText.textContent='Uploading '+f.name+'…';x.send(f)}</script></body></html>";
    return HTTPResponse(200, @"OK", @"text/html; charset=utf-8",
                        [html dataUsingEncoding:NSUTF8StringEncoding]);
}

void SendAndClose(nw_connection_t connection, NSData* response) {
    void* bytes = malloc(response.length);
    if (bytes == nullptr) {
        nw_connection_cancel(connection);
        return;
    }
    memcpy(bytes, response.bytes, response.length);
    dispatch_data_t payload =
        dispatch_data_create(bytes, response.length, ServerQueue(),
                             DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(connection, payload, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                       ^(nw_error_t error) {
                           (void)error;
                           nw_connection_cancel(connection);
                       });
}

}  // namespace

@interface DuskTVOSHTTPConnection : NSObject

@property(nonatomic, strong) nw_connection_t connection;
@property(nonatomic, strong) NSMutableData* pendingHeader;
@property(nonatomic, strong) NSFileHandle* output;
@property(nonatomic, copy) NSString* temporaryPath;
@property(nonatomic, copy) NSString* destinationPath;
@property(nonatomic, copy) NSString* displayName;
@property(nonatomic) uint64_t contentLength;
@property(nonatomic) uint64_t receivedLength;
@property(nonatomic) BOOL headersComplete;
@property(nonatomic) BOOL finished;

- (instancetype)initWithConnection:(nw_connection_t)connection;
- (void)start;

@end

@implementation DuskTVOSHTTPConnection

- (instancetype)initWithConnection:(nw_connection_t)connection {
    self = [super init];
    if (self != nil) {
        self.connection = connection;
        self.pendingHeader = [NSMutableData data];
    }
    return self;
}

- (void)start {
    nw_connection_set_queue(self.connection, ServerQueue());
    nw_connection_start(self.connection);
    [self receiveNext];
}

- (void)receiveNext {
    if (self.finished) {
        return;
    }
    DuskTVOSHTTPConnection* retainedSelf = self;
    nw_connection_receive(self.connection, 1, 64 * 1024,
                          ^(dispatch_data_t content, nw_content_context_t context,
                            bool isComplete, nw_error_t error) {
                              (void)context;
                              DuskTVOSHTTPConnection* strongSelf = retainedSelf;
                              if (error != nullptr) {
                                  [strongSelf fail:@"Network transfer interrupted." status:500];
                                  return;
                              }
                              if (content != nullptr) {
                                  const void* bytes = nullptr;
                                  size_t length = 0;
                                  dispatch_data_t contiguous =
                                      dispatch_data_create_map(content, &bytes, &length);
                                  (void)contiguous;
                                  if (bytes != nullptr && length > 0) {
                                      [strongSelf consumeBytes:bytes length:length];
                                  }
                              }
                              if (!strongSelf.finished && isComplete) {
                                  if (strongSelf.headersComplete &&
                                      strongSelf.receivedLength == strongSelf.contentLength) {
                                      [strongSelf finishUpload];
                                  } else {
                                      [strongSelf
                                          fail:@"Upload ended before the complete file arrived."
                                          status:400];
                                  }
                                  return;
                              }
                              [strongSelf receiveNext];
                          });
}

- (void)consumeBytes:(const void*)bytes length:(size_t)length {
    if (!self.headersComplete) {
        [self.pendingHeader appendBytes:bytes length:length];
        if (self.pendingHeader.length > kMaximumHeaderBytes) {
            [self fail:@"Request headers are too large." status:431];
            return;
        }
        NSData* marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange boundary = [self.pendingHeader rangeOfData:marker options:0
                                                    range:NSMakeRange(0, self.pendingHeader.length)];
        if (boundary.location == NSNotFound) {
            return;
        }

        NSUInteger bodyStart = NSMaxRange(boundary);
        NSData* body = bodyStart < self.pendingHeader.length
                           ? [self.pendingHeader
                                 subdataWithRange:NSMakeRange(
                                                      bodyStart,
                                                      self.pendingHeader.length - bodyStart)]
                           : [NSData data];
        NSData* headerData =
            [self.pendingHeader subdataWithRange:NSMakeRange(0, boundary.location)];
        self.pendingHeader = nil;
        if (![self parseHeaders:headerData]) {
            return;
        }
        if (body.length > 0) {
            [self consumeBody:body];
        }
        return;
    }

    [self consumeBody:[NSData dataWithBytes:bytes length:length]];
}

- (BOOL)parseHeaders:(NSData*)data {
    NSString* headers = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString*>* lines = [headers componentsSeparatedByString:@"\r\n"];
    NSArray<NSString*>* request = [lines.firstObject
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (request.count < 2) {
        [self fail:@"Malformed HTTP request." status:400];
        return NO;
    }

    NSString* method = request[0].uppercaseString;
    NSString* target = request[1];
    if ([method isEqualToString:@"GET"] && [target isEqualToString:@"/"]) {
        self.finished = YES;
        SendAndClose(self.connection, TransferPage());
        return NO;
    }
    if (![method isEqualToString:@"PUT"] || ![target hasPrefix:@"/upload/"]) {
        [self fail:@"Open the root page and use its Upload Disc Image button." status:404];
        return NO;
    }

    uint64_t contentLength = 0;
    for (NSString* line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString* trimmedKey = [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString* key = trimmedKey.lowercaseString;
        if ([key isEqualToString:@"content-length"]) {
            contentLength = [[[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                longLongValue];
        }
    }
    if (contentLength == 0 || contentLength > kMaximumUploadBytes) {
        [self fail:@"The upload is empty or exceeds the 4 GB transfer limit." status:413];
        return NO;
    }

    NSString* encoded = [target substringFromIndex:@"/upload/".length];
    NSString* decoded = [encoded stringByRemovingPercentEncoding];
    NSString* filename = decoded.lastPathComponent;
    if (filename.length == 0 || ![filename isEqualToString:decoded] ||
        !IsAllowedExtension(filename)) {
        [self fail:@"Allowed files: ISO/GCM, RVZ, WIA, WBFS, CISO, GCZ, NFS, and TGC."
             status:415];
        return NO;
    }

    NSString* directory = ReadUploadDirectory();
    if (directory.length == 0) {
        [self fail:@"Dusklight has not prepared its disc storage folder." status:500];
        return NO;
    }

    NSError* directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&directoryError]) {
        NSString* detail = directoryError.localizedDescription ?: @"unknown filesystem error";
        [self fail:[@"Apple TV storage could not be prepared: " stringByAppendingString:detail]
             status:500];
        return NO;
    }

    self.contentLength = contentLength;
    self.destinationPath = [directory stringByAppendingPathComponent:filename];
    self.displayName = filename;
    self.temporaryPath = [directory
        stringByAppendingPathComponent:[NSString
                                           stringWithFormat:@".upload-%@",
                                                            NSUUID.UUID.UUIDString]];
    if (![[NSFileManager defaultManager] createFileAtPath:self.temporaryPath
                                                  contents:nil
                                                attributes:nil]) {
        [self fail:@"The temporary upload file could not be created." status:500];
        return NO;
    }
    self.output = [NSFileHandle fileHandleForWritingAtPath:self.temporaryPath];
    if (self.output == nil) {
        [self fail:@"The uploaded file could not be opened for writing." status:500];
        return NO;
    }
    self.headersComplete = YES;
    WriteStatus([NSString stringWithFormat:@"Receiving %@ — 0%%", filename]);
    return YES;
}

- (void)consumeBody:(NSData*)data {
    if (self.finished || data.length == 0) {
        return;
    }
    uint64_t remaining = self.contentLength - self.receivedLength;
    NSUInteger accepted = (NSUInteger)MIN((uint64_t)data.length, remaining);
    @try {
        [self.output
            writeData:accepted == data.length
                          ? data
                          : [data subdataWithRange:NSMakeRange(0, accepted)]];
    } @catch (NSException* exception) {
        (void)exception;
        [self fail:@"Apple TV storage ran out of space or became unavailable." status:507];
        return;
    }
    self.receivedLength += accepted;
    NSInteger percent = (NSInteger)((self.receivedLength * 100) / self.contentLength);
    WriteStatus(
        [NSString stringWithFormat:@"Receiving %@ — %ld%%", self.displayName, (long)percent]);
    if (self.receivedLength == self.contentLength) {
        [self finishUpload];
    }
}

- (void)finishUpload {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self.output closeFile];
    self.output = nil;

    NSFileManager* files = [NSFileManager defaultManager];
    NSError* error = nil;
    BOOL installed = NO;
    if ([files fileExistsAtPath:self.destinationPath]) {
        installed = [files replaceItemAtURL:[NSURL fileURLWithPath:self.destinationPath]
                                withItemAtURL:[NSURL fileURLWithPath:self.temporaryPath]
                               backupItemName:nil
                                      options:0
                             resultingItemURL:nil
                                        error:&error];
    } else {
        installed = [files moveItemAtPath:self.temporaryPath
                                   toPath:self.destinationPath
                                    error:&error];
    }
    if (!installed) {
        [files removeItemAtPath:self.temporaryPath error:nil];
        WriteStatus([@"Upload could not be installed: "
            stringByAppendingString:error.localizedDescription ?: @"unknown storage error"]);
        SendAndClose(self.connection,
                     TextResponse(500, @"Internal Server Error",
                                  @"The file arrived but could not be installed."));
        return;
    }

    WriteUploadedPath(self.destinationPath);
    WriteStatus([NSString stringWithFormat:@"%@ uploaded. Dusklight is verifying it now.",
                                           self.displayName]);
    SendAndClose(self.connection,
                 TextResponse(201, @"Created",
                              @"Upload complete. Dusklight is verifying the disc automatically."));
}

- (void)fail:(NSString*)message status:(NSInteger)status {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self.output closeFile];
    self.output = nil;
    if (self.temporaryPath != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:self.temporaryPath error:nil];
    }
    WriteStatus(message);
    SendAndClose(self.connection, TextResponse(status, @"Upload Error", message));
}

@end

extern "C" void DuskTVOSFileServer_Start(const char* uploadDirectory) {
    if (uploadDirectory == nullptr || uploadDirectory[0] == '\0') {
        WriteStatus(@"Dusklight could not determine its disc storage folder.");
        return;
    }
    @synchronized(gStateLock) {
        gUploadDirectory = [NSString stringWithUTF8String:uploadDirectory];
    }
    WriteStatus([NSString stringWithFormat:@"Starting disc transfer… Open %@", TransferURL()]);

    dispatch_async(ServerQueue(), ^{
        if (gListener != nullptr) {
            return;
        }
        nw_parameters_t parameters =
            nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                            NW_PARAMETERS_DEFAULT_CONFIGURATION);
        gListener = nw_listener_create_with_port("8080", parameters);
        if (gListener == nullptr) {
            WriteStatus(@"Could not start Apple TV disc transfer.");
            return;
        }
        nw_advertise_descriptor_t descriptor =
            nw_advertise_descriptor_create_bonjour_service(
                "Dusklight", "_dusklight-transfer._tcp", nullptr);
        nw_listener_set_advertise_descriptor(gListener, descriptor);
        nw_listener_set_queue(gListener, ServerQueue());
        nw_listener_set_state_changed_handler(
            gListener, ^(nw_listener_state_t state, nw_error_t error) {
                (void)error;
                if (state == nw_listener_state_ready) {
                    gRunning.store(true);
                    WriteStatus([NSString
                        stringWithFormat:@"On a phone or computer, open %@", TransferURL()]);
                } else if (state == nw_listener_state_failed) {
                    gRunning.store(false);
                    WriteStatus(@"Apple TV disc transfer failed to start.");
                    nw_listener_cancel(gListener);
                    gListener = nullptr;
                } else if (state == nw_listener_state_cancelled) {
                    gRunning.store(false);
                    gListener = nullptr;
                }
            });
        nw_listener_set_new_connection_handler(gListener, ^(nw_connection_t connection) {
            DuskTVOSHTTPConnection* handler =
                [[DuskTVOSHTTPConnection alloc] initWithConnection:connection];
            [handler start];
        });
        nw_listener_start(gListener);
    });
}

extern "C" void DuskTVOSFileServer_Stop(void) {
    dispatch_async(ServerQueue(), ^{
        if (gListener != nullptr) {
            nw_listener_cancel(gListener);
        }
        gRunning.store(false);
        WriteStatus(@"Apple TV disc transfer is off.");
    });
}

extern "C" int DuskTVOSFileServer_IsRunning(void) {
    return gRunning.load() ? 1 : 0;
}

extern "C" void DuskTVOSFileServer_GetStatus(char* buffer, size_t bufferSize) {
    if (buffer == nullptr || bufferSize == 0) {
        return;
    }
    const char* status = ReadStatus().UTF8String ?: "Apple TV disc transfer is unavailable.";
    std::strncpy(buffer, status, bufferSize - 1);
    buffer[bufferSize - 1] = '\0';
}

extern "C" int DuskTVOSFileServer_TakeUploadedPath(char* buffer, size_t bufferSize) {
    if (buffer == nullptr || bufferSize == 0) {
        return 0;
    }
    @synchronized(gStateLock) {
        if (gUploadedPath.length == 0) {
            buffer[0] = '\0';
            return 0;
        }
        const char* path = gUploadedPath.UTF8String;
        if (path == nullptr || std::strlen(path) >= bufferSize) {
            return 0;
        }
        std::strcpy(buffer, path);
        gUploadedPath = nil;
        return 1;
    }
}
