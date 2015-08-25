//
//  MMImageManagerOptions.h
//  MMImageManager
//
//  Created by Matías Martínez on 8/17/15.
//  Copyright © 2015 Matías Martínez. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface MMImageManagerOptions : NSObject <NSCopying>

+ (instancetype)defaultOptions;

/**
 *  The scale for images. Default is the main @c UIScreen scale.
 */
@property (assign, nonatomic) CGFloat imageScale;

/**
 *  Resizes images to fit the requested target size. Default is @c NO.
 */
@property (assign, nonatomic) BOOL resizesImagesToTargetSize;

/**
 *  Disk capacity for the image manager. By default @c 0, no limit is defined.
 */
@property (assign, nonatomic) NSUInteger diskCapacity;

/**
 *  Default expiration date for the images. If @c nil, images won't expire. By default @c nil.
 */
@property (copy, nonatomic) NSDate *expirationDate;

@end
