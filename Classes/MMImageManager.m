//
//  MMImageManager.m
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "MMImageManager.h"
#import "MMImageInflate.h"
#import <CommonCrypto/CommonCrypto.h>
#import <ImageIO/ImageIO.h>
#import <sys/xattr.h>

CGSize const MMImageManagerMaximumSize = { .width = CGFLOAT_MAX, .height = CGFLOAT_MAX };

@interface MMImageManager ()

@property (copy, nonatomic, readwrite) NSString *name;
@property (copy, nonatomic) NSString *workingPath;
@property (assign, nonatomic) CGFloat imageScale;

@property (strong, nonatomic) NSFileManager *fileManager;
@property (strong, nonatomic) dispatch_queue_t queue;

@property (strong, nonatomic) NSCache *cache;
@property (strong, nonatomic) NSMutableDictionary *cacheInfo;

@property (strong, nonatomic) NSMutableArray *pendingImageRequestArray;
@property (strong, nonatomic) NSMutableArray *preheatImageRequestArray;

@property (strong, nonatomic, readwrite) NSSet *registeredImageFormats;

@property (assign, nonatomic) NSTimeInterval automaticCleanupTimeInterval;

@end

@interface _MMImageCacheObjectInfo : NSObject

@property (strong, nonatomic) NSMutableSet *availableImageFormats;
@property (assign, nonatomic, getter=isExpired) BOOL expired;

@end

@implementation _MMImageCacheObjectInfo

- (instancetype)init
{
    self = [super init];
    if (self) {
        _availableImageFormats = [NSMutableSet set];
    }
    return self;
}

@end

@implementation MMImageManager

static NSString *MMImageManagerDomain = @"net.matmartinez.MMImageManager";

- (instancetype)init
{
    return [self initWithName:@"Default"];
}

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (self) {
        NSString *label = [MMImageManagerDomain stringByAppendingPathExtension:name];
        
        _name = [name copy];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        _workingPath = [paths.firstObject stringByAppendingPathComponent:label];
        
        _queue = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
        dispatch_sync(_queue, ^{
            _fileManager = [[NSFileManager alloc] init];
        });
        
        _imageScale = [UIScreen mainScreen].scale;
        
        _cache = [[NSCache alloc] init];
        _cache.name = label;
        
        _cacheInfo = [NSMutableDictionary dictionary];
        _pendingImageRequestArray = [NSMutableArray array];
        _preheatImageRequestArray = [NSMutableArray array];
        
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        
        [notificationCenter addObserver:self
                               selector:@selector(_applicationWillTerminate:)
                                   name:UIApplicationWillTerminateNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(_applicationDidEnterBackground:)
                                   name:UIApplicationDidEnterBackgroundNotification
                                 object:nil];
    }
    return self;
}

#pragma mark - Public API.

- (void)setImageSource:(id<MMImageManagerImageSource>)imageSource
{
    if (imageSource != _imageSource) {
        _imageSource = imageSource;
        
        if ([imageSource respondsToSelector:@selector(imageFormatsForImageManager:)]) {
            NSArray *imageFormats = [imageSource imageFormatsForImageManager:self];
            _registeredImageFormats = [NSSet setWithArray:imageFormats];
            
            if (imageFormats.count != _registeredImageFormats.count) {
                NSLog(@"Warning: Duplicate image format removed. Each provided image format must have an unique name.");
            }
        } else {
            _registeredImageFormats = nil;
        }
        
        for (MMImageRequest *imageRequest in self.pendingImageRequestArray.copy) {
            [self cancelRequestsWithFormat:nil forItem:imageRequest.item];
        }
        
        [self stopCachingImagesForAllItems];
    }
}

- (void)addRequest:(MMImageRequest *)request
{
    if (!request) {
        return;
    }
    
    const CGSize targetSize = request.targetSize;
    id <MMImageManagerItem> item = request.item;
    
    dispatch_async(self.queue, ^{
        MMImageFormat *imageFormat = [self appropiateImageFormatForTargetSize:targetSize];
        NSString *relativePath = [self _relativePathForItem:item imageFormat:imageFormat];
        
        // Hit the cache for the requested item and size.
        UIImage *image = [self.cache objectForKey:relativePath];
        
        _MMImageCacheObjectInfo *info = [self _cacheObjectInfoForItem:item];
        
        // If opportunistic try to hit other sizes.
        BOOL opportunisticCacheReplacement = NO;
        if (!image && request.opportunistic) {
            MMImageFormat *replacementImageFormat = [self _appropiateImageFormatForTargetSize:targetSize imageFormats:info.availableImageFormats];
            if (replacementImageFormat) {
                NSString *otherSizeKey = [self _relativePathForItem:item imageFormat:replacementImageFormat];
                image = [self.cache objectForKey:otherSizeKey];
                
                opportunisticCacheReplacement = YES;
            }
        }
        
        if (image) {
            // Deliver update.
            MMImageRequestResultHandler resultHandler = request.resultHandler;
            if (resultHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    resultHandler(image, nil);
                });
            }
            
            // Don't return if opportunistic or image is expired. We need to do the request.
            if (!opportunisticCacheReplacement && !info.expired) {
                return;
            }
        }
        
        @autoreleasepool {
            NSString *diskRelativePath = relativePath;
            MMImageFormat *diskImageFormat = imageFormat;
            
            // Hit the disk with the required item and size.
            image = [self _createImageFromDataAtRelativePath:relativePath];
            
            // If opportunistic try to hit other sizes.
            BOOL opportunisticDiskReplacement = NO;
            if (!image && request.opportunistic) {
                NSString *containerRelativePath = [self _containerRelativePathForItem:item];
                NSString *containerPath = [self.workingPath stringByAppendingPathComponent:containerRelativePath];
                NSDirectoryEnumerator *containerDirectoryEnumerator = [self.fileManager enumeratorAtURL:[NSURL fileURLWithPath:containerPath] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsSubdirectoryDescendants errorHandler:NULL];
                
                CGFloat closestDiff = INFINITY;
                
                for (NSURL *otherDiskImagePathURL in containerDirectoryEnumerator) {
                    NSString *otherRelativeDiskPath = [NSString pathWithComponents:@[ containerRelativePath, otherDiskImagePathURL.lastPathComponent ]];
                    
                    // Try to match image format name with what we have on record.
                    MMImageFormat *imageFormatWithMatchingName = [self _imageFormatWithName:otherRelativeDiskPath.lastPathComponent];
                    if (imageFormatWithMatchingName) {
                        diskRelativePath = otherRelativeDiskPath;
                        diskImageFormat = imageFormatWithMatchingName;
                        break;
                    }
                    
                    // If nothing was found, try to use closest size image.
                    CGSize size = [self _calculateImageSizeForImageAtRelativePath:otherRelativeDiskPath];
                    if (!CGSizeEqualToSize(size, CGSizeZero)) {
                        CGFloat diff = abs((size.width * size.height) - (targetSize.width * targetSize.height));
                        if (diff < closestDiff) {
                            closestDiff = diff;
                            diskRelativePath = otherRelativeDiskPath;
                        }
                    }
                }
                
                if (![diskRelativePath isEqualToString:relativePath]) {
                    image = [self _createImageFromDataAtRelativePath:diskRelativePath];
                    
                    opportunisticDiskReplacement = YES;
                }
            }
            
            if (image) {
                // Note: Caching will automatically skip if diskImageFormat doesn't exists.
                [self _cacheImage:image imageFormat:diskImageFormat forItem:item relativePath:diskRelativePath];
                
                // Check if this item is now expired. We want to also update the cache info
                // in case the manager is hit with another request for this very expired item.
                BOOL expires = [self _imageExpiredAtRelativePath:relativePath];
                [[self _cacheObjectInfoForItem:item] setExpired:expires];
                
                // Deliver update.
                MMImageRequestResultHandler resultHandler = request.resultHandler;
                if (resultHandler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        resultHandler(image, nil);
                    });
                }
                
                // Don't return if opportunistic or image is expired. We need to do the request.
                if (!opportunisticDiskReplacement && !expires) {
                    return;
                }
            }
        }
        
        // Check if can skip requesting for the same size.
        BOOL alreadyRequesting = NO;
        NSString *imageManagerUniqueIdentifier = [item imageManagerUniqueIdentifier];
        
        for (MMImageRequest *otherImageRequest in self.pendingImageRequestArray) {
            BOOL equalUniqueIdentifier = [[otherImageRequest.item imageManagerUniqueIdentifier] isEqualToString:imageManagerUniqueIdentifier];
            BOOL equalSize = CGSizeEqualToSize(otherImageRequest.targetSize, targetSize);
            
            if (equalUniqueIdentifier && equalSize) {
                alreadyRequesting = YES;
                break;
            }
        }
        
        // Add to pending images.
        [self.pendingImageRequestArray addObject:request];
        
        if (alreadyRequesting) {
            return;
        }
        
        // Image is not existent on disk nor cache, so let's query the image source.
        BOOL imagePromised = [self.imageSource imageManager:self handleRequestWithImageFormat:imageFormat forItem:item];
        
        // If image request is denied, remove object and notify failure.
        if (!imagePromised) {
            [self.pendingImageRequestArray removeObject:request];
            
            MMImageRequestResultHandler resultHandler = request.resultHandler;
            if (resultHandler) {
                NSError *error = [NSError errorWithDomain:MMImageManagerDomain code:NSFeatureUnsupportedError userInfo:nil];
                NSDictionary *errorDictionary = @{ NSUnderlyingErrorKey : error };
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    resultHandler(nil, errorDictionary);
                });
            }
        }
    });
}

- (void)cancelRequest:(MMImageRequest *)request
{
    if (!request) {
        return;
    }
    
    if ([self.pendingImageRequestArray containsObject:request]) {
        [self.pendingImageRequestArray removeObject:request];
        
        MMImageFormat *format = [self appropiateImageFormatForTargetSize:request.targetSize];
        [self.imageSource imageManager:self cancelRequestWithImageFormat:format forItem:request.item];
        
        MMImageRequestResultHandler resultHandler = request.resultHandler;
        if (resultHandler) {
            NSError *error = [NSError errorWithDomain:MMImageManagerDomain code:NSUserCancelledError userInfo:nil];
            NSDictionary *userInfo = @{ NSUnderlyingErrorKey : error };
            
            resultHandler(nil, userInfo);
        }
    }
}

- (void)cancelRequestsWithFormat:(MMImageFormat *)format forItem:(id <MMImageManagerItem>)item
{
    if (!item || ![self.registeredImageFormats containsObject:format]) {
        return;
    }
    
    NSString *uniqueIdentifier = [item imageManagerUniqueIdentifier];
    
    for (MMImageRequest *imageRequest in self.pendingImageRequestArray) {
        MMImageFormat *appropiateFormat = [self appropiateImageFormatForTargetSize:imageRequest.targetSize];
        
        if ([[imageRequest.item imageManagerUniqueIdentifier] isEqualToString:uniqueIdentifier]) {
            BOOL shouldCancel = NO;
            if (!format) {
                shouldCancel = YES;
            } else {
                shouldCancel = [appropiateFormat isEqual:format];
            }
            
            if (shouldCancel) {
                [self cancelRequest:imageRequest];
            }
        }
    }
}

- (MMImageFormat *)appropiateImageFormatForTargetSize:(CGSize)targetSize
{
    return [self _appropiateImageFormatForTargetSize:targetSize imageFormats:self.registeredImageFormats];
}

- (void)saveImage:(UIImage *)image imageFormat:(MMImageFormat *)imageFormat forItem:(id<MMImageManagerItem>)item
{
    if (!image || !item) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        NSString *relativePath = [self _relativePathForItem:item imageFormat:imageFormat];
        
        // Cache the image.
        [self _cacheImage:image imageFormat:imageFormat forItem:item relativePath:relativePath];
        
        // Deliver pending.
        NSMutableArray *matchingRequests = nil;
        NSMutableArray *removedRequests = nil;
        
        NSString *uniqueIdentifier = [item imageManagerUniqueIdentifier];
        
        for (MMImageRequest *imageRequest in self.pendingImageRequestArray) {
            if ([[imageRequest.item imageManagerUniqueIdentifier] isEqualToString:uniqueIdentifier]) {
                BOOL shouldDeliver = NO;
                BOOL shouldRemove = NO;
                
                // If size is the same, deliver.
                MMImageFormat *requestImageFormat = [self appropiateImageFormatForTargetSize:imageRequest.targetSize]; // Cache this?
                if (imageFormat == requestImageFormat) {
                    shouldDeliver = YES;
                    shouldRemove = YES;
                }
                
                // If opportunistic, give it a shot.
                if (!shouldDeliver && imageRequest.opportunistic) {
                    shouldDeliver = YES;
                }
                
                if (shouldDeliver) {
                    if (!matchingRequests) {
                        matchingRequests = [NSMutableArray array];
                    }
                    [matchingRequests addObject:imageRequest];
                }
                
                if (shouldRemove) {
                    if (!removedRequests) {
                        removedRequests = [NSMutableArray array];
                    }
                    [removedRequests addObject:imageRequest];
                }
            }
        }
        
        if (removedRequests.count > 0) {
            [self.pendingImageRequestArray removeObjectsInArray:matchingRequests];
        }
        
        if (matchingRequests.count > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (MMImageRequest *imageRequest in matchingRequests) {
                    MMImageRequestResultHandler resultHandler = imageRequest.resultHandler;
                    if (resultHandler) {
                        resultHandler(image, nil);
                    }
                }
            });
        }
        
        // Write image to disk.
        CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image.CGImage);
        BOOL hasAlpha = !(alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast);
        
        NSData *imageData;
        if (hasAlpha) {
            imageData = UIImagePNGRepresentation(image);
        } else {
            imageData = UIImageJPEGRepresentation(image, 1.0f);
        }
        
        if (imageData) {
            NSString *containerAbsolutePath = [self.workingPath stringByAppendingPathComponent:[self _containerRelativePathForItem:item]];
            NSString *absolutePath = [self.workingPath stringByAppendingPathComponent:relativePath];
            
            if (![self.fileManager fileExistsAtPath:containerAbsolutePath]) {
                [self.fileManager createDirectoryAtPath:containerAbsolutePath withIntermediateDirectories:YES attributes:nil error:NULL];
            }
            
            [self.fileManager createFileAtPath:absolutePath contents:imageData attributes:nil];
        }
    });
}

- (void)removeAllImagesForItem:(id<MMImageManagerItem>)item
{
    dispatch_async(self.queue, ^{
        // Remove container for item.
        NSString *containerPath = [self _containerRelativePathForItem:item];
        
        [self.fileManager removeItemAtPath:containerPath error:nil];
        
        // Remove from cache.
        _MMImageCacheObjectInfo *info = [self _cacheObjectInfoForItem:item];
        
        for (MMImageFormat *imageFormat in info.availableImageFormats) {
            NSString *relativePath = [self _relativePathForItem:item imageFormat:imageFormat];
            [self.cache removeObjectForKey:relativePath];
        }
        
        [self _removeCacheObjectForItem:item];
    });
}

- (void)removeAllImages
{
    dispatch_async(self.queue, ^{
        // Remove working path.
        NSString *workingPath = self.workingPath;
        
        [self.fileManager removeItemAtPath:workingPath error:nil];
        
        // Remove all images from cache.
        [self.cacheInfo removeAllObjects];
        [self.cache removeAllObjects];
    });
}

- (void)beginCachingImagesForItems:(NSArray *)items targetSize:(CGSize)targetSize
{
    if (!items || items.count == 0) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        for (id <MMImageManagerItem> item in items) {
            MMImageRequest *preheatImageRequest = [MMImageRequest requestForItem:item targetSize:targetSize resultHandler:NULL];
            
            [self.preheatImageRequestArray addObject:preheatImageRequest];
            [self addRequest:preheatImageRequest];
        }
    });
}

- (void)stopCachingImagesForItems:(NSArray *)items targetSize:(CGSize)targetSize
{
    if (!items || items.count == 0) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        NSArray *uniqueIdentifiers = [items valueForKey:NSStringFromSelector(@selector(imageManagerUniqueIdentifier))];
        NSMutableIndexSet *indexesToRemove = [NSMutableIndexSet indexSet];
        
        NSUInteger idx = 0;
        for (MMImageRequest *preheatImageRequest in self.preheatImageRequestArray) {
            if ([uniqueIdentifiers containsObject:[preheatImageRequest.item imageManagerUniqueIdentifier]]) {
                if (CGSizeEqualToSize(targetSize, preheatImageRequest.targetSize)) {
                    [self cancelRequest:preheatImageRequest];
                    [indexesToRemove addIndex:idx];
                }
            }
            idx++;
        }
        
        [self.preheatImageRequestArray removeObjectsAtIndexes:indexesToRemove];
    });
}

- (void)stopCachingImagesForAllItems
{
    dispatch_async(self.queue, ^{
        for (MMImageRequest *preheatImageRequest in self.preheatImageRequestArray) {
            [self cancelRequest:preheatImageRequest];
        }
    });
}

#pragma mark - Accesing disk for images.

- (UIImage *)_createImageFromDataAtRelativePath:(NSString *)relativePath
{
    NSString *workingPath = self.workingPath;
    NSString *path = [workingPath stringByAppendingPathComponent:relativePath];
    
    if (![self.fileManager fileExistsAtPath:path]) {
        return nil;
    }
    
    NSData *data = [NSData dataWithContentsOfFile:path];
    UIImage *image = [UIImage MM_inflatedImageWithData:data scale:self.imageScale];
    
    return image;
}

- (CGSize)_calculateImageSizeForImageAtRelativePath:(NSString *)relativePath
{
    NSString *workingPath = self.workingPath;
    NSString *path = [workingPath stringByAppendingPathComponent:relativePath];
    NSURL *imageFileURL = [NSURL fileURLWithPath:path];
    
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((CFURLRef)imageFileURL, NULL);
    if (imageSource == NULL) {
        return CGSizeZero;
    }
    
    CGFloat width = 0.0f, height = 0.0f;
    CFDictionaryRef imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
    if (imageProperties != NULL) {
        CFNumberRef widthNum  = CFDictionaryGetValue(imageProperties, kCGImagePropertyPixelWidth);
        if (widthNum != NULL) {
            CFNumberGetValue(widthNum, kCFNumberCGFloatType, &width);
        }
        
        CFNumberRef heightNum = CFDictionaryGetValue(imageProperties, kCGImagePropertyPixelHeight);
        if (heightNum != NULL) {
            CFNumberGetValue(heightNum, kCFNumberCGFloatType, &height);
        }
        
        CFRelease(imageProperties);
    }
    
    CFRelease(imageSource);
    
    return CGSizeMake(width, height);
}

#pragma mark - Cache entries.

- (void)_cacheImage:(UIImage *)image imageFormat:(MMImageFormat *)imageFormat forItem:(id <MMImageManagerItem>)item relativePath:(NSString *)relativePath
{
    if (!imageFormat) {
        return;
    }
    
    if (!relativePath) {
        relativePath = [self _relativePathForItem:item imageFormat:imageFormat];
    }
    
    CGSize imageSize = image.size;
    CGFloat cost = imageSize.height * imageSize.width * image.scale * image.scale;
    
    [self.cache setObject:image forKey:relativePath cost:cost];
    
    NSString *itemIdentifier = [item imageManagerUniqueIdentifier];
    if (itemIdentifier) {
        _MMImageCacheObjectInfo *cacheItem = [self.cacheInfo objectForKey:itemIdentifier];
        if (!cacheItem) {
            cacheItem = [_MMImageCacheObjectInfo new];
            
            [self.cacheInfo setObject:cacheItem forKey:itemIdentifier];
        }
        
        [cacheItem.availableImageFormats addObject:imageFormat];
        
        // Reset expiration.
        [cacheItem setExpired:NO];
    }
}

- (_MMImageCacheObjectInfo *)_cacheObjectInfoForItem:(id <MMImageManagerItem>)item
{
    NSString *itemIdentifier = [item imageManagerUniqueIdentifier];
    return [self.cacheInfo objectForKey:itemIdentifier];
}

- (void)_removeCacheObjectForItem:(id <MMImageManagerItem>)item
{
    NSString *itemIdentifier = [item imageManagerUniqueIdentifier];
    [self.cacheInfo removeObjectForKey:itemIdentifier];
}

#pragma mark - Accesing image formats.

- (MMImageFormat *)_appropiateImageFormatForTargetSize:(CGSize)targetSize imageFormats:(NSSet *)imageFormats
{
    MMImageFormat *closestImageFormat = nil;
    CGSize closestSize = CGSizeZero;
    CGFloat closestDiff = INFINITY;
    
    BOOL appropiateIsLargestImageFormat = CGSizeEqualToSize(targetSize, MMImageManagerMaximumSize);
    
    for (MMImageFormat *imageFormat in imageFormats) {
        CGSize size = imageFormat.imageSize;
        
        if (appropiateIsLargestImageFormat) {
            if (size.width * size.height > closestSize.width * closestSize.height) {
                closestSize = size;
                closestImageFormat = imageFormat;
            }
        } else {
            CGFloat diff = abs((size.width * size.height) - (targetSize.width * targetSize.height));
            if (diff < closestDiff) {
                closestDiff = diff;
                closestImageFormat = imageFormat;
            }
        }
    }
    return closestImageFormat;
}

- (MMImageFormat *)_imageFormatWithName:(NSString *)name
{
    for (MMImageFormat *imageFormat in self.registeredImageFormats) {
        if ([imageFormat.name isEqualToString:name]) {
            return imageFormat;
        }
    }
    return nil;
}

#pragma mark - Paths.

- (NSString *)_relativePathForItem:(id <MMImageManagerItem>)item imageFormat:(MMImageFormat *)imageFormat
{
    NSString *containerPath = [self _containerRelativePathForItem:item];
    NSString *path = [containerPath stringByAppendingPathComponent:imageFormat.name];
    
    return path;
}

- (NSString *)_containerRelativePathForItem:(id <MMImageManagerItem>)item
{
    NSString *UUID = [item imageManagerUniqueIdentifier];
    const char *str = [UUID UTF8String];
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
    
    return filename;
}

#pragma mark - Clean up.

- (void)_applicationWillTerminate:(NSNotification *)notification
{
    [self _cleanDiskWithCompletionBlock:NULL];
}

- (void)_applicationDidEnterBackground:(NSNotification *)notification
{
    UIApplication *application = [UIApplication sharedApplication];
    
    __block UIBackgroundTaskIdentifier backgroundTaskIdentifier = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:backgroundTaskIdentifier];
        backgroundTaskIdentifier = UIBackgroundTaskInvalid;
    }];
    
    [self _cleanDiskWithCompletionBlock:^{
        [application endBackgroundTask:backgroundTaskIdentifier];
        backgroundTaskIdentifier = UIBackgroundTaskInvalid;
    }];
}

- (void)_cleanDiskWithCompletionBlock:(void (^)(void))completionBlock
{
    dispatch_async(self.queue, ^{
        NSFileManager *fileManager = self.fileManager;
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.workingPath isDirectory:YES];
        NSArray *resourceKeys = @[ NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ];
        
        // This enumerator prefetches useful properties for our cache files.
        NSDirectoryEnumerator *fileEnumerator = [fileManager enumeratorAtURL:diskCacheURL
                                                  includingPropertiesForKeys:resourceKeys
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                errorHandler:NULL];
        
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.automaticCleanupTimeInterval];
        NSMutableDictionary *cacheFiles = [NSMutableDictionary dictionary];
        NSUInteger currentCacheSize = 0;
        
        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        NSMutableArray *urlsToDelete = [NSMutableArray array];
        
        for (NSURL *fileURL in fileEnumerator) {
            NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];
            
            // Skip directories.
            if ([resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }
            
            // Remove files that are older than the expiration date;
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }
            
            // Store a reference to this file and account for its total size.
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += [totalAllocatedSize unsignedIntegerValue];
            [cacheFiles setObject:resourceValues forKey:fileURL];
        }
        
        for (NSURL *fileURL in urlsToDelete) {
            [self.fileManager removeItemAtURL:fileURL error:nil];
        }
        
        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.
        if (self.diskCapacity > 0 && currentCacheSize > self.diskCapacity) {
            // Target half of our maximum cache size for this cleanup pass.
            const NSUInteger desiredCacheSize = self.diskCapacity / 2;
            
            // Sort the remaining cache files by their last modification time (oldest first).
            NSArray *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                            usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                            }];
            
            // Delete files until we fall below our desired cache size.
            for (NSURL *fileURL in sortedFiles) {
                if ([fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= [totalAllocatedSize unsignedIntegerValue];
                    
                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }
        
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

- (NSUInteger)currentDiskUsage
{
    NSArray *resourceKeys = @[ NSURLTotalFileAllocatedSizeKey, NSURLIsDirectoryKey ];
    
    NSURL *workingFileURL = [NSURL fileURLWithPath:self.workingPath isDirectory:YES];
    NSDirectoryEnumerator *directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:workingFileURL includingPropertiesForKeys:resourceKeys options:0 errorHandler:NULL];
    
    NSUInteger currentCacheSize = 0;
    
    for (NSURL *fileURL in directoryEnumerator) {
        NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];
        NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
        
        // Skip directories.
        if ([resourceValues[NSURLIsDirectoryKey] boolValue]) {
            continue;
        }
        
        // Add up the size.
        if (totalAllocatedSize) {
            currentCacheSize += [totalAllocatedSize unsignedIntegerValue];
        }
    }
    
    return currentCacheSize;
}

#pragma mark - Expiration.

static NSString * MMExpirationExtendedAttribute = @"expires";

- (void)removeImageFormat:(MMImageFormat *)format forItem:(id<MMImageManagerItem>)item scheduledWithDate:(NSDate *)date
{
    dispatch_async(self.queue, ^{
        NSString *relativePath = [self _relativePathForItem:item imageFormat:format];
        NSString *path = [self.workingPath stringByAppendingPathComponent:relativePath];
        
        const char *filePath = [path fileSystemRepresentation];
        const char *name = [MMImageManagerDomain stringByAppendingPathExtension:MMExpirationExtendedAttribute].UTF8String;
        const char *value = [NSNumber numberWithInt:[date timeIntervalSince1970]].stringValue.UTF8String;
        
        setxattr(filePath, name, value, strlen(value), 0, 0);
    });
}

- (BOOL)_imageExpiredAtRelativePath:(NSString *)relativePath
{
    NSString *path = [self.workingPath stringByAppendingPathComponent:relativePath];
    NSDate *date = [self _expirationDateForFileAtPath:path];
    
    if (date) {
        return ([[NSDate date] compare:date] == NSOrderedDescending);
    }
    
    return NO;
}

- (NSDate *)_expirationDateForFileAtPath:(NSString *)path
{
    const char *filePath = [path fileSystemRepresentation];
    const char *name = [MMImageManagerDomain stringByAppendingPathExtension:MMExpirationExtendedAttribute].UTF8String;
    
    void *valueBuffer = NULL;
    ssize_t length = getxattr(filePath, name, NULL, SIZE_MAX, 0, 0);
    if (length != -1) {
        valueBuffer = calloc(1, length);
        length = getxattr(filePath, name, valueBuffer, length, 0, 0);
    }
    
    NSString *value = nil;
    if (length == -1) {
        if (valueBuffer) {
            free(valueBuffer);
            valueBuffer = NULL;
        }
    } else {
        value = [[NSString alloc] initWithBytesNoCopy:valueBuffer length:length encoding:NSUTF8StringEncoding freeWhenDone:YES];
    }
    
    if (value) {
        return [NSDate dateWithTimeIntervalSince1970:[value integerValue]];
    }
    return nil;
}

@end
