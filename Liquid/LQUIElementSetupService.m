//
//  LQUIElementSetupService.m
//  Liquid
//
//  Created by Miguel M. Almeida on 11/01/16.
//  Copyright © 2016 Liquid. All rights reserved.
//

#import "LQUIElementSetupService.h"
#import <objc/runtime.h>
#import <Aspects/Aspects.h>
#import <UIKit/UIKit.h>
#import "LQDefaults.h"
#import "UIViewController+LQTopmost.h"
#import "LQUIElement.h"

@interface LQUIElementSetupService() {
    BOOL touchingDown;
}

@property (nonatomic, strong) LQUIElementChanger *elementChanger;

@end

@implementation LQUIElementSetupService

@synthesize elementChanger = _elementChanger;

- (instancetype)initWithUIElementChanger:(LQUIElementChanger *)elementChanger {
    self = [super init];
    if (self) {
        _elementChanger = elementChanger;
    }
    return self;
}

#pragma mark - Change UIButton

- (void)interceptUIElements {
    static dispatch_once_t onceToken; // TODO: probably get rid of this
    dispatch_once(&onceToken, ^{
        [UIControl aspect_hookSelector:@selector(didMoveToWindow) withOptions:AspectPositionAfter usingBlock:^(id<AspectInfo> aspectInfo) {
            id object = [aspectInfo instance];
            if ([object isKindOfClass:[UIButton class]]) {
                [object addTarget:self action:@selector(touchDownButton:) forControlEvents:UIControlEventTouchDown];
                [object addTarget:self action:@selector(touchUpButton:) forControlEvents:UIControlEventTouchUpInside];
            }
        } error:NULL];
    });
}

- (void)touchDownButton:(UIButton *)button { // TODO: UIAlertController is only supported in iOS 8
    touchingDown = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (touchingDown) {
            touchingDown = NO;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Liquid"
                                                                           message:@"This button isn't being tracked. Do you want to track?"
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            [alert addAction:[UIAlertAction actionWithTitle:@"Track" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
                [self registerUIElement:[[LQUIElement alloc] initFromUIView:button]];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Don't Track" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                [self unregisterUIElement:[[LQUIElement alloc] initFromUIView:button]];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [[UIViewController topViewController] presentViewController:alert animated:YES completion:nil];
            LQLog(kLQLogLevelInfo, @"Configuring button with title %@", button.titleLabel.text);
        }
    });
}

- (void)touchUpButton:(UIButton *)button {
    touchingDown = NO;
}

#pragma mark - Alerts

- (void)showNetworkFailAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Network error"
                                                                   message:@"An error occured while configuring your UI element on Liquid. Please try again."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
    [[UIViewController topViewController] presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Button actions

- (void)registerUIElement:(LQUIElement *)element {
    [self.elementChanger registerUIElement:element withSuccessHandler:^{
        LQLog(kLQLogLevelInfo, @"<Liquid/LQUIElementChanger> Registered a new UIElement");
    } failHandler:^{
        [self showNetworkFailAlert];
    }];
}

- (void)unregisterUIElement:(LQUIElement *)element {
    [self.elementChanger unregisterUIElement:element withSuccessHandler:^{
        LQLog(kLQLogLevelInfo, @"<Liquid/LQUIElementChanger> Unregistered UIElement %@", element.identifier);
    } failHandler:^{
        [self showNetworkFailAlert];
    }];
}

@end