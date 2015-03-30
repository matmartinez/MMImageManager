//
//  UIImage+MMImageInflate.h
//  MMImageManager
//
//  Created by Matías Martínez on 3/30/15.
//  Copyright (c) 2015 Matías Martínez. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface UIImage (MMImageInflate)

/**
 *  Creates and decompresses an image with the provided image data.
 *
 *  @param data An instance of @c NSData.
 *
 *  @return An @c UIImage instance.
 */
+ (UIImage *)MM_inflatedImageWithData:(NSData *)data;

/**
 *  Creates and decompresses an image with the provided image data and scale.
 *
 *  @param data  An instance of @c NSData.
 *  @param scale The scale for the image.
 *
 *  @return An @c UIImage instance.
 */
+ (UIImage *)MM_inflatedImageWithData:(NSData *)data scale:(CGFloat)scale;

@end
