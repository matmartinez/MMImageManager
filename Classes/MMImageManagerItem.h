//
//  MMImageManagerItem.h
//  MMImageManager
//
//  Created by Matías Martínez on 2/18/15.
//  Copyright (c) 2015 Buena Onda. All rights reserved.
//

#import <UIKit/UIKit.h>

@protocol MMImageManagerItem <NSObject>
@required

- (NSString *)imageManagerUniqueIdentifier;

@end
