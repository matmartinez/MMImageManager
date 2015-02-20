//
//  MMImageFormat.h
//  MMImageManager
//
//  Created by Matías Martínez on 2/19/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface MMImageFormat : NSObject

+ (MMImageFormat *)imageFormatWithName:(NSString *)name imageSize:(CGSize)imageSize;
+ (MMImageFormat *)defaultImageFormat;

@property (readonly, copy, nonatomic) NSString *name;
@property (readonly, nonatomic) CGSize imageSize;

@end
