//
//  UIImage+MMImageResize.m
//  MMImageManager
//
//  Created by Matías Martínez on 8/17/15.
//  Copyright © 2015 Matías Martínez. All rights reserved.
//

#import "MMImageResize.h"

@implementation UIImage (MMImageResize)

- (BOOL)MM_hasAlpha
{
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(self.CGImage);
    BOOL hasAlpha = !(alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast);
    
    return hasAlpha;
}

- (UIImage *)MM_imageConstrainedToSize:(CGSize)maximumImageSize
{
    const CGSize imageSize = self.size;
    
    CGFloat xScale = maximumImageSize.width  / imageSize.width;
    CGFloat yScale = maximumImageSize.height / imageSize.height;
    CGFloat minScale = MIN(xScale, yScale);
    
    if (minScale >= 1.0f) {
        return self;
    }
    
    NSLog(@"Resizing!!");
    
    CGSize newSize = { round(imageSize.width * minScale), round(imageSize.height * minScale) };
    
    UIGraphicsBeginImageContextWithOptions(newSize, ![self MM_hasAlpha], self.scale);
    [self drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return newImage;
}

@end
