//
//  MMImageFormat.m
//  MMImageManager
//
//  Created by Matías Martínez on 2/19/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "MMImageFormat.h"

@interface MMImageFormat ()

@property (readwrite, copy, nonatomic) NSString *name;
@property (readwrite, assign, nonatomic) CGSize imageSize;

@end

@implementation MMImageFormat

+ (MMImageFormat *)defaultImageFormat
{
    static MMImageFormat *f;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        f = [MMImageFormat imageFormatWithName:@"Default" imageSize:CGSizeZero];
    });
    return f;
}

+ (MMImageFormat *)imageFormatWithName:(NSString *)name imageSize:(CGSize)imageSize
{
    NSAssert(name && name.length > 0, @"Image format must have a name.");
    
    MMImageFormat *imageFormat = [[MMImageFormat alloc] init];
    imageFormat.name = name;
    imageFormat.imageSize = imageSize;
    
    return imageFormat;
}

- (BOOL)isEqual:(id)object
{
    if ([object isKindOfClass:[MMImageFormat class]]) {
        if ([[object name] isEqualToString:self.name]) {
            return YES;
        }
    }
    return NO;
}

- (NSUInteger)hash
{
    return self.name.hash;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, name: %@, imageSize: %@>", NSStringFromClass([self class]), self, self.name, NSStringFromCGSize(self.imageSize)];
}

@end
