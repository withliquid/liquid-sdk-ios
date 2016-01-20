//
//  LQUIElementSetupService.h
//  Liquid
//
//  Created by Miguel M. Almeida on 11/01/16.
//  Copyright © 2016 Liquid. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "LQUIElementChanger.h"

@interface LQUIElementSetupService : NSObject

- (instancetype)initWithUIElementChanger:(LQUIElementChanger *)elementChanger;
- (void)interceptUIElements;

@end