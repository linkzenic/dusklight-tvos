#import "ICloudSaveSync.h"

#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "miniz.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <ranges>
#include <string>
#include <vector>

#ifndef DUSK_ICLOUD_CONTAINER_ID
#define DUSK_ICLOUD_CONTAINER_ID "iCloud.com.linkzenic.dusklight"
#endif

namespace {

NSString* const kRecordType = @"DusklightSaveBundle";
NSString* const kModifiedAtField = @"sourceModifiedAt";
NSString* const kContentsField = @"contents";

dispatch_queue_t SyncQueue() {
    static dispatch_queue_t queue =
        dispatch_queue_create("com.linkzenic.dusklight.icloud-save-sync",
                              DISPATCH_QUEUE_SERIAL);
    return queue;
}

NSObject* gStateLock = [[NSObject alloc] init];
NSString* gDataDirectory = nil;
NSString* gStatus = @"iCloud save sync is ready.";
dispatch_source_t gTimer = nil;
id gBackgroundObserver = nil;
id gForegroundObserver = nil;

void WriteStatus(NSString* status) {
    @synchronized(gStateLock) {
        gStatus = [status copy];
    }
}

NSString* ReadStatus() {
    @synchronized(gStateLock) {
        return [gStatus copy];
    }
}

NSString* DataDirectory() {
    @synchronized(gStateLock) {
        return [gDataDirectory copy];
    }
}

CKContainer* Container() {
    static CKContainer* container = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            container =
                [CKContainer containerWithIdentifier:@DUSK_ICLOUD_CONTAINER_ID];
        } @catch (NSException* exception) {
            NSString* reason = exception.reason
                                   ?: @"The CloudKit container could not be opened.";
            WriteStatus([@"iCloud unavailable: " stringByAppendingString:reason]);
        }
    });
    return container;
}

CKDatabase* Database() {
    CKContainer* container = Container();
    return container != nil ? container.privateCloudDatabase : nil;
}

CKRecordID* SaveRecordID() {
    static CKRecordID* recordID =
        [[CKRecordID alloc] initWithRecordName:@"dusklight-save-bundle-v1"];
    return recordID;
}

bool WaitForAccount() {
    CKContainer* container = Container();
    if (container == nil) {
        return false;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block CKAccountStatus accountStatus = CKAccountStatusCouldNotDetermine;
    __block NSError* accountError = nil;
    [container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError* error) {
        accountStatus = status;
        accountError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(
            semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        WriteStatus(@"iCloud did not respond. Local saves remain available.");
        return false;
    }
    if (accountStatus != CKAccountStatusAvailable) {
        NSString* reason = accountError.localizedDescription
                               ?: @"Sign in to iCloud to synchronize saves.";
        WriteStatus([@"iCloud unavailable: " stringByAppendingString:reason]);
        return false;
    }
    return true;
}

bool IsSaveRelativePath(const std::filesystem::path& relative) {
    if (relative.empty() || relative.is_absolute() || relative.has_root_path()) {
        return false;
    }
    if (std::ranges::any_of(relative, [](const auto& component) {
            return component == "..";
        })) {
        return false;
    }
    const auto first = relative.begin();
    if (first != relative.end() &&
        (*first == "USA" || *first == "EUR" || *first == "JAP")) {
        return true;
    }
    const auto filename = relative.filename().string();
    return relative.parent_path().empty() &&
           filename.starts_with("MemoryCard") &&
           relative.extension() == ".raw";
}

std::vector<std::filesystem::path> LocalSaveFiles(
    const std::filesystem::path& root) {
    std::vector<std::filesystem::path> files;
    std::error_code ec;
    for (const char* region : {"USA", "EUR", "JAP"}) {
        const auto directory = root / region;
        if (!std::filesystem::exists(directory, ec)) {
            ec.clear();
            continue;
        }
        for (std::filesystem::recursive_directory_iterator iterator{
                 directory,
                 std::filesystem::directory_options::skip_permission_denied,
                 ec}, end;
             iterator != end; iterator.increment(ec)) {
            if (ec) {
                ec.clear();
                continue;
            }
            if (iterator->is_regular_file(ec)) {
                files.push_back(iterator->path());
            }
        }
    }
    for (std::filesystem::directory_iterator iterator{
             root, std::filesystem::directory_options::skip_permission_denied, ec}, end;
         iterator != end; iterator.increment(ec)) {
        if (ec) {
            ec.clear();
            continue;
        }
        const auto relative = iterator->path().filename();
        if (iterator->is_regular_file(ec) && IsSaveRelativePath(relative)) {
            files.push_back(iterator->path());
        }
    }
    return files;
}

NSDate* LatestLocalModificationDate(const std::filesystem::path& root) {
    NSDate* latest = nil;
    NSFileManager* fileManager = NSFileManager.defaultManager;
    for (const auto& file : LocalSaveFiles(root)) {
        NSString* path = [NSString stringWithUTF8String:file.string().c_str()];
        NSDate* modified =
            [fileManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (modified != nil && (latest == nil ||
                                [modified compare:latest] == NSOrderedDescending)) {
            latest = modified;
        }
    }
    return latest;
}

bool BuildSnapshot(const std::filesystem::path& root,
                   const std::filesystem::path& archive,
                   std::string& error) {
    const auto files = LocalSaveFiles(root);
    if (files.empty()) {
        error = "No local save files have been created yet.";
        return false;
    }

    mz_zip_archive zip{};
    const auto archiveString = archive.string();
    if (!mz_zip_writer_init_file(&zip, archiveString.c_str(), 0)) {
        error = "The local saves could not be staged for iCloud.";
        return false;
    }
    bool success = true;
    for (const auto& file : files) {
        const auto relative = std::filesystem::relative(file, root);
        if (!IsSaveRelativePath(relative)) {
            continue;
        }
        const auto filename = file.string();
        const auto archiveName = relative.generic_string();
        if (!mz_zip_writer_add_file(&zip, archiveName.c_str(), filename.c_str(),
                                    nullptr, 0, MZ_BEST_SPEED)) {
            error = "A save file could not be added to the iCloud snapshot.";
            success = false;
            break;
        }
    }
    if (success && !mz_zip_writer_finalize_archive(&zip)) {
        error = "The iCloud save snapshot could not be finalized.";
        success = false;
    }
    mz_zip_writer_end(&zip);
    if (!success) {
        std::error_code ec;
        std::filesystem::remove(archive, ec);
    }
    return success;
}

bool ApplySnapshot(const std::filesystem::path& root,
                   const std::filesystem::path& archive,
                   NSDate* modifiedAt,
                   std::string& error) {
    mz_zip_archive zip{};
    const auto archiveString = archive.string();
    if (!mz_zip_reader_init_file(&zip, archiveString.c_str(), 0)) {
        error = "The iCloud save snapshot could not be opened.";
        return false;
    }

    const auto timestamp =
        std::chrono::system_clock::now().time_since_epoch().count();
    const auto staging = root / (".icloud-download-" + std::to_string(timestamp));
    const auto conflicts = root / "icloud_conflicts" / std::to_string(timestamp);
    std::error_code ec;
    std::filesystem::create_directories(staging, ec);
    bool success = !ec;
    std::vector<std::filesystem::path> extracted;

    for (mz_uint index = 0;
         success && index < mz_zip_reader_get_num_files(&zip); ++index) {
        mz_zip_archive_file_stat stat{};
        if (!mz_zip_reader_file_stat(&zip, index, &stat)) {
            error = "An iCloud save entry could not be inspected.";
            success = false;
            break;
        }
        const std::filesystem::path relative =
            std::filesystem::u8path(stat.m_filename);
        const unsigned unixType = (stat.m_external_attr >> 16) & 0170000;
        if (!IsSaveRelativePath(relative) || unixType == 0120000) {
            error = "The iCloud save snapshot contained an unsafe path.";
            success = false;
            break;
        }
        if (mz_zip_reader_is_file_a_directory(&zip, index)) {
            continue;
        }
        const auto output = staging / relative;
        std::filesystem::create_directories(output.parent_path(), ec);
        if (ec || !mz_zip_reader_extract_to_file(
                      &zip, index, output.string().c_str(), 0)) {
            error = "An iCloud save file could not be extracted.";
            success = false;
            break;
        }
        extracted.push_back(relative);
    }
    mz_zip_reader_end(&zip);

    if (success && extracted.empty()) {
        error = "The iCloud save snapshot was empty.";
        success = false;
    }
    if (!success) {
        std::filesystem::remove_all(staging, ec);
        return false;
    }

    NSFileManager* fileManager = NSFileManager.defaultManager;
    for (const auto& relative : extracted) {
        const auto source = staging / relative;
        const auto destination = root / relative;
        std::filesystem::create_directories(destination.parent_path(), ec);
        if (std::filesystem::exists(destination, ec)) {
            const auto backup = conflicts / relative;
            std::filesystem::create_directories(backup.parent_path(), ec);
            std::filesystem::copy_file(
                destination, backup,
                std::filesystem::copy_options::overwrite_existing, ec);
        }
        std::filesystem::remove(destination, ec);
        std::filesystem::rename(source, destination, ec);
        if (ec) {
            error = "A downloaded iCloud save could not replace its local copy.";
            std::filesystem::remove_all(staging, ec);
            return false;
        }
        if (modifiedAt != nil) {
            NSString* destinationPath =
                [NSString stringWithUTF8String:destination.string().c_str()];
            [fileManager setAttributes:@{NSFileModificationDate : modifiedAt}
                          ofItemAtPath:destinationPath
                                 error:nil];
        }
    }
    std::filesystem::remove_all(staging, ec);
    return true;
}

CKRecord* FetchCloudRecord() {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block CKRecord* result = nil;
    __block NSError* resultError = nil;
    [Database() fetchRecordWithID:SaveRecordID()
                completionHandler:^(CKRecord* record, NSError* error) {
                    result = record;
                    resultError = error;
                    dispatch_semaphore_signal(semaphore);
                }];
    if (dispatch_semaphore_wait(
            semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        WriteStatus(@"The iCloud save check timed out. Local saves remain available.");
        return nil;
    }
    if (resultError != nil && resultError.code != CKErrorUnknownItem) {
        WriteStatus([@"iCloud save check failed: "
            stringByAppendingString:resultError.localizedDescription]);
    }
    return result;
}

bool UploadLocalSnapshot(const std::filesystem::path& root,
                         NSDate* modifiedAt,
                         CKRecord* existingRecord) {
    const auto temporary =
        std::filesystem::path{NSTemporaryDirectory().UTF8String} /
        (std::string{"dusklight-saves-"} +
         NSUUID.UUID.UUIDString.UTF8String + ".zip");
    std::string buildError;
    if (!BuildSnapshot(root, temporary, buildError)) {
        WriteStatus([NSString stringWithUTF8String:buildError.c_str()]);
        return false;
    }

    CKRecord* record =
        existingRecord ?: [[CKRecord alloc] initWithRecordType:kRecordType
                                                      recordID:SaveRecordID()];
    record[kModifiedAtField] = modifiedAt;
    record[kContentsField] =
        [[CKAsset alloc] initWithFileURL:[NSURL fileURLWithPath:
            [NSString stringWithUTF8String:temporary.string().c_str()]]];

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError* uploadError = nil;
    [Database() saveRecord:record completionHandler:^(CKRecord* saved, NSError* error) {
        (void)saved;
        uploadError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    const bool completed =
        dispatch_semaphore_wait(
            semaphore, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0;
    std::error_code ec;
    std::filesystem::remove(temporary, ec);
    if (!completed) {
        WriteStatus(@"The iCloud save upload timed out. It will retry automatically.");
        return false;
    }
    if (uploadError != nil) {
        WriteStatus([@"iCloud save upload failed: "
            stringByAppendingString:uploadError.localizedDescription]);
        return false;
    }
    WriteStatus(@"Saves are up to date in iCloud.");
    return true;
}

void Reconcile(bool applyCloudDownloads) {
    NSString* rootString = DataDirectory();
    if (rootString.length == 0 || !WaitForAccount()) {
        return;
    }
    const std::filesystem::path root =
        std::filesystem::u8path(rootString.UTF8String);
    WriteStatus(@"Checking iCloud saves…");
    CKRecord* cloudRecord = FetchCloudRecord();
    NSDate* localDate = LatestLocalModificationDate(root);
    if (cloudRecord == nil) {
        if (localDate != nil) {
            UploadLocalSnapshot(root, localDate, nil);
        } else if ([ReadStatus() hasPrefix:@"Checking"]) {
            WriteStatus(@"iCloud is ready. No saves have been created yet.");
        }
        return;
    }

    NSDate* cloudDate = cloudRecord[kModifiedAtField] ?: cloudRecord.modificationDate;
    CKAsset* asset = cloudRecord[kContentsField];
    if (cloudDate == nil || asset.fileURL == nil) {
        WriteStatus(@"The iCloud save record is incomplete.");
        return;
    }
    if (localDate == nil || [cloudDate compare:localDate] == NSOrderedDescending) {
        if (!applyCloudDownloads) {
            WriteStatus(@"A newer iCloud save is available. Restart Dusklight to load it safely.");
            return;
        }
        std::string applyError;
        if (ApplySnapshot(root, asset.fileURL.path.UTF8String, cloudDate, applyError)) {
            WriteStatus(@"Downloaded the latest saves from iCloud.");
        } else {
            WriteStatus([NSString stringWithUTF8String:applyError.c_str()]);
        }
        return;
    }
    if ([localDate compare:cloudDate] == NSOrderedDescending) {
        UploadLocalSnapshot(root, localDate, cloudRecord);
    } else {
        WriteStatus(@"Saves are up to date in iCloud.");
    }
}

}  // namespace

extern "C" void DuskICloudSaveSync_Configure(const char* dataDirectory) {
    if (dataDirectory == nullptr) {
        return;
    }
    @synchronized(gStateLock) {
        gDataDirectory = [NSString stringWithUTF8String:dataDirectory];
    }
}

extern "C" void DuskICloudSaveSync_PrepareSaves(void) {
    dispatch_sync(SyncQueue(), ^{
        Reconcile(true);
    });
}

extern "C" void DuskICloudSaveSync_StartMonitoring(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTimer == nil) {
            gTimer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, SyncQueue());
            dispatch_source_set_timer(
                gTimer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                60 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(gTimer, ^{
                Reconcile(false);
            });
            dispatch_resume(gTimer);
        }
        NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
        if (gBackgroundObserver == nil) {
            gBackgroundObserver = [notifications
                addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification* note) {
                            (void)note;
                            DuskICloudSaveSync_SyncNow();
                        }];
        }
        if (gForegroundObserver == nil) {
            gForegroundObserver = [notifications
                addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification* note) {
                            (void)note;
                            DuskICloudSaveSync_SyncNow();
                        }];
        }
    });
}

extern "C" void DuskICloudSaveSync_StopMonitoring(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTimer != nil) {
            dispatch_source_cancel(gTimer);
            gTimer = nil;
        }
        NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
        if (gBackgroundObserver != nil) {
            [notifications removeObserver:gBackgroundObserver];
            gBackgroundObserver = nil;
        }
        if (gForegroundObserver != nil) {
            [notifications removeObserver:gForegroundObserver];
            gForegroundObserver = nil;
        }
    });
}

extern "C" void DuskICloudSaveSync_SyncNow(void) {
    __block UIBackgroundTaskIdentifier backgroundTask =
        UIBackgroundTaskInvalid;
    void (^beginBackgroundTask)(void) = ^{
        backgroundTask = [UIApplication.sharedApplication
            beginBackgroundTaskWithName:@"Dusklight iCloud Save Sync"
                       expirationHandler:^{
                           if (backgroundTask != UIBackgroundTaskInvalid) {
                               [UIApplication.sharedApplication
                                   endBackgroundTask:backgroundTask];
                               backgroundTask = UIBackgroundTaskInvalid;
                           }
                       }];
    };
    if (NSThread.isMainThread) {
        beginBackgroundTask();
    } else {
        dispatch_sync(dispatch_get_main_queue(), beginBackgroundTask);
    }

    dispatch_async(SyncQueue(), ^{
        Reconcile(false);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (backgroundTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication
                    endBackgroundTask:backgroundTask];
                backgroundTask = UIBackgroundTaskInvalid;
            }
        });
    });
}

extern "C" void DuskICloudSaveSync_GetStatus(
    char* buffer, size_t bufferSize) {
    if (buffer == nullptr || bufferSize == 0) {
        return;
    }
    const char* status = ReadStatus().UTF8String
                             ?: "iCloud save sync is ready.";
    std::strncpy(buffer, status, bufferSize - 1);
    buffer[bufferSize - 1] = '\0';
}
