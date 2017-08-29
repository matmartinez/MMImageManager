//
//  MMImageManager.m
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "MMImageManager.h"
#import "MMImageInflate.h"
#import "MMImageResize.h"
#import <CommonCrypto/CommonCrypto.h>
#import <ImageIO/ImageIO.h>
#import <sys/xattr.h>

CGSize const MMImageManagerMaximumSize = { .width = CGFLOAT_MAX, .height = CGFLOAT_MAX };

@interface MMImageManager ()

@property (copy, nonatomic, readwrite) NSString *name;
@property (copy, nonatomic) NSString *workingPath;
@property (copy, nonatomic) MMImageManagerOptions *options;

@property (strong, nonatomic) NSFileManager *fileManager;
@property (strong, nonatomic) dispatch_queue_t queue;

@property (strong, nonatomic) NSCache *cache;
@property (strong, nonatomic) NSMutableDictionary *cacheInfo;

@property (strong, nonatomic) NSCache *contextCache;

@property (strong, nonatomic) NSMutableArray *pendingImageRequestArray;
@property (strong, nonatomic) NSMutableArray *preheatImageRequestArray;

@property (strong, nonatomic, readwrite) NSSet *registeredImageFormats;

@end

@interface _MMImageCacheObjectInfo : NSObject

@property (strong, nonatomic) NSMutableSet *availableImageFormats;
@property (assign, nonatomic, getter=isExpired) BOOL expired;

@end

@interface _MMDrawingContext : NSObject

- (instancetype)initWithSize:(CGSize)size scale:(CGFloat)scale opaque:(BOOL)opaque NS_DESIGNATED_INITIALIZER;

@property (weak, nonatomic) dispatch_queue_t queue;
@property (readonly, nonatomic) CGContextRef context;

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

@implementation _MMDrawingContext

NS_INLINE CGContextRef MMCreateGraphicsContext(CGSize size, BOOL opaque) {
    size_t width = size.width;
    size_t height = size.height;
    size_t bitsPerComponent = 8;
    size_t bytesPerRow = 4 * width;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host | (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst);
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, bitsPerComponent, bytesPerRow, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    return ctx;
}

- (instancetype)init
{
    return [self initWithSize:CGSizeZero scale:1.0f opaque:YES];
}

- (instancetype)initWithSize:(CGSize)imageSize scale:(CGFloat)scale opaque:(BOOL)opaque
{
    if (CGSizeEqualToSize(imageSize, CGSizeZero)) {
        return nil;
    }
    
    self = [super init];
    if (self) {
        CGSize size = imageSize;
        size.width *= scale;
        size.height *= scale;
        
        if (size.width < 1) size.width = 1;
        if (size.height < 1) size.height = 1;
        
        CGContextRef ctx = MMCreateGraphicsContext(size, opaque);
        
        CGContextScaleCTM(ctx, scale, scale);
        CGContextTranslateCTM(ctx, 0, imageSize.height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        
        _context = ctx;
    }
    return self;
}

- (void)dealloc
{
    CGContextRef ctx = _context;
    if (ctx != NULL) {
        dispatch_queue_t queque = _queue;
        if (queque != nil) {
            dispatch_async(queque, ^{
                CGContextRelease(ctx);
            });
        } else {
            CGContextRelease(ctx);
        }
    }
    _context = nil;
}

@end

@implementation MMImageManager

static NSString *MMImageManagerDomain = @"net.matmartinez.MMImageManager";

NS_INLINE BOOL MMUIImageContainsAlpha(UIImage *image){
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image.CGImage);
    BOOL hasAlpha = !(alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast);
    
    return hasAlpha;
};

- (instancetype)init
{
    return [self initWithName:@"Default" options:[MMImageManagerOptions defaultOptions]];
}

- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name options:[MMImageManagerOptions defaultOptions]];
}

- (instancetype)initWithName:(NSString *)name options:(MMImageManagerOptions *)options
{
    self = [super init];
    if (self) {
        NSString *label = [MMImageManagerDomain stringByAppendingPathExtension:name];
        _name = [name copy];
        _options = [options copy];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        _workingPath = [paths.firstObject stringByAppendingPathComponent:label];
        
        _queue = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
        dispatch_sync(_queue, ^{
            _fileManager = [[NSFileManager alloc] init];
        });
        
        _cache = [[NSCache alloc] init];
        _cache.name = label;
        
        _contextCache = [[NSCache alloc] init];
        _contextCache.name = [label stringByAppendingPathExtension:@"Drawing"];
        _contextCache.countLimit = 10;
        
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
        @autoreleasepool {
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
                [self _finishImageRequest:request withImage:image error:nil];
                
                // Don't return if opportunistic or image is expired. We need to do the request.
                if (!opportunisticCacheReplacement && !info.expired) {
                    return;
                }
            }
            
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
                        CGFloat diff = fabs((size.width * size.height) - (targetSize.width * targetSize.height));
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
                [self _finishImageRequest:request withImage:image error:nil];
                
                // Don't return if opportunistic or image is expired. We need to do the request.
                if (!opportunisticDiskReplacement && !expires) {
                    return;
                }
            }
            
            // Return early if network is not allowed.
            if (!request.networkAccessAllowed) {
                NSError *error = [NSError errorWithDomain:MMImageManagerDomain code:NSExecutableNotLoadableError userInfo:nil];
                [self _finishImageRequest:request withImage:image error:error];
                return;
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
                
                NSError *error = [NSError errorWithDomain:MMImageManagerDomain code:NSFeatureUnsupportedError userInfo:nil];
                [self _finishImageRequest:request withImage:nil error:error];
            }
        }
    });
}

- (void)cancelRequest:(MMImageRequest *)request
{
    if (!request) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            if ([self.pendingImageRequestArray containsObject:request]) {
                [self.pendingImageRequestArray removeObject:request];
                
                MMImageFormat *format = [self appropiateImageFormatForTargetSize:request.targetSize];
                [self.imageSource imageManager:self cancelRequestWithImageFormat:format forItem:request.item];
                
                NSError *error = [NSError errorWithDomain:MMImageManagerDomain code:NSUserCancelledError userInfo:nil];
                [self _finishImageRequest:request withImage:nil error:error];
            }
        };
    });
}

- (void)cancelRequestsWithFormat:(MMImageFormat *)format forItem:(id <MMImageManagerItem>)item
{
    if (!item || ![self.registeredImageFormats containsObject:format]) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        @autoreleasepool {
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
    });
}

- (MMImageFormat *)appropiateImageFormatForTargetSize:(CGSize)targetSize
{
    return [self _appropiateImageFormatForTargetSize:targetSize imageFormats:self.registeredImageFormats];
}

- (void)saveImage:(UIImage *)original imageFormat:(MMImageFormat *)imageFormat forItem:(id<MMImageManagerItem>)item
{
    if (!original || !item) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            UIImage *image = original;
            
            // Resize if needed.
            if (self.options.resizesImagesToTargetSize) {
                const CGSize imageSize = imageFormat.imageSize;
                const BOOL needsResizing = !CGSizeEqualToSize(imageSize, CGSizeZero) && !CGSizeEqualToSize(imageSize, MMImageManagerMaximumSize);
                
                if (needsResizing) {
                    image = [image MM_imageConstrainedToSize:imageSize];
                }
            }
            
            // Create relative path.
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
                [self _batchFinishImageRequests:matchingRequests withImage:image error:nil];
            }
            
            // Write image to disk.
            NSData *imageData;
            if (MMUIImageContainsAlpha(image)) {
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
        }
    });
}

- (void)removeAllImagesForItem:(id<MMImageManagerItem>)item
{
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            // Remove container for item.
            NSString *containerPath = [self _containerRelativePathForItem:item];
            
            [self.fileManager removeItemAtPath:containerPath error:nil];
            
            // Remove from cache.
            _MMImageCacheObjectInfo *info = [self _cacheObjectInfoForItem:item];
            
            for (MMImageFormat *imageFormat in info.availableImageFormats.copy) {
                NSString *relativePath = [self _relativePathForItem:item imageFormat:imageFormat];
                
                if (relativePath) {
                    [self.cache removeObjectForKey:relativePath];
                }
            }
            
            [self _removeCacheObjectForItem:item];
        }
    });
}

- (void)removeAllImages
{
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            // Remove working path.
            NSString *workingPath = self.workingPath;
            
            [self.fileManager removeItemAtPath:workingPath error:nil];
            
            // Remove all images from cache.
            [self.cacheInfo removeAllObjects];
            [self.cache removeAllObjects];
            
            // Clear the context cache.
            [self.contextCache removeAllObjects];
        }
    });
}

- (void)beginCachingImagesForItems:(NSArray *)items targetSize:(CGSize)targetSize
{
    if (!items || items.count == 0) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            for (id <MMImageManagerItem> item in items) {
                MMImageRequest *preheatImageRequest = [MMImageRequest requestForItem:item targetSize:targetSize resultHandler:NULL];
                
                [self.preheatImageRequestArray addObject:preheatImageRequest];
                [self addRequest:preheatImageRequest];
            }
        }
    });
}

- (void)stopCachingImagesForItems:(NSArray *)items targetSize:(CGSize)targetSize
{
    if (!items || items.count == 0) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        @autoreleasepool {
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
        }
    });
}

- (void)stopCachingImagesForAllItems
{
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            for (MMImageRequest *preheatImageRequest in self.preheatImageRequestArray) {
                [self cancelRequest:preheatImageRequest];
            }
        }
    });
}

#pragma mark - Finishing requests.

- (void)_finishImageRequest:(MMImageRequest *)imageRequest withImage:(UIImage *)image error:(NSError *)error
{
    BOOL usingImageContext = NO;
    
    if (image && imageRequest.drawRect) {
        CGContextRef ctx = [self _graphicsContextForImage:image];
        if (ctx != NULL) {
            UIGraphicsPushContext(ctx);
            usingImageContext = YES;
        }
    }
    
    dispatch_block_t handler = [self _handlerForImageRequest:imageRequest image:image error:error];
    
    if (usingImageContext) {
        UIGraphicsPopContext();
    }
    
    if (handler) {
        dispatch_queue_t resultQueue = imageRequest.resultQueue;
        dispatch_async(resultQueue ?: dispatch_get_main_queue(), handler);
    }
}

- (dispatch_block_t)_handlerForImageRequest:(MMImageRequest *)imageRequest image:(UIImage *)image error:(NSError *)error
{
    MMImageRequestResultHandler resultHandler = imageRequest.resultHandler;
    if (!resultHandler) {
        return nil;
    }
    
    NSDictionary *userInfo = nil;
    if (error) {
        userInfo = @{ NSUnderlyingErrorKey : error };
    }
    
    const BOOL clearsContextBeforeDrawing = imageRequest.clearsContextBeforeDrawing;
    const MMImageDrawRect drawRect = imageRequest.drawRect;
    
    if (image && drawRect) {
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        
        CGRect r = (CGRect){ .size = image.size };
        
        if (clearsContextBeforeDrawing) {
            CGContextClearRect(ctx, r);
        }
        
        drawRect(image, r);
        
        CGImageRef contextImage = CGBitmapContextCreateImage(ctx);
        if (contextImage != NULL) {
            image = [UIImage imageWithCGImage:contextImage];
            
            CGImageRelease(contextImage);
        }
    }
    
    return ^{
        resultHandler(image, userInfo);
    };
}

- (void)_batchFinishImageRequests:(NSArray *)batch withImage:(UIImage *)image error:(NSError *)error
{
    NSMutableArray *handlers = [NSMutableArray arrayWithCapacity:batch.count];
    BOOL usingImageContext = NO;
    for (MMImageRequest *imageRequest in batch) {
        if (image && imageRequest.drawRect) {
            CGContextRef ctx = [self _graphicsContextForImage:image];
            if (ctx != NULL) {
                UIGraphicsPushContext(ctx);
                usingImageContext = YES;
            }
        }
        
        dispatch_block_t handler = [self _handlerForImageRequest:imageRequest image:image error:error];
        if (handler) {
            [handlers addObject:handler];
        }
    }
    
    if (usingImageContext) {
        UIGraphicsPopContext();
    }
    
    if (handlers.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (dispatch_block_t handler in handlers) {
                handler();
            }
        });
    }
}

- (CGContextRef)_graphicsContextForImage:(UIImage *)image
{
    const BOOL opaque = !MMUIImageContainsAlpha(image);
    const CGFloat scale = image.scale;
    const CGSize size = image.size;
    
    NSString *contextIdentifier = [NSString stringWithFormat:@"%f.%f.%f.%d", size.width, size.height, scale, opaque];
    _MMDrawingContext *context = [_contextCache objectForKey:contextIdentifier];
    if (!context) {
        context = [[_MMDrawingContext alloc] initWithSize:size scale:scale opaque:opaque];
        context.queue = self.queue;
        
        [_contextCache setObject:context forKey:contextIdentifier cost:size.width * size.height];
    }
    
    return context.context;
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
    UIImage *image = [UIImage MM_inflatedImageWithData:data scale:self.options.imageScale];
    
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
            CGFloat diff = fabs((size.width * size.height) - (targetSize.width * targetSize.height));
            if (diff < closestDiff) {
                closestDiff = diff;
                closestImageFormat = imageFormat;
            }
        }
    }
    
    return closestImageFormat ?: imageFormats.anyObject;
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
    NSDate *expirationDate = self.options.expirationDate;
    if (!expirationDate) {
        return;
    }
    
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            NSFileManager *fileManager = self.fileManager;
            NSURL *diskCacheURL = [NSURL fileURLWithPath:self.workingPath isDirectory:YES];
            NSArray *resourceKeys = @[ NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ];
            
            // This enumerator prefetches useful properties for our cache files.
            NSDirectoryEnumerator *fileEnumerator = [fileManager enumeratorAtURL:diskCacheURL
                                                      includingPropertiesForKeys:resourceKeys
                                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                    errorHandler:NULL];
            
            NSMutableDictionary *cacheFiles = [NSMutableDictionary dictionary];
            NSUInteger currentCacheSize = 0;
            
            // Enumerate all of the files in the cache directory.  This loop has two purposes:
            //
            //  1. Removing files that are older than the expiration date.
            //  2. Storing file attributes for the size-based cleanup pass.
            NSMutableArray *urlsToDelete = [NSMutableArray array];
            
            for (NSURL *fileURL in fileEnumerator) {
                NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];
                
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
            NSUInteger diskCapacity = self.options.diskCapacity;
            if (diskCapacity > 0 && currentCacheSize > diskCapacity) {
                // Target half of our maximum cache size for this cleanup pass.
                const NSUInteger desiredCacheSize = diskCapacity / 2;
                
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
        }
    });
}

- (NSUInteger)currentDiskUsage
{
    NSArray *resourceKeys = @[ NSURLTotalFileAllocatedSizeKey ];
    
    NSURL *workingFileURL = [NSURL fileURLWithPath:self.workingPath isDirectory:YES];
    NSDirectoryEnumerator *directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:workingFileURL includingPropertiesForKeys:resourceKeys options:0 errorHandler:NULL];
    
    NSUInteger currentCacheSize = 0;
    
    for (NSURL *fileURL in directoryEnumerator) {
        NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];
        NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
        
        // Add up the size.
        if (totalAllocatedSize) {
            currentCacheSize += [totalAllocatedSize unsignedIntegerValue];
        }
    }
    
    return currentCacheSize;
}

- (void)removeImagesSinceDate:(NSDate *)date
{
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            NSFileManager *fileManager = self.fileManager;
            NSURL *diskCacheURL = [NSURL fileURLWithPath:self.workingPath isDirectory:YES];
            NSArray *resourceKeys = @[ NSURLContentModificationDateKey ];
            
            // This enumerator prefetches useful properties for our cache files.
            NSDirectoryEnumerator *fileEnumerator = [fileManager enumeratorAtURL:diskCacheURL
                                                      includingPropertiesForKeys:resourceKeys
                                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                    errorHandler:NULL];
            
            NSMutableArray *URLsToDelete = [NSMutableArray array];
            
            for (NSURL *fileURL in fileEnumerator) {
                NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];
                
                // Check date.
                NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
                
                if ([modificationDate compare:date] == NSOrderedDescending) {
                    [URLsToDelete addObject:fileURL];
                }
            }
            
            for (NSURL *fileURL in URLsToDelete) {
                [fileManager removeItemAtURL:fileURL error:nil];
            }
        }
    });
}

#pragma mark - Expiration.

static NSString * MMExpirationExtendedAttribute = @"expires";

- (void)removeImageFormat:(MMImageFormat *)format forItem:(id<MMImageManagerItem>)item scheduledWithDate:(NSDate *)date
{
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            NSString *relativePath = [self _relativePathForItem:item imageFormat:format];
            NSString *path = [self.workingPath stringByAppendingPathComponent:relativePath];
            
            const char *filePath = [path fileSystemRepresentation];
            const char *name = [MMImageManagerDomain stringByAppendingPathExtension:MMExpirationExtendedAttribute].UTF8String;
            const char *value = [NSNumber numberWithInt:[date timeIntervalSince1970]].stringValue.UTF8String;
            
            setxattr(filePath, name, value, strlen(value), 0, 0);
        }
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
