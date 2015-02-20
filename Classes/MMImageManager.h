//
//  MMImageManager.h
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "MMImageManagerItem.h"
#import "MMImageRequest.h"
#import "MMImageFormat.h"

@class MMImageRequest;
@class MMImageManager;
@class MMImageFormat;

extern CGSize const MMImageManagerMaximumSize;

@protocol MMImageManagerImageSource <NSObject>

@required
- (BOOL)imageManager:(MMImageManager *)imageManager handleRequestWithImageFormat:(MMImageFormat *)imageFormat forItem:(id <MMImageManagerItem>)item;

- (void)imageManager:(MMImageManager *)imageManager cancelRequestWithImageFormat:(MMImageFormat *)format forItem:(id <MMImageManagerItem>)item;

@optional
- (NSArray *)imageFormatsForImageManager:(MMImageManager *)imageManager;

@end

@interface MMImageManager : NSObject

- (instancetype)initWithName:(NSString *)name;

@property (readonly, copy, nonatomic) NSString *name;

@property (weak, nonatomic) id <MMImageManagerImageSource> imageSource;

- (void)addRequest:(MMImageRequest *)request;
- (void)cancelRequest:(MMImageRequest *)request;
- (void)cancelRequestsWithFormat:(MMImageFormat *)format forItem:(id <MMImageManagerItem>)item;

- (MMImageFormat *)appropiateImageFormatForTargetSize:(CGSize)size;

- (void)beginCachingImagesForItems:(NSArray *)items targetSize:(CGSize)targetSize;
- (void)stopCachingImagesForItems:(NSArray *)items targetSize:(CGSize)targetSize;
- (void)stopCachingImagesForAllItems;

- (void)saveImage:(UIImage *)image imageFormat:(MMImageFormat *)imageFormat forItem:(id <MMImageManagerItem>)item;
- (void)removeAllImagesForItem:(id <MMImageManagerItem>)item;
- (void)removeAllImages;

@property (assign, nonatomic) NSUInteger diskCapacity;
@property (readonly, nonatomic) NSUInteger currentDiskUsage;

@end

@interface MMImageManager (CacheControl)

@property (assign, nonatomic) NSTimeInterval automaticCleanupTimeInterval;

- (void)removeImageFormat:(MMImageFormat *)format forItem:(id <MMImageManagerItem>)item scheduledWithDate:(NSDate *)date;
- (void)removeImagesSinceDate:(NSDate *)date;

@end
