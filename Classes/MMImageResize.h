//
//  UIImage+MMImageResize.h
//  MMImageManager
//
//  Created by Matías Martínez on 8/17/15.
//  Copyright © 2015 Matías Martínez. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface UIImage (MMImageResize)

/**
 *  Resizes an image with the provided size.
 *
 *  @param data An instance of @c NSData.
 *
 *  @return An @c UIImage instance.
 */
- (UIImage *)MM_imageConstrainedToSize:(CGSize)maximumImageSize;

@end
