// Copyright 2016 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// RCS_ID("$Id$")

import Foundation
import Dispatch

/// Encapsulates the encryption settings of a document
@objc public
class OFDocumentEncryptionSettings : NSObject {
    
    /// Decrypts an encrypted document file, if necessary.
    ///
    /// If the file is encrypted, it is unwrapped and a new file wrapper is returned, and information about the encryption settings is stored in `info`. Otherwise the original file wrapper is returned. If the file is encrypted but cannot be decrypted, an error is thrown, but `info` may still be filled in with whatever information is publicly visible on the encryption wrapper.
    ///
    /// - Parameter wrapper: The possibly-encrypted document.
    /// - Parameter info: May be filled in with a new instance of `OFDocumentEncryptionSettings`.
    /// - Parameter keys: Will be used to resolve password/key queries.
    @objc(decryptFileWrapper:info:keys:error:)
    public class func unwrapIfEncrypted(_ wrapper: FileWrapper, info: AutoreleasingUnsafeMutablePointer<OFDocumentEncryptionSettings?>, keys: OFCMSKeySource?) throws -> FileWrapper {
        if (OFCMSFileWrapper.mightBeEncrypted(wrapper)) {
            let helper = OFCMSFileWrapper();
            helper.delegate = keys;
            let unwrapped = try helper.unwrap(input: wrapper);
            info.pointee = OFDocumentEncryptionSettings(from: helper);
            return unwrapped;
        } else {
            info.pointee = nil;
            return wrapper;
        }
    }
    
    /** Tests whether a given filewrapper looks like an encrypted document.
     *
     * May return false positives for other CMS-formatted objects, such as PKCS#7 or PKCS#12 objects, iTunes store receipts, etc.
     */
    @objc(fileWrapperMayBeEncrypted:)
    public class func mayBeEncrypted(wrapper: FileWrapper) -> ObjCBool {
        if (OFCMSFileWrapper.mightBeEncrypted(wrapper)) {
            return true;
        } else {
            return false;
        }
    }
    
    /** Encrypts a file wrapper using the receiver's settings. */
    @objc(encryptFileWrapper:schema:error:)
    public func wrap(_ wrapper: FileWrapper, schema: [String:AnyObject]?) throws -> FileWrapper {
        let helper = OFCMSFileWrapper();
        for recipient in recipients {
            if let pkrecipient = recipient as? CMSPKRecipient,
               let cert = pkrecipient.cert {
                helper.embeddedCertificates.append(SecCertificateCopyData(cert) as Data);
            }
        }
        return try helper.wrap(input: wrapper, previous:nil, schema: schema, recipients: self.recipients, options: self.cmsOptions);
    }
    
    @objc
    public var cmsOptions : OFCMSOptions;
    
    @objc
    public var documentIdentifier : Data?;
    
    internal var recipients : [CMSRecipient];
    internal var unreadableRecipientCount : UInt;
    
    private
    init(from wrapper: OFCMSFileWrapper) {
        cmsOptions = [];
        // TODO: copy stuff from helper into savedSettings
        recipients = wrapper.recipientsFoo;
        unreadableRecipientCount = 0;
        
        var unresolvedPKRecipients = recipients.flatMap { (recip) -> CMSPKRecipient? in
            if let r = recip as? CMSPKRecipient, !r.canWrap() {
                return r;
            } else {
                return nil;
            }
        };
        
        for certData in wrapper.embeddedCertificates {
            if unresolvedPKRecipients.isEmpty {
                break;
            }
            
            guard let cert = SecCertificateCreateWithData(kCFAllocatorDefault, certData as CFData) else {
                continue;
            }
            
            var i = 0;
            while i < unresolvedPKRecipients.count {
                if unresolvedPKRecipients[i].resolve(certificate: cert) {
                    unresolvedPKRecipients.remove(at: i);
                } else {
                    i += 1;
                }
            }
        }
    }
    
    @objc public
    override init() {
        cmsOptions = [];
        recipients = [];
        unreadableRecipientCount = 0;
    }
    
    @objc public
    init(settings other: OFDocumentEncryptionSettings) {
        cmsOptions = other.cmsOptions;
        recipients = other.recipients;
        unreadableRecipientCount = other.unreadableRecipientCount;
    }
    
    /// Removes any existing password recipients, and adds one given a plaintext passphrase.
    // - parameter: The password to set.
    @objc public
    func setPassword(_ password: String) {
        recipients = recipients.filter({ (recip: CMSRecipient) -> Bool in !(recip is CMSPasswordRecipient) });
        recipients.insert(CMSPasswordRecipient(password: password), at: 0);
    }
    
    /// Returns YES if the receiver allows decryption using a password.
    @objc public
    func hasPassword() -> ObjCBool {
        for recip in recipients {
            if recip is CMSPasswordRecipient {
                return true;
            }
        }
        return false;
    }
        
};

internal
class OFCMSFileWrapper {
    
    fileprivate static let indexFileName = "contents.cms";
    fileprivate static let encryptedContentIndexNamespaceURI = "http://www.omnigroup.com/namespace/DocumentEncryption/v1";
    fileprivate static let xLinkNamespaceURI = "http://www.w3.org/1999/xlink";
    
    var recipientsFoo : [CMSRecipient] = [];
    var usedRecipient : CMSRecipient? = nil;
    var embeddedCertificates : [Data] = [];
    public var delegate : OFCMSKeySource? = nil;
    public var auxiliaryAsymmetricKeys : [Keypair] = [];
    
    /** Checks whether an NSFileWrapper looks like an encrypted document we produced. */
    public class func mightBeEncrypted(_ wrapper: FileWrapper) -> Bool {
        
        if wrapper.isRegularFile {
            if let contentData = wrapper.regularFileContents {
                return OFCMSFileWrapper.mightBeCMS(contentData);
            } else {
                return false;
            }
        } else if wrapper.isDirectory {
            if let indexFile = wrapper.fileWrappers?[OFCMSFileWrapper.indexFileName], indexFile.isRegularFile,
               let indexFileContents = indexFile.regularFileContents {
                return OFCMSFileWrapper.mightBeCMS(indexFileContents);
            } else {
                return false;
            }
        } else {
            return false;
        }
    }
    
    /** Checks whether an NSData looks like it could be a CMS message */
    static fileprivate func mightBeCMS(_ data: Data) -> Bool {
        var ct : OFCMSContentType = OFCMSContentType_Unknown;
        let rc = OFASN1ParseCMSContent(data, &ct, nil);
        if rc == 0 && ct != OFCMSContentType_Unknown {
            return true;
        } else {
            return false;
        }
    }
    
    private typealias partWrapSpec = (identifier: Data?, contents: dataSrc, type: OFCMSContentType, options: OFCMSOptions);
    
    /** Encrypts a FileWrapper and returns the encrypted version. */
    func wrap(input: FileWrapper, previous: FileWrapper?, schema: [String: AnyObject]?, recipients: [CMSRecipient], options: OFCMSOptions) throws -> FileWrapper {
        
        var toplevelFileAttributes = input.fileAttributes;
        guard let docID = toplevelFileAttributes.removeValue(forKey: OFDocEncryptionDocumentIdentifierFileAttribute) as? Data? else {
            throw CocoaError(.fileWriteInvalidFileName);
        }
        
        if input.isRegularFile {
            /* For flat files, we can simply encrypt the flat file and write it out. */
            let wrapped = FileWrapper(regularFileWithContents: try self.wrap(data: input.regularFileContents!, recipients: recipients, options: options, outerIdentifier: docID));
            if let fname = input.preferredFilename {
                wrapped.preferredFilename = fname;
            }
            wrapped.fileAttributes = toplevelFileAttributes;
            return wrapped;
        } else if input.isDirectory {
            /* For file packages, we encrypt all the files under random names, and write an index file indicating the real names of each file member. */
            
            let nameCount = input.countRegularFiles();
            let nlen = nameCount < 125 ? 6 : nameCount < 600 ? 8 : 15;
            var ns = Set<String>();
            let sides = CMSKEKRecipient();
            
            var sideFiles : [ (String, FileWrapper, OFCMSOptions) ] = [];
            var insideFiles : [ partWrapSpec ] = [];
            var nextPartNumber = 1;
            
            func wrapWrapperHierarchy(_ w: FileWrapper, settings: [String:AnyObject]?) -> (files: [PackageIndex.FileEntry], directories: [PackageIndex.DirectoryEntry]) {
                guard let items = w.fileWrappers else {
                    return ([], []); // what to do here? when can this happen?
                }
                var files : [PackageIndex.FileEntry] = [];
                var directories : [PackageIndex.DirectoryEntry] = [];
                for (realName, wrapper) in items {
                    let setting = settings?[realName] as! [String : AnyObject]?;
                    if wrapper.isRegularFile {
                        var obscuredName : String;
                        var fileOptions : OFCMSOptions = [];
                        
                        if let specifiedOptions = setting?[OFDocEncryptionFileOptions] {
                            fileOptions.formUnion(specifiedOptions as! OFCMSOptions);
                        }
                        
                        let contentType = (fileOptions.contains(OFCMSOptions.contentIsXML)) ? OFCMSContentType_XML : OFCMSContentType_data;
                        
                        if fileOptions.contains(OFCMSOptions.storeInMain) {
                            
                            let cid = "part\(nextPartNumber)";
                            nextPartNumber += 1;
                            
                            insideFiles.append( (cid.data(using: String.Encoding.ascii)!, dataSrc.fileWrapper(wrapper), contentType, fileOptions) );
                            
                            obscuredName = "#" + cid;
                        } else {
                            
                            if let exposed = setting?[OFDocEncryptionExposeName] {
                                obscuredName = exposed as! String;
                            } else {
                                obscuredName = OFCMSFileWrapper.generateCrypticFilename(ofLength: nlen);
                            }
                            
                            while ns.contains(obscuredName) {
                                obscuredName = OFCMSFileWrapper.generateCrypticFilename(ofLength: nlen);
                            }
                            ns.insert(obscuredName);
                            
                            sideFiles.append( (obscuredName, wrapper, fileOptions) );
                        }
                        
                        files.append(PackageIndex.FileEntry(realName: realName, storedName: obscuredName, options: fileOptions))
                    } else if wrapper.isDirectory {
                        let subSettings : [String : AnyObject]? = setting?[OFDocEncryptionChildren] as! [String : AnyObject]?;
                        let (subFiles, subDirectories) = wrapWrapperHierarchy(wrapper, settings: subSettings);
                        directories.append(PackageIndex.DirectoryEntry(realName: realName, files: subFiles, directories: subDirectories));
                    }
                }
                
                return (files: files, directories: directories);
            }
            
            var packageIndex = PackageIndex();
            packageIndex.keys[sides.keyIdentifier] = sides.kek;
            (packageIndex.files, packageIndex.directories) = wrapWrapperHierarchy(input, settings: schema);
            
            try insideFiles.insert( (nil, dataSrc.data(packageIndex.serialize()), OFCMSContentType_XML, options), at: 0);
            
            let wrappedIndex = try self.wrap(parts: insideFiles,
                                             recipients: recipients,
                                             options: options,
                                             outerIdentifier: nil);
            var resultItems : [String:FileWrapper] = [:];
            resultItems[OFCMSFileWrapper.indexFileName] = FileWrapper(regularFileWithContents: wrappedIndex);
            
            for (obscuredName, wrapper, fileOptions) in sideFiles {
                let wrappedData = try self.wrap(data: wrapper.regularFileContents!, recipients: [sides], options: fileOptions);
                let sideFile = FileWrapper(regularFileWithContents: wrappedData);
                sideFile.preferredFilename = obscuredName;
                resultItems[obscuredName] = sideFile;
            }
            
            let result = FileWrapper(directoryWithFileWrappers: resultItems);
            result.fileAttributes = toplevelFileAttributes;
            return result;
        } else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil /* TODO: Better error for this should-never-happen case? */)
        }
    }
    
    /** Generates a random filename of a given length. */
    private static 
    func generateCrypticFilename(ofLength nlen: Int) -> String {
        var r : UInt32 = 0;
        var cs = Array(repeating: UInt8(0), count: nlen);
        let ch : [UInt8] = [ 0x49, 0x6C, 0x4F, 0x30, 0x31 ];
        for i in 0 ..< nlen {
            if i % 12 == 0 {
                r = OFRandomNext32();
            }
            
            var v : Int;
            if i == 0 || i == (nlen - 1) {
                v = Int(r & 0x01);
                r = r >> 1;
            } else {
                v = Int(r % 5);
                r = r / 5;
            }
            
            cs[i] = ch[v];
        }
        
        return String(bytes: cs, encoding: String.Encoding.ascii)!;
    }
    
    /** Decrypts a FileWrapper and returns the plaintext version */
    func unwrap(input: FileWrapper) throws -> FileWrapper {
        
        if input.isRegularFile {
            guard let encryptedData = input.regularFileContents else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
            }
            let decryptedData = try self.unwrap(data: encryptedData);
            guard let unwrappedData = decryptedData.primaryContent else {
                throw miscFormatError();
            }
            recipientsFoo = decryptedData.allRecipients;
            usedRecipient = decryptedData.usedRecipient;
            embeddedCertificates += decryptedData.embeddedCertificates;
            let unwrapped = FileWrapper(regularFileWithContents: unwrappedData);
            if let fname = input.preferredFilename {
                unwrapped.preferredFilename = fname;
            }
            unwrapped.fileAttributes = input.fileAttributes;
            return unwrapped;
        } else if input.isDirectory {
            
            // Open the main index file and read the index, which should be its primary content.
            
            guard let encryptedFiles = input.fileWrappers else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
            }
            
            guard let indexFile = encryptedFiles[OFCMSFileWrapper.indexFileName],
                  indexFile.isRegularFile,
                  let indexFileContents = indexFile.regularFileContents else {
                throw missingFileError(filename: OFCMSFileWrapper.indexFileName);
            }
            
            let decryptedIndexFile = try self.unwrap(data: indexFileContents);
            recipientsFoo = decryptedIndexFile.allRecipients;
            usedRecipient = decryptedIndexFile.usedRecipient;
            embeddedCertificates += decryptedIndexFile.embeddedCertificates;
            guard let indexData = decryptedIndexFile.primaryContent else {
                throw miscFormatError(reason: "Missing table of contents");
            }
            
            let indexEntries : PackageIndex;
            do {
                indexEntries = try PackageIndex.unserialize(indexData);
            } catch let e as NSError {
                throw miscFormatError(reason: "Malformed table of contents", underlying: e);
            }
            
            // Recreate the structure of directory wrappers. Don't decrypt the leaf files yet, but build a list of which side file contains data which goes into which directory wrapper.
            
            typealias unwrapQueue = Array<(Data?, OFCMSOptions, String, FileWrapper)>;
            
            var leafFiles : [ String : unwrapQueue ] = [:];
            
            func recreateWrapperHierarchy(files: [PackageIndex.FileEntry], directories: [PackageIndex.DirectoryEntry]) -> FileWrapper {
                var resultItems : [String : FileWrapper] = [:];
                for dent in directories {
                    resultItems[dent.realName] = recreateWrapperHierarchy(files: dent.files, directories: dent.directories);
                }
                let directoryWrapper = FileWrapper(directoryWithFileWrappers: resultItems);
                
                for fent in files {
                    let (basename, cid) = fent.splitStoredName();
                    if leafFiles[basename] == nil {
                        leafFiles[basename] = [];
                    }
                    leafFiles[basename]!.append( (cid, fent.options, fent.realName, directoryWrapper) );
                }
                
                return directoryWrapper;
            }
            let resultWrapper = recreateWrapperHierarchy(files: indexEntries.files, directories: indexEntries.directories);
            
            // Now repopulate the file wrapper hierarchy's regular file data.
            
            func readSideFileEntries(sideFileName: String, sideFile: OFCMSFileWrapper.ExpandedContent, entries: unwrapQueue) throws {
                for (cid_, options, realName, dstWrapper) in entries {
                    var fentData : Data?;
                    if let cid = cid_ {
                        // One entry in a multipart file.
                        fentData = sideFile.identifiedContent[cid];
                    } else {
                        // File entry refers to the side file's primary content.
                        fentData = sideFile.primaryContent;
                    }
                    guard let fentDataBang = fentData else {
                        if options.contains(OFCMSOptions.fileIsOptional) {
                            continue;
                        } else {
                            throw missingFileError(filename: "\(sideFileName)#\(cid_)");
                        }
                    }
                    dstWrapper.addRegularFile(withContents: fentDataBang, preferredFilename: realName);
                }
            }
            
            // Any files contained in the main CMS object --- do this first so we can go ahead and deallocate it.
            if let indexFilePackedEntries = leafFiles.removeValue(forKey: "") {
                try readSideFileEntries(sideFileName: "", sideFile: decryptedIndexFile, entries: indexFilePackedEntries);
            }
            // Then any files contained in auxiliary CMS objects. We do it this way so that we only decrypt/decompress a given file once even if it contains multiple contents.
            for (sideFileName, entries) in leafFiles {
                guard let dataFile = encryptedFiles[sideFileName] else {
                    // This file was missing, make sure that's OK.
                    for (_, opts, _, _) in entries {
                        if !opts.contains(OFCMSOptions.fileIsOptional) {
                            throw missingFileError(filename: sideFileName);
                        }
                    }
                    // All the entries in this file were optional, so I guess this is OK.
                    continue;
                }
                
                guard dataFile.isRegularFile,
                      let fileData = dataFile.regularFileContents else {
                        throw missingFileError(filename: sideFileName);
                }
                
                try readSideFileEntries(sideFileName: sideFileName, sideFile: self.unwrap(data: fileData, auxiliaryKeys: indexEntries.keys), entries: entries);
            }
            
            
            // We're done recreating the original wrapper hierarchy and all its content files; return it.
            return resultWrapper;
        } else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
        }
    }
    
    private func compressPart(data input: Data, contentType: OFCMSContentType) throws -> (Data, OFCMSContentType) {
        return (input, contentType);  // TODO
    }
    
    private func wrap(data input_: Data, type type_: OFCMSContentType = OFCMSContentType_Unknown, recipients: [CMSRecipient], options: OFCMSOptions, outerIdentifier: Data? = nil) throws -> Data {
        
        var input = input_;
        var contentType = type_;
        
        if contentType == OFCMSContentType_Unknown {
            contentType = (options.contains(.contentIsXML) ? OFCMSContentType_XML : OFCMSContentType_data);
        }
        
        if options.contains(.compress) {
            (input, contentType) = try compressPart(data: input, contentType: contentType);
        }
        
        let cek = NSData.cryptographicRandomData(ofLength: 32);
        let rinfos = try recipients.map( { (recip) -> Data in try recip.recipientInfo(wrapping: cek) } );
        
        var envelope : Data;
        var envelopeType : OFCMSContentType;
        
        let attributes : [Data]?;
        if let cid = outerIdentifier {
            attributes = [ OFCMSIdentifierAttribute(cid) ];
        } else {
            attributes = nil;
        }
        
        if !options.contains(.withoutAEAD) {
            var error : NSError? = nil;
            guard let enveloped_ = OFCMSCreateAuthenticatedEnvelopedData(cek, rinfos, options, contentType.asDER(), input, attributes, &error) else {
                throw error!;
            }
            envelope = OFNSDataFromDispatchData(enveloped_);
            envelopeType = OFCMSContentType_authenticatedEnvelopedData;
        } else {
            var error : NSError? = nil;
            guard let enveloped_ = OFCMSCreateEnvelopedData(cek, rinfos, contentType.asDER(), input, &error) else {
                throw error!;
            }
            envelope = OFNSDataFromDispatchData(enveloped_);
            envelopeType = OFCMSContentType_envelopedData;
        }
        
        return OFNSDataFromDispatchData(OFCMSWrapContent(envelopeType, envelope));
    }
    
    private func wrap(parts: [partWrapSpec], recipients: [CMSRecipient], options: OFCMSOptions, outerIdentifier: Data?) throws -> Data {

        // If we only have one part, we don't need to use a ContentCollection
        if parts.count == 1 {
            let partContents = try parts[0].contents.get();
            let partOptions = options.union(parts[0].options);
            if let partIdentifier = parts[0].identifier {
                return try wrap(data: OFNSDataFromDispatchData(OFCMSWrapIdentifiedContent(parts[0].type, partContents, partIdentifier)),
                                type: OFCMSContentType_contentWithAttributes,
                                recipients: recipients,
                                options: partOptions,
                                outerIdentifier: outerIdentifier);
            } else {
                return try wrap(data: partContents,
                                type: parts[0].type,
                                recipients: recipients,
                                options: partOptions,
                                outerIdentifier: outerIdentifier);
            }
        }
        
        // If we have multiple parts (or zero, though that's a silly case), put everything in a ContentCollection
        
        let anyUncompressedParts = parts.contains { !$0.options.contains(OFCMSOptions.compress) };
        
        let encodedParts = try parts.map { (part: partWrapSpec) -> Data in
            var partContents = try part.contents.get();
            var partType = part.type;
            if anyUncompressedParts && part.options.contains(OFCMSOptions.compress) {
                (partContents, partType) = try compressPart(data: partContents, contentType: partType);
            }
            if let partIdentifier = part.identifier {
                return OFNSDataFromDispatchData(OFCMSWrapIdentifiedContent(partType, partContents, partIdentifier));
            } else {
                return OFNSDataFromDispatchData(OFCMSWrapContent(partType, partContents));
            }
        };
        
        var outerOptions = options;
        if anyUncompressedParts {
            outerOptions.remove(OFCMSOptions.compress);
        } else {
            outerOptions.insert(OFCMSOptions.compress);
        }
        
        return try wrap(data: OFNSDataFromDispatchData(OFCMSCreateMultipart(encodedParts)), type: OFCMSContentType_contentCollection, recipients: recipients, options: outerOptions, outerIdentifier: outerIdentifier);
    }
    
    /// Represents the results of recursively unpacking one disk file.
    private struct ExpandedContent {
        /// The outermost content-identifier
        // (stored in plaintext and possibly unauthenticated).
        let outerIdentifier: Data?;
        /// Primary (or only, in the common case) content data.
        var primaryContent: Data?;
        /// Other contents, stored by their content-identifiers.
        var identifiedContent: [Data : Data];
        /// Any certificates found while traversing the message.
        var embeddedCertificates: [Data];
        
        /// All CMSRecipients found on the outermost (typically only) envelope.
        let allRecipients: [CMSRecipient];
        /// The recipient we actually used for decryption.
        let usedRecipient: CMSRecipient?;
    }

    private func unwrap(data input_: Data, auxiliaryKeys: [Data: Data] = [:]) throws -> ExpandedContent {
        
        let decr = try OFCMSUnwrapper(data: input_, keySource: delegate);
        
        if !auxiliaryKeys.isEmpty {
            decr.addSymmetricKeys(auxiliaryKeys);
        }
        if !auxiliaryAsymmetricKeys.isEmpty {
            decr.addAsymmetricKeys(auxiliaryAsymmetricKeys);
        }
        
        try decr.peelMeLikeAnOnion();
        var result = ExpandedContent(outerIdentifier: decr.contentIdentifier,
                                     primaryContent: nil,
                                     identifiedContent: [:],
                                     embeddedCertificates: decr.embeddedCertificates,
                                     allRecipients: decr.allRecipients,
                                     usedRecipient: decr.usedRecipient);

        switch decr.contentType {
        case OFCMSContentType_data, OFCMSContentType_XML:
            result.primaryContent = try decr.content();
            
        case OFCMSContentType_contentCollection:
            var parts = try decr.splitParts().makeIterator();
            while true {
                guard let part = parts.next() else {
                    break;
                }
                
                let outermostType = part.contentType;
                try part.peelMeLikeAnOnion();
                result.embeddedCertificates += part.embeddedCertificates;
                if part.hasNullContent && outermostType == OFCMSContentType_signedData {
                    // It's OK for this to have null content --- it's how PKCS#7 objects contain certificate lists.
                    continue;
                }
                
                switch part.contentType {
                case OFCMSContentType_contentCollection:
                    var subParts = try part.splitParts();
                    subParts.append(contentsOf: parts);
                    parts = subParts.makeIterator();

                case OFCMSContentType_data, OFCMSContentType_XML:
                    let partContents = try part.content();
                    if let identifier = part.contentIdentifier {
                        result.identifiedContent[identifier] = partContents;
                    } else if result.primaryContent == nil {
                        result.primaryContent = partContents;
                    }
                    // We're dropping any identifier-less content other than the first on the floor.
                    
                default:
                    if result.primaryContent == nil && part.contentIdentifier == nil {
                        // This could be the primary content, if we knew what it was. Throw an error.
                        throw unexpectedContentTypeError(part.contentType);
                    }
                    // Else, ignore it. If it's referenced by something, we'll get the appropriate error when we try to find it.
                }
            }
            
        default:
            throw unexpectedContentTypeError(decr.contentType);
        }
        
        return result;
    }
    
    private func unexpectedContentTypeError(_ ct: OFCMSContentType) -> NSError {
        return NSError(domain: OFErrorDomain,
                       code: OFUnsupportedCMSFeature,
                       userInfo: [NSLocalizedFailureReasonErrorKey: NSLocalizedString("Unexpected content-type", tableName: "OmniFoundation", bundle: OFBundle, comment: "Document decryption error - unexpected CMS content-type found while unwrapping")]);
    }
    
    private struct PackageIndex {
        
        struct FileEntry {
            let realName: String;
            let storedName: String;
            let options: OFCMSOptions;
            
            func serialize(into elt: OFXMLMakerElement) {
                let felt = elt.openElement("file")
                              .addAttribute("name", value: realName)
                              .addAttribute("href", xmlns: xLinkNamespaceURI, value: storedName);
                if options.contains(OFCMSOptions.fileIsOptional) {
                    felt.addAttribute("optional", value: "1");
                }
                felt.close();
            }
            
            func splitStoredName() -> (String, Data?) {
                if let sep = storedName.range(of: "#") {
                    return ( storedName.substring(to: sep.lowerBound),
                             storedName.substring(from: sep.upperBound).data(using: String.Encoding.ascii) );
                } else {
                    return (storedName, nil);
                }
            }
        }
        
        struct DirectoryEntry {
            let realName: String;
            let files : [FileEntry];
            let directories : [DirectoryEntry];
            
            func serialize(into elt: OFXMLMakerElement) {
                let dirElt = elt.openElement("directory").addAttribute("name", value: realName);
                for fileEntry in files {
                    fileEntry.serialize(into: dirElt);
                }
                for subDirectory in directories {
                    subDirectory.serialize(into: dirElt);
                }
                dirElt.close();
            }
        }
        
        var files : [FileEntry] = [];
        var keys : [Data : Data] = [:];
        var directories : [DirectoryEntry] = [];
        
        func serialize() throws -> Data {
            let strm = OutputStream(toMemory: ());
            let sink = OFXMLTextWriterSink(stream: strm)!;
            let doc = sink.openElement("index", xmlns: encryptedContentIndexNamespaceURI, defaultNamespace: encryptedContentIndexNamespaceURI);
            doc.prefix(forNamespace:xLinkNamespaceURI, hint: "xl");
            
            for (keyIdentifier, keyMaterial) in self.keys {
                doc.openElement("key")
                    .addAttribute("id", value: (keyIdentifier as NSData).unadornedLowercaseHexString())
                    .add(string: (keyMaterial as NSData).unadornedLowercaseHexString())
                    .close();
            }
            
            for d in self.directories {
                d.serialize(into: doc);
            }
            
            for entry in self.files {
                entry.serialize(into: doc);
            }
            
            doc.close();
            sink.close();
            
            if let bufferError = strm.streamError {
                throw bufferError;
            }
            
            let v = strm.property(forKey: Stream.PropertyKey.dataWrittenToMemoryStreamKey);
            
            return (v as? Data) ?? Data();  // RADAR 6160521
        }
        
        static func unserialize(_ input: Data) throws -> PackageIndex {
            let reader = try OFXMLReader(data: input);
            guard let rtelt = reader.elementQName() else {
                throw NSError(domain: OFErrorDomain, code: OFXMLDocumentNoRootElementError, userInfo: nil);
            }
            guard rtelt.name == "index", rtelt.namespace == encryptedContentIndexNamespaceURI else {
                throw miscFormatError(reason: "Incorrect root element: \(rtelt.shortDescription()!)");
            }
            
            var files : [PackageIndex.FileEntry] = [];
            var keys : [Data:Data] = [:];
            var directories : [DirectoryEntry] = [];
            
            let fileNameAttr = OFXMLQName(namespace: nil, name: "name")!;
            let fileLocationAttr = OFXMLQName(namespace: xLinkNamespaceURI, name: "href")!;
            let fileOptionalAttr = OFXMLQName(namespace: nil, name: "optional")!;
            let keyIdAttr = OFXMLQName(namespace: nil, name: "id")!;
            
            try reader.openElement();
            var currentElementName = reader.elementQName();
            var directoryStack : [DirectoryEntry] = [];
            
            while true {
                try reader.findNextElement(&currentElementName);
                guard let elementName = currentElementName else {
                    // Nil indicates end of enclosing element. In theory the only elements we should be entering are the toplevel element and any <directory/> elements.
                    if let dent = directoryStack.popLast() {
                        // We abuse the DirectoryEntry type slightly here: its name field contains the name of the dierctory we were just scanning, but its other fields are the saved state from its own containing directry.
                        let newSubdirectory = DirectoryEntry(realName: dent.realName, files: files, directories: directories);
                        files = dent.files;
                        directories = dent.directories;
                        directories.append(newSubdirectory);
                        try reader.closeElement();
                        continue;
                    } else {
                        // Done with the index.
                        break;
                    }
                }
                
                if elementName.name == "file" && elementName.namespace == encryptedContentIndexNamespaceURI {
                    guard let memberName = try reader.getAttributeValue(fileNameAttr),
                          let memberLocation = try reader.getAttributeValue(fileLocationAttr) else {
                            throw NSError(domain: OFErrorDomain, code: OFEncryptedDocumentFormatError, userInfo: [
                                NSLocalizedFailureReasonErrorKey: "Missing <file> attribute"
                                ]);
                    }
                    var memberOptions : OFCMSOptions = [];
                    if let optionality = try reader.getAttributeValue(fileOptionalAttr), (optionality as NSString).boolValue {
                        memberOptions.formUnion(OFCMSOptions.fileIsOptional);
                    }
                    files.append(PackageIndex.FileEntry(realName: memberName, storedName: memberLocation, options: memberOptions));
                    try reader.skipCurrentElement();
                } else if elementName.name == "key" && elementName.namespace == encryptedContentIndexNamespaceURI {
                    guard let keyName = try reader.getAttributeValue(keyIdAttr) else {
                        throw NSError(domain: OFErrorDomain, code: OFEncryptedDocumentFormatError, userInfo: [
                            NSLocalizedFailureReasonErrorKey: "Missing <key> attribute"
                        ]);
                    }
                    do {
                        try reader.openElement();
                        var keyValue = nil as NSString?;
                        try reader.copyStringContents(toEndOfElement: &keyValue);
                        let keyValueData = try NSData(hexString: keyValue! as String);

                        keys[ try NSData(hexString:keyName) as Data ] = keyValueData as Data;
                    } catch let e as NSError {
                        throw NSError(domain: OFErrorDomain, code: OFEncryptedDocumentFormatError, userInfo: [NSUnderlyingErrorKey: e]);
                    }
                } else if elementName.name == "directory" && elementName.namespace == encryptedContentIndexNamespaceURI {
                    guard let dirName = try reader.getAttributeValue(fileNameAttr) else {
                        throw NSError(domain: OFErrorDomain, code: OFEncryptedDocumentFormatError, userInfo: [
                            NSLocalizedFailureReasonErrorKey: "Missing <directory> attribute"
                            ]);
                    }
                    
                    directoryStack.append(DirectoryEntry(realName: dirName, files: files, directories: directories));
                    files = [];
                    directories = [];
                    try reader.openElement();
                } else {
                    // Ignore unknown tags.
                    try reader.skipCurrentElement();
                }
            }
            
            return PackageIndex(files: files, keys: keys, directories: directories);
        }
    }
}

private
func missingFileError(filename: String) -> NSError {
    let msg = NSString(format: NSLocalizedString("The encrypted item \"%@\" is missing or unreadable.", tableName: "OmniFoundation", bundle: OFBundle, comment: "Document decryption error message - a file within the encrypted file wrapper can't be read") as NSString,
                       filename) as String;
    return miscFormatError(reason: msg);
}

private
func miscFormatError(reason: String? = nil, underlying: NSError? = nil) -> NSError {
    var userInfo: [String: AnyObject] = [:];
    
    if let underlyingError = underlying {
        if underlyingError.domain == OFErrorDomain && underlyingError.code == OFEncryptedDocumentFormatError && reason == nil {
            return underlyingError;
        }
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    
    if let message_ = reason {
        userInfo[NSLocalizedFailureReasonErrorKey] = message_ as NSString;
    }
    
    return NSError(domain: OFErrorDomain, code: OFEncryptedDocumentFormatError, userInfo: userInfo.isEmpty ? nil : userInfo);
}



private extension OFXMLReader {
    /// Swifty cover on -copyValueOfAttribute:named:error:
    func getAttributeValue(_ qualifiedName: OFXMLQName) throws -> String? {
        var attributeValue : NSString?;
        attributeValue = nil;
        try self.copyValue(ofAttribute: &attributeValue, named: qualifiedName);
        return attributeValue as String?;
    }
}

/// A tiny Either class containing either raw Data or a (potentially lazily-mapped) NSFileWrapper
fileprivate enum dataSrc {
    case data(_: Data);
    case fileWrapper(_: FileWrapper);
    
    func get() throws -> Data {
        switch self {
        case .data(let d):
            return d;
        case .fileWrapper(let w):
            guard let contents = w.regularFileContents else {
                throw CocoaError(.fileReadUnknown);
            }
            return contents;
        }
    }
}

private extension FileWrapper {
    
    /// Count the number of regular files in a file wrapper hierarchy
    func countRegularFiles() -> UInt {
        
        if self.isRegularFile {
            return 1;
        }
        
        var nameCount : UInt = 0;
        var wrappersToCount : [FileWrapper] = [self];
        
        repeat {
            if let entries = wrappersToCount.popLast()?.fileWrappers {
                for (_, w) in entries {
                    if w.isRegularFile {
                        nameCount += 1;
                    } else if w.isDirectory {
                        wrappersToCount.append(w);
                    }
                }
            }
        } while !wrappersToCount.isEmpty;
        
        return nameCount;
    }
}
