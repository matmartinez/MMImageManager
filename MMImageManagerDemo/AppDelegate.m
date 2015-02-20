//
//  AppDelegate.m
//  MMImageManager
//
//  Created by Matías Martínez on 2/20/15.
//  Copyright (c) 2015 Matías Martínez. All rights reserved.
//

#import "AppDelegate.h"
#import "ViewController.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    ViewController *viewController = [[ViewController alloc] init];
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.rootViewController = viewController;
    
    self.window = window;
    
    [window makeKeyAndVisible];
    
    return YES;
}

@end
