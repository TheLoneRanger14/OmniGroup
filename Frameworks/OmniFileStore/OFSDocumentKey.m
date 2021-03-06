// Copyright 2014-2017 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OFSDocumentKey-Internal.h"

#import <Security/Security.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/NSArray-OFExtensions.h>
#import <OmniFoundation/NSDictionary-OFExtensions.h>
#import <OmniFoundation/NSIndexSet-OFExtensions.h>
#import <OmniFoundation/NSMutableDictionary-OFExtensions.h>
#import <OmniFoundation/OFErrors.h>
#import <OmniFoundation/OFSymmetricKeywrap.h>
#import <OmniFileStore/Errors.h>
#import <OmniFileStore/OFSDocumentKey-KeychainStorageSupport.h>
#import <OmniFileStore/OFSEncryptionConstants.h>
#import <OmniFileStore/OFSSegmentedEncryptionWorker.h>
#import "OFSEncryption-Internal.h"
#include <stdlib.h>

RCS_ID("$Id$");

OB_REQUIRE_ARC

static uint16_t derive(uint8_t derivedKey[MAX_SYMMETRIC_KEY_BYTES], NSString *password, NSData *salt, CCPseudoRandomAlgorithm prf, unsigned int rounds, NSError **outError);
static OFSKeySlots *deriveFromPassword(NSDictionary *docInfo, NSString *password, struct skbuf *outWk, NSError **outError);

#define unsupportedError(e, t) ofsUnsupportedError_(e, __LINE__, t)
#define arraycount(a) (sizeof(a)/sizeof(a[0]))

/* String names read/written to the file */
static const struct { CFStringRef name; CCPseudoRandomAlgorithm value; } prfNames[] = {
    { CFSTR(PBKDFPRFSHA1),   kCCPRFHmacAlgSHA1   },
    { CFSTR(PBKDFPRFSHA256), kCCPRFHmacAlgSHA256 },
    { CFSTR(PBKDFPRFSHA512), kCCPRFHmacAlgSHA512 },
};

@interface OFSMutableDocumentKey ()
- (instancetype)_init;
@end

@implementation OFSDocumentKey

- initWithData:(NSData *)storeData error:(NSError **)outError;
{
    self = [super init];
    
    memset(&wk, 0, sizeof(wk));
    
    if (storeData != nil) {
        NSError * __autoreleasing error = NULL;
        NSArray *docInfo = [NSPropertyListSerialization propertyListWithData:storeData
                                                                     options:NSPropertyListImmutable
                                                                      format:NULL
                                                                       error:&error];
        if (!docInfo) {
            if (outError) {
                *outError = error;
                OFSError(outError, OFSEncryptionBadFormat, @"Could not decrypt file", @"Could not read encryption header");
            }
            return nil;
        }
        
        __block BOOL contentsLookReasonable = YES;
        
        if (![docInfo isKindOfClass:[NSArray class]]) {
            contentsLookReasonable = NO;
        }
        
        if (contentsLookReasonable) {
            [docInfo enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop){
                if (![obj isKindOfClass:[NSDictionary class]]) {
                    contentsLookReasonable = NO;
                    *stop = YES;
                    return;
                }
                
                NSString *method = [obj objectForKey:KeyDerivationMethodKey];
                if ([method isEqual:KeyDerivationMethodPassword] && !passwordDerivation) {
                    passwordDerivation = obj;
                } else {
                    // We might eventually want to mark ourselves as read-only if we have a passwordDerivation and also some derivations we don't understand.
                    // For now we just fail completely in that case.
                    contentsLookReasonable = NO;
                }
            }];
        }
        
        if (!contentsLookReasonable) {
            if (outError) {
                OFSError(outError, OFSEncryptionBadFormat, @"Could not decrypt file", @"Could not read encryption header");
            }
            return nil;
        }
    }
    
    return self;
}

- (NSData *)data;
{
    /* Return an NSData blob with the information we'll need to recover the document key in the future. The caller will presumably store this blob in the underlying file manager or somewhere related, and hand it back to us via -initWithData:error:. */
    NSArray *docInfo = [NSArray arrayWithObject:passwordDerivation];
    NSError * __autoreleasing serializationError = nil;
    NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:docInfo format:NSPropertyListXMLFormat_v1_0 options:0 error:&serializationError];
    if (!serialized) {
        /* This really shouldn't ever happen, since we generate the plist ourselves. Throw an exception instead of propagating the error. */
        [NSException exceptionWithName:NSInternalInconsistencyException reason:@"OFSDocumentKey: unable to serialize" userInfo:@{ @"error": serializationError }];
    }
    
    /* clang-sa doesn't recognize the throw above, so cast this as non-null to avoid an analyzer false positive */
    return (NSData * _Nonnull)serialized;
}

- (id)copyWithZone:(nullable NSZone *)zone
{
    OBASSERT([self isMemberOfClass:[OFSDocumentKey class]]);  // Make sure we're exactly an OFSDocumentKey, not an OFSMutableDocumentKey
    return self;
}

- (id)mutableCopyWithZone:(nullable NSZone *)zone
{
    OFSDocumentKey *newInstance = [[OFSMutableDocumentKey alloc] _init];
    newInstance->passwordDerivation = [passwordDerivation copy];
    newInstance->slots = [slots copy];
    newInstance->wk = wk;
    newInstance->_prefix = _prefix;
    
    return newInstance;
}

- (NSInteger)changeCount;
{
    return 0;
}

@dynamic valid, hasPassword;

- (BOOL)valid;
{
    return (slots != nil)? YES : NO;
}

@synthesize keySlots = slots;

#pragma mark Passphrase handling and wrapping/unwrapping

- (BOOL)hasPassword;
{
    return (passwordDerivation != nil)? YES : NO;
}

- (BOOL)deriveWithPassword:(NSString *)password error:(NSError **)outError;
{
    OFSKeySlots *derivedKeyTable = deriveFromPassword(passwordDerivation, password, &wk, outError);
    if (derivedKeyTable && wk.len) {
        slots = derivedKeyTable;
        return YES;
    } else {
        // If we got a password but the derivation failed with a decode error, wrap that up in our own bad-password error
        // Note that the kCCDecodeError code here is actually set by other OFS bits – per unwrapData() in OFSDocumentKey.m, CCSymmetricKeyUnwrap() can return bad codes, so we substitute a better code there
        // (If the CommonCrypto unwrap function is someday updated to conform to its own documentation, it will return kCCDecodeError naturally)
        if (outError && [*outError hasUnderlyingErrorDomain:NSOSStatusErrorDomain code:kCCDecodeError]) {
            id wrongPasswordInfoValue;
#if defined(DEBUG)
            wrongPasswordInfoValue = password;
#else
            wrongPasswordInfoValue = @YES;
#endif
            
            NSString *description = NSLocalizedStringFromTableInBundle(@"Incorrect encryption password.", @"OmniFileStore", OMNI_BUNDLE, @"bad password error description");
            NSString *reason = NSLocalizedStringFromTableInBundle(@"Could not decode encryption document key.", @"OmniFileStore", OMNI_BUNDLE, @"bad password error reason");
            OFSErrorWithInfo(outError, OFSEncryptionNeedAuth, description, reason, OFSEncryptionWrongPassword, wrongPasswordInfoValue, nil);
        }
        
        return NO;
    }
}

static unsigned calibratedRoundCount = 1000000;
static unsigned const saltLength = 20;
static void calibrateRounds(void *dummy) {
    uint roundCount = CCCalibratePBKDF(kCCPBKDF2, 24, saltLength, kCCPRFHmacAlgSHA1, kCCKeySizeAES128, 750);
    if (roundCount > calibratedRoundCount)
        calibratedRoundCount = roundCount;
}
static dispatch_once_t calibrateRoundsOnce;

static uint16_t derive(uint8_t derivedKey[MAX_SYMMETRIC_KEY_BYTES], NSString *password, NSData *salt, CCPseudoRandomAlgorithm prf, unsigned int rounds, NSError **outError)
{
    /* TODO: A stringprep profile might be more appropriate here than simple NFC. Is there one that's been defined for unicode passwords? */
    NSData *passBytes = [[password precomposedStringWithCanonicalMapping] dataUsingEncoding:NSUTF8StringEncoding];
    if (!passBytes) {
        // Password itself was probably nil. Error out instead of crashing, though.
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain
                                            code:errSecAuthFailed
                                        userInfo:@{ NSLocalizedFailureReasonErrorKey: @"Missing password" }];
        return 0;
    }
    
    /* Note: Asking PBKDF2 for an output size that's longer than its PRF size can (depending on downstream details) increase the difficulty for the legitimate user without increasing the difficulty for an attacker, because the portions of the result can be computed in parallel. That's not a problem right here since AES128 < SHA1-160, but it's something to keep in mind. */
    
    uint16_t outputLength;
    if (prf >= kCCPRFHmacAlgSHA256) {
        /* We rely on the ordering of the CCPseudoRandomAlgorithm constants here :( */
        outputLength = kCCKeySizeAES256;
    } else {
        outputLength = kCCKeySizeAES128;
    }
    _Static_assert(kCCKeySizeAES256 <= MAX_SYMMETRIC_KEY_BYTES, "");
    
    CCCryptorStatus cerr = CCKeyDerivationPBKDF(kCCPBKDF2, [passBytes bytes], [passBytes length],
                                                [salt bytes], [salt length],
                                                prf, rounds,
                                                derivedKey, outputLength);
    
    if (cerr) {
        if (outError)
            *outError = ofsWrapCCError(cerr, @"CCKeyDerivationPBKDF", nil, nil);
        return 0;
    }
    
    return outputLength;
}

static OFSKeySlots *deriveFromPassword(NSDictionary *docInfo, NSString *password, struct skbuf *outWk, NSError **outError)
{
    /* Retrieve all our parameters from the dictionary */
    NSString *alg = [docInfo objectForKey:PBKDFAlgKey];
    if (![alg isEqualToString:PBKDFAlgPBKDF2_WRAP_AES]) {
        unsupportedError(outError, alg);
        return nil;
    }
    
    unsigned pbkdfRounds = [docInfo unsignedIntForKey:PBKDFRoundsKey];
    if (!pbkdfRounds) {
        unsupportedError(outError, [docInfo objectForKey:PBKDFRoundsKey]);
        return nil;
    }
    
    NSData *salt = [docInfo objectForKey:PBKDFSaltKey];
    if (![salt isKindOfClass:[NSData class]]) {
        unsupportedError(outError, NSStringFromClass([salt class]));
        return nil;
    }
    
    id prfString = [docInfo objectForKey:PBKDFPRFKey defaultObject:@"" PBKDFPRFSHA1];
    CCPseudoRandomAlgorithm prf = 0;
    for (int i = 0; i < (int)arraycount(prfNames); i++) {
        if ([prfString isEqualToString:(__bridge NSString *)(prfNames[i].name)]) {
            prf = prfNames[i].value;
            break;
        }
    }
    if (prf == 0) {
        OFSErrorWithInfo(outError, OFSEncryptionBadFormat,
                         NSLocalizedStringFromTableInBundle(@"Could not decrypt file.", @"OmniFileStore", OMNI_BUNDLE, @"error description"),
                         NSLocalizedStringFromTableInBundle(@"Unrecognized settings in encryption header", @"OmniFileStore", OMNI_BUNDLE, @"error detail"),
                         PBKDFPRFKey, prfString, nil);
        return nil;
    }
    
    NSData *wrappedKey = [docInfo objectForKey:DocumentKeyKey];
    
    /* Derive the key-wrapping-key from the user's password */
    uint8_t wrappingKey[MAX_SYMMETRIC_KEY_BYTES];
    uint16_t wrappingKeyLength = derive(wrappingKey, password, salt, prf, pbkdfRounds, outError);
    if (!wrappingKeyLength) {
        return nil;
    }
    
    /* Unwrap the document key(s) using the key-wrapping-key */
    OFSKeySlots *retval = [[OFSKeySlots alloc] initWithData:wrappedKey wrappedWithKey:wrappingKey length:wrappingKeyLength error:outError];
    
    if (retval) {
        outWk->len = wrappingKeyLength;
        memcpy(outWk->bytes, wrappingKey, wrappingKeyLength);
    }
    
    memset(wrappingKey, 0, sizeof(wrappingKey));
    
    return retval;
}

/* Return an encryption worker for an active key slot. Encryption workers can be used from multiple threads, so we can safely cache one and return it here. */
- (nullable OFSSegmentEncryptWorker *)encryptionWorker:(NSError **)outError;
{
    OFSKeySlots *localSlots = self.keySlots;
    
    if (!localSlots) {
        if (outError)
            *outError = [NSError errorWithDomain:OFSErrorDomain code:OFSEncryptionNeedAuth userInfo:nil];
        return nil;
    }
    
    return [localSlots encryptionWorker:outError];
}

- (unsigned)flagsForFilename:(NSString *)filename;
{
    return [self.keySlots flagsForFilename:filename fromSlot:NULL];
}

- (NSString *)description;
{
    return [NSString stringWithFormat:@"<%@:%p slots=%@>", NSStringFromClass([self class]), self, [self.keySlots description]];
}

- (NSDictionary *)descriptionDictionary;   // For the UI. See keys below.
{
    NSMutableDictionary *description = [NSMutableDictionary dictionary];

    NSDictionary *slotInfo = [slots descriptionDictionary];
    if (slotInfo)
        [description addEntriesFromDictionary:slotInfo];
    
    if (passwordDerivation) {
        [description setObject:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Password (%@; %@ rounds; %@)", @"OmniFileStore", OMNI_BUNDLE, @"encryption access method description - key derivation from password"),
                                [passwordDerivation objectForKey:PBKDFAlgKey],
                                [passwordDerivation objectForKey:PBKDFRoundsKey],
                                [passwordDerivation objectForKey:PBKDFPRFKey defaultObject:@"" PBKDFPRFSHA1]]
                        forKey:OFSDocKeyDescription_AccessMethod];
    }
    
    return description;
}

#pragma mark Key identification

- (NSData *)applicationLabel;
{
    if (!passwordDerivation)
        return nil;
    
    /* We generate a unique application label for each key we store, using the salt as the unique identifier. */
    
    if ([[passwordDerivation objectForKey:PBKDFAlgKey] isEqualToString:PBKDFAlgPBKDF2_WRAP_AES]) {
        
        NSData *salt = [passwordDerivation objectForKey:PBKDFSaltKey];
        if (!salt)
            return nil;
        NSString *prf = [passwordDerivation objectForKey:PBKDFPRFKey defaultObject:@"" PBKDFPRFSHA1];
        
        NSMutableData *label = [[[NSString stringWithFormat:@"PBKDF2$%@$", prf] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        
        if (_prefix) {
            [label replaceBytesInRange:(NSRange){0,0} withBytes:":" length:1];
            [label replaceBytesInRange:(NSRange){0,0} withBytes:_prefix length:strlen(_prefix)];
        }
        
        [label appendData:salt];
        
        return label;
    }
    
    return nil;
}

@end

#pragma mark -

@implementation OFSMutableDocumentKey
{
    OFSMutableKeySlots *mutableSlots;
    
    /* Incremented when -data changes */
    NSInteger additionalChangeCount;
}

- (instancetype)_init
{
    return [super initWithData:nil error:NULL];
}

- (instancetype)init
{
    return [self initWithData:nil error:NULL];
}

- initWithData:(NSData *)storeData error:(NSError **)outError;
{
    if (!(self = [super initWithData:storeData error:outError])) {
        return nil;
    }
    
    // Unlike an immutable key, initializing a mutable key with no data produces a valid, but empty, key table.
    if (!storeData) {
        OBASSERT(!slots);
        mutableSlots = [[OFSMutableKeySlots alloc] init];
    }
    
    return self;
}

- (instancetype)initWithAuthenticator:(OFSDocumentKey *)source error:(NSError **)outError;
{
    self = [self init];
    
    if (!(source.valid)) {
        unsupportedError(outError, @"source.valid = NO");
        return nil;
    }
    
    passwordDerivation = [source->passwordDerivation dictionaryWithObjectRemovedForKey:DocumentKeyKey];
    slots = nil;
    mutableSlots = [[OFSMutableKeySlots alloc] init];
    memcpy(&wk, &(source->wk), sizeof(wk));
    
    return self;
}

- (id)copyWithZone:(NSZone *)zone;
{
    [self _updateInner];
    OFSDocumentKey *newInstance = [[OFSDocumentKey alloc] initWithData:nil error:NULL];
    newInstance->passwordDerivation = [passwordDerivation copy];
    newInstance->slots = [slots copy];
    newInstance->wk = wk;
    newInstance->_prefix = _prefix;
    
    return newInstance;
}

- (id)mutableCopyWithZone:(nullable NSZone *)zone
{
    [self _updateInner];
    OFSMutableDocumentKey *newInstance = [super mutableCopyWithZone:zone];
    newInstance->additionalChangeCount = additionalChangeCount;
    
    return newInstance;
}

- (OFSKeySlots *)keySlots;
{
    [self _updateInner];
    return super.keySlots;
}

- (BOOL)valid;
{
    return (slots != nil || mutableSlots != nil)? YES : NO;
}

- (OFSMutableKeySlots *)mutableKeySlots;
{
    [self _makeMutableSlots:_cmd];
    return mutableSlots;
}

- (BOOL)deriveWithPassword:(NSString *)password error:(NSError **)outError;
{
    slots = nil;
    mutableSlots = nil;
    return [super deriveWithPassword:password error:outError];
}

- (NSString *)description;
{
    if (mutableSlots) {
        return [NSString stringWithFormat:@"<%@:%p cc=%" PRIdNS " mutableSlots=%@>", NSStringFromClass([self class]), self, additionalChangeCount, [mutableSlots description]];
    }
    
    return [super description];
}

- (NSDictionary *)descriptionDictionary;
{
    [self _updateInner];
    return [super descriptionDictionary];
}

- (NSInteger)changeCount;
{
    NSInteger count = additionalChangeCount;
    if (mutableSlots)
        count += mutableSlots.changeCount;
    return count;
}

- (BOOL)setPassword:(NSString *)password error:(NSError **)outError;
{
    [self _makeMutableSlots:_cmd];
    
    NSMutableDictionary *kminfo = [NSMutableDictionary dictionary];
    
    [kminfo setObject:KeyDerivationMethodPassword forKey:KeyDerivationMethodKey];
    [kminfo setObject:PBKDFAlgPBKDF2_WRAP_AES forKey:PBKDFAlgKey];
    
    /* TODO: Choose a round count dynamically using CCCalibratePBKDF()? The problem is we don't know if we're on one of the user's faster machines or one of their slower machines, nor how much tolerance the user has for slow unlocking on their slower machines. On my current 2.4GHz i7, asking for a 1-second derive time results in a round count of roughly 2560000. */
    dispatch_once_f(&calibrateRoundsOnce, NULL, calibrateRounds);
    
    [kminfo setUnsignedIntValue:calibratedRoundCount forKey:PBKDFRoundsKey];
    
    NSMutableData *salt = [NSMutableData data];
    [salt setLength:saltLength];
    if (!randomBytes([salt mutableBytes], saltLength, outError))
        return NO;
    [kminfo setObject:salt forKey:PBKDFSaltKey];
    
    wk.len = derive(wk.bytes, password, salt, kCCPRFHmacAlgSHA1, calibratedRoundCount, outError);
    if (!wk.len) {
        return NO;
    }
    
    passwordDerivation = kminfo;
    additionalChangeCount ++;
    
    OBPOSTCONDITION(mutableSlots);
    OBPOSTCONDITION(!slots);
    
    return YES;
}

/* We make a mutable copy on write of the slots table when a mutating method is called */
- (void)_makeMutableSlots:(SEL)caller;
{
    if (!mutableSlots) {
        if (!slots)
            OBRejectInvalidCall(self, caller, @"not currently valid");
        mutableSlots = [slots mutableCopy];
        slots = nil;
    }
    
    OBPOSTCONDITION(!slots);
}

/* Convert our slots table back to its immutable form */
- (void)_updateInner;
{
    if (mutableSlots) {
        OBASSERT(!slots);
        
        if (passwordDerivation) {
            passwordDerivation = [passwordDerivation dictionaryWithObject:[mutableSlots wrapWithKey:wk.bytes length:wk.len] forKey:DocumentKeyKey];
        }

        slots = [mutableSlots copy];
        additionalChangeCount += mutableSlots.changeCount;
        mutableSlots = nil;
    }
}

@end


