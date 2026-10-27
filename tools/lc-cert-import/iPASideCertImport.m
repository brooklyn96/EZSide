/*
 * iPASideCertImport - seeds LiveContainer's signing certificate at first launch.
 *
 * Why this exists at all:
 *
 * LiveContainer reads its signing certificate out of the app group's UserDefaults
 * suite (LCUtils.certificateData -> initWithSuiteName:[LCSharedUtils appGroupID],
 * key "LCCertificateData"). That suite is backed by a plist inside the shared app
 * group container, and that container cannot be written from a PC: house_arrest's
 * AFC session will enumerate directories through "..", but rejects GET_FILE_INFO and
 * FILE_OPEN for anything outside the vended app container. The app's own
 * standardUserDefaults is writable, but certificateData only falls back to it when
 * the suite cannot be created - which never happens once the app group entitlement
 * is granted, and the entitlement is exactly what JIT-less mode requires.
 *
 * So the write has to happen from inside LiveContainer. iPASide drops a request into
 * LiveContainer's Documents directory - which house_arrest *can* write, because
 * LiveContainer declares UIFileSharingEnabled - and injects this dylib at sign time.
 * On launch we perform the same writes LiveContainer's own importCertificate() does,
 * sparing the user a manual file-picker trip through Settings.
 *
 * Deliberately conservative: this runs before main() in an app that is not ours, so
 * every value read from the request is type-checked before use, nothing is forced
 * unwrapped, and any missing or malformed input leaves the request untouched so the
 * manual import in LiveContainer's Settings still works.
 */

#import <Foundation/Foundation.h>

/* Written by iPASide over house_arrest; deleted by us once the import is verified. */
static NSString *const kRequestFileName = @"iPASide-cert-import.plist";

/* Request keys, matching what ipaside_engine.livecontainer writes. */
static NSString *const kRequestAppGroupID = @"AppGroupID";
static NSString *const kRequestCertificateData = @"CertificateData";
static NSString *const kRequestCertificatePassword = @"CertificatePassword";

/* LiveContainer's own keys - these names are its API, not ours. */
static NSString *const kLCCertificateData = @"LCCertificateData";
static NSString *const kLCCertificatePassword = @"LCCertificatePassword";
static NSString *const kLCCertificateUpdateDate = @"LCCertificateUpdateDate";
static NSString *const kLCAppGroupID = @"LCAppGroupID";

static void iPASideLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void iPASideLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[iPASide] cert-import: %@", message);
}

/** Documents directory of the host app, where iPASide leaves the import request. */
static NSString *iPASideDocumentsPath(void) {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject;
}

/**
 * Read and validate the import request.
 *
 * Returns nil when there is nothing to do (no request) or when the request is not
 * usable, having logged the reason. A malformed request is left on disk rather than
 * deleted, so it can be inspected instead of silently vanishing.
 */
static NSDictionary *iPASideReadRequest(NSString *requestPath) {
    if (![NSFileManager.defaultManager fileExistsAtPath:requestPath]) {
        return nil;
    }

    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
    if (![request isKindOfClass:NSDictionary.class]) {
        iPASideLog(@"request at %@ is not a dictionary; ignoring", requestPath);
        return nil;
    }

    id groupID = request[kRequestAppGroupID];
    id certificateData = request[kRequestCertificateData];
    id password = request[kRequestCertificatePassword];

    if (![groupID isKindOfClass:NSString.class] || ((NSString *)groupID).length == 0) {
        iPASideLog(@"request is missing a usable %@", kRequestAppGroupID);
        return nil;
    }
    if (![certificateData isKindOfClass:NSData.class] || ((NSData *)certificateData).length == 0) {
        iPASideLog(@"request is missing a usable %@", kRequestCertificateData);
        return nil;
    }
    if (![password isKindOfClass:NSString.class]) {
        iPASideLog(@"request is missing a usable %@", kRequestCertificatePassword);
        return nil;
    }
    return request;
}

/**
 * Consume the request now that the certificate is stored.
 *
 * Only the request goes. The loose `iPASide-certificate.p12` iPASide writes beside it is
 * deliberately left in place: it is what LiveContainer's own
 * Settings -> Import Certificate reads, so leaving it means the manual route is always
 * available if the stored certificate is ever removed, replaced or rejected - without
 * needing a PC to put the file back. iPASide rewrites it on every install and refresh.
 */
static void iPASideConsumeRequest(NSString *requestPath) {
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:requestPath error:&error]) {
        iPASideLog(@"could not remove the request: %@", error.localizedDescription);
    }
}

__attribute__((constructor))
static void iPASideSeedCertificate(void) {
    NSString *documents = iPASideDocumentsPath();
    if (documents.length == 0) {
        return;
    }

    NSString *requestPath = [documents stringByAppendingPathComponent:kRequestFileName];
    NSDictionary *request = iPASideReadRequest(requestPath);
    if (request == nil) {
        return;
    }

    NSString *groupID = request[kRequestAppGroupID];
    NSData *certificateData = request[kRequestCertificateData];
    NSString *password = request[kRequestCertificatePassword];

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:groupID];
    if (group == nil) {
        iPASideLog(@"app group %@ is not accessible; leaving the request for a manual import",
                   groupID);
        return;
    }

    /* Already seeded with this exact certificate - clean up and stay quiet. This makes
     * a repeated install harmless rather than rewriting preferences on every launch. */
    id existing = [group objectForKey:kLCCertificateData];
    if ([existing isKindOfClass:NSData.class] && [existing isEqualToData:certificateData]) {
        iPASideLog(@"certificate already present in %@; removing the request", groupID);
        iPASideConsumeRequest(requestPath);
        return;
    }

    /* Exactly the writes LiveContainer's importCertificate() performs. The password is
     * mirrored into standardUserDefaults because LCUtils.setCertificatePassword does the
     * same, and LCAppGroupID is cached so LiveContainer need not re-derive it. */
    [group setObject:certificateData forKey:kLCCertificateData];
    [group setObject:password forKey:kLCCertificatePassword];
    [group setObject:NSDate.date forKey:kLCCertificateUpdateDate];

    NSUserDefaults *standard = NSUserDefaults.standardUserDefaults;
    [standard setObject:password forKey:kLCCertificatePassword];
    [standard setObject:groupID forKey:kLCAppGroupID];

    /* Force the store out before deleting the request. Preferences are normally
     * flushed lazily; if the app were killed in between, we would have removed the
     * only copy of the certificate without having persisted it anywhere. */
    [group synchronize];
    [standard synchronize];

    id readBack = [group objectForKey:kLCCertificateData];
    if (![readBack isKindOfClass:NSData.class] || ![readBack isEqualToData:certificateData]) {
        iPASideLog(@"write to %@ did not persist; leaving the request for a manual import",
                   groupID);
        return;
    }

    iPASideLog(@"imported %lu bytes into %@",
               (unsigned long)certificateData.length, groupID);
    iPASideConsumeRequest(requestPath);
}
