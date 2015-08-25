//
//  MMImageManagerOptions.m
//  MMImageManager
//
//  Created by Matías Martínez on 8/17/15.
//  Copyright © 2015 Matías Martínez. All rights reserved.
//

#import "MMImageManagerOptions.h"
#import <UIKit/UIKit.h>

@implementation MMImageManagerOptions

+ (instancetype)defaultOptions
{
    MMImageManagerOptions *options = [[self alloc] init];
    options.resizesImagesToTargetSize = NO;
    options.diskCapacity = 0;
    options.imageScale = [UIScreen mainScreen].scale;
    
    return options;
}

#pragma mark - NSCopying.

- (id)copyWithZone:(NSZone *)zone
{
    MMImageManagerOptions *newOptions = [[[self class] allocWithZone:zone] init];
    newOptions->_resizesImagesToTargetSize = _resizesImagesToTargetSize;
    newOptions->_diskCapacity = _diskCapacity;
    newOptions->_imageScale = _imageScale;
    newOptions->_expirationDate = [_expirationDate copyWithZone:zone];
    
    return newOptions;
}

@end
