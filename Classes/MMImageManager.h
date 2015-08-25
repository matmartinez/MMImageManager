//
//  MMImageManager.h
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "MMImageManagerItem.h"
#import "MMImageManagerOptions.h"
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
- (instancetype)initWithName:(NSString *)name options:(MMImageManagerOptions *)options NS_DESIGNATED_INITIALIZER;

@property (readonly, copy, nonatomic) NSString *name;
@property (readonly, nonatomic) NSUInteger currentDiskUsage;

@property (strong, nonatomic) id <MMImageManagerImageSource> imageSource;

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

@end

@interface MMImageManager (CacheControl)

- (void)removeImageFormat:(MMImageFormat *)format forItem:(id <MMImageManagerItem>)item scheduledWithDate:(NSDate *)date;
- (void)removeImagesSinceDate:(NSDate *)date;

@end
