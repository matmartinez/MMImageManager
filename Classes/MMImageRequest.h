//
//  MMImageRequest.h
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import "MMImageManager.h"

typedef void (^MMImageRequestResultHandler)(UIImage *image, NSDictionary *info);
typedef void (^MMImageDrawRect)(UIImage *, CGRect);

@interface MMImageRequest : NSObject

+ (instancetype)requestForItem:(id <MMImageManagerItem>)item targetSize:(CGSize)targetSize resultHandler:(MMImageRequestResultHandler)resultHandler;

@property (readonly, nonatomic) id <MMImageManagerItem> item;
@property (readonly, nonatomic) CGSize targetSize;

@property (assign, nonatomic, getter = isSynchronous) BOOL synchronous NS_UNAVAILABLE;
@property (assign, nonatomic, getter = isOportunistic) BOOL opportunistic;
@property (assign, nonatomic, getter = isNetworkAccessAllowed) BOOL networkAccessAllowed;

@property (copy, nonatomic) MMImageDrawRect drawRect;
@property (assign, nonatomic) BOOL clearsContextBeforeDrawing;

@property (copy, nonatomic) MMImageRequestResultHandler resultHandler;
@property (weak, nonatomic) dispatch_queue_t resultQueue;

@end
