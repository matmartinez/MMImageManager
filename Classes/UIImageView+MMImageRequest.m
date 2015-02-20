//
//  UIImageView+MMImageRequest.m
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "UIImageView+MMImageRequest.h"
#import <objc/runtime.h>

@interface UIImageView ()

@property (strong, nonatomic, readwrite, setter=MM_setImageRequest:) MMImageRequest *imageRequest;

@end

@implementation UIImageView (MMImageRequest)

- (void)configureWithImageRequest:(MMImageRequest *)imageRequest
{
    MMImageRequest *previousImageRequest = self.imageRequest;
    if (previousImageRequest == imageRequest) {
        return;
    }
    
    MMImageManager *imageManager = self.imageManager;
    if (previousImageRequest) {
        [imageManager cancelRequest:imageRequest];
    }
    
    [self MM_setImageRequest:imageRequest];
    
    self.image = nil;
    
    if (imageRequest) {
        __weak typeof(self)weakSelf = self;
        __weak typeof(imageRequest)weakImageRequest = imageRequest;
        
        if (!imageRequest.resultHandler) {
            imageRequest.resultHandler = ^(UIImage *image, NSDictionary *info){
                __strong __typeof(&*weakSelf)strongSelf = weakSelf;
                __strong __typeof(&*weakImageRequest)strongImageRequest = weakImageRequest;
                
                if (strongSelf.imageRequest != strongImageRequest) {
                    return;
                }
                
                [strongSelf setImage:image];
            };
        }
        
        [imageManager addRequest:imageRequest];
    }
}

#pragma mark - Properties.

- (void)MM_setImageRequest:(MMImageRequest *)imageManager
{
    objc_setAssociatedObject(self, @selector(imageRequest), imageManager, OBJC_ASSOCIATION_RETAIN);
}

- (MMImageRequest *)imageRequest
{
    return objc_getAssociatedObject(self, @selector(imageRequest));
}

- (void)setImageManager:(MMImageManager *)imageManager
{
    [self configureWithImageRequest:nil];
    
    objc_setAssociatedObject(self, @selector(imageManager), imageManager, OBJC_ASSOCIATION_RETAIN);
}

- (MMImageManager *)imageManager
{
    MMImageManager *instanceImageManager = objc_getAssociatedObject(self, @selector(imageManager));
    return instanceImageManager ?: [self.class sharedImageManager];
}

#pragma mark - Class instance.

static MMImageManager *_sharedImageManager;

+ (void)setSharedImageManager:(MMImageManager *)imageManager
{
    _sharedImageManager = imageManager;
}

+ (MMImageManager *)sharedImageManager
{
    return _sharedImageManager;
}

@end
