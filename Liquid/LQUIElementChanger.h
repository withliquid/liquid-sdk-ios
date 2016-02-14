//
//  LQUIElementChanger.h
//  Liquid
//
//  Created by Miguel M. Almeida on 10/12/15.
//  Copyright © 2015 Liquid. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "LQNetworking.h"
#import "LQUser.h"
#import "LQUIElement.h"

@interface LQUIElementChanger : NSObject

@property (atomic, strong) NSString *developerToken;

- (instancetype)initWithNetworking:(LQNetworking *)networking appToken:(NSString *)appToken;
- (void)interceptUIElementsWithBlock:(void(^)(id view))interceptBlock; // TODO: FIX ID to UIView
- (BOOL)applyChangesTo:(id)view; // TODO: FIX ID to UIView
- (void)requestUiElements;
- (void)addUIElement:(LQUIElement *)element;
- (void)removeUIElement:(LQUIElement *)element;
- (LQUIElement *)uiElementFor:(id)view; // TODO: FIX ID to UIView
- (BOOL)viewIsTrackingEvent:(id)view; // TODO: FIX ID to UIView
- (BOOL)archiveUIElements;
- (void)unarchiveUIElements;
+ (NSDictionary<NSString *, LQUIElement *> *)unarchiveHttpQueueForToken:(NSString *)apiToken;

@end
