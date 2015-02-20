//
//  MMImageRequest.m
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "MMImageRequest.h"

@interface MMImageRequest ()

@property (readwrite, strong, nonatomic) id <MMImageManagerItem> item;
@property (readwrite, assign, nonatomic) CGSize targetSize;

@end

@implementation MMImageRequest

+ (instancetype)requestForItem:(id<MMImageManagerItem>)item targetSize:(CGSize)targetSize resultHandler:(MMImageRequestResultHandler)resultHandler
{
    if (!item) {
        return nil;
    }
    
    if (CGSizeEqualToSize(targetSize, CGSizeZero)) {
        targetSize = MMImageManagerMaximumSize;
    }
    
    MMImageRequest *request = [[self alloc] init];
    request.item = item;
    request.targetSize = targetSize;
    request.resultHandler = resultHandler;
    request.opportunistic = YES;
    
    return request;
}

- (id)copyWithZone:(NSZone *)zone
{
    MMImageRequest *request = [super copy];
    request->_item = self.item;
    request->_targetSize = self.targetSize;
    request->_resultHandler = [self.resultHandler copy];
//    request->_synchronous = self.isSynchronous;
    request->_opportunistic = self.isOportunistic;
    
    return request;
}

@end
