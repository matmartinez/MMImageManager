//
//  UIImageView+MMImageRequest.h
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "MMImageRequest.h"

@interface UIImageView (MMImageRequest)

- (void)configureWithImageRequest:(MMImageRequest *)imageRequest;

@property (readonly, nonatomic) MMImageRequest *imageRequest;
@property (strong, nonatomic) MMImageManager *imageManager;

+ (void)setSharedImageManager:(MMImageManager *)imageManager;
+ (MMImageManager *)sharedImageManager;

@end
