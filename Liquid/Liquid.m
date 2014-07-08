//
//  Liquid.m
//  Liquid
//
//  Created by Liquid Liquid Data Intelligence, S.A. (lqd.io) on 09/01/14.
//  Copyright (c) 2014 Liquid Data Intelligence, S.A. All rights reserved.
//

#import "Liquid.h"

#import <UIKit/UIApplication.h>

#import "LQEvent.h"
#import "LQSession.h"
#import "LQDevice.h"
#import "LQUser.h"
#import "LQQueue.h"
#import "LQValue.h"
#import "LQTarget.h"
#import "LQDataPoint.h"
#import "LQLiquidPackage.h"
#import "LQDefaults.h"
#import "UIColor+LQColor.h"
#import "NSDateFormatter+LQDateFormatter.h"
#import "NSString+LQString.h"

@interface Liquid ()

@property(nonatomic, strong) NSString *apiToken;
@property(nonatomic, assign) BOOL developmentMode;
@property(nonatomic, strong) LQUser *currentUser;
@property(nonatomic, strong) LQUser *previousUser;
@property(nonatomic, strong) LQDevice *device;
@property(nonatomic, strong) LQSession *currentSession;
@property(nonatomic, strong) NSDate *enterBackgroundTime;
@property(nonatomic, strong) NSDate *veryFirstMoment;
@property(nonatomic, assign) BOOL firstEventSent;
@property(nonatomic, assign) BOOL inBackground;
#if OS_OBJECT_USE_OBJC
@property(nonatomic, strong) dispatch_queue_t queue;
#else
@property(nonatomic, assign) dispatch_queue_t queue;
#endif
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray *httpQueue;
@property(nonatomic, strong) LQLiquidPackage *loadedLiquidPackage; // (includes loaded Targets and loaded Values)
@property(nonatomic, strong) NSMutableArray *valuesSentToServer;
@property(nonatomic, strong, readonly) NSString *liquidUserAgent;

@end

static Liquid *sharedInstance = nil;

@implementation Liquid

@synthesize flushInterval = _flushInterval;
@synthesize autoLoadValues = _autoLoadValues;
@synthesize queueSizeLimit = _queueSizeLimit;
@synthesize flushOnBackground = _flushOnBackground;
@synthesize sessionTimeout = _sessionTimeout;
@synthesize sendFallbackValuesInDevelopmentMode = _sendFallbackValuesInDevelopmentMode;
@synthesize liquidUserAgent = _liquidUserAgent;
@synthesize valuesSentToServer = _valuesSentToServer;

NSString * const LQDidReceiveValues = kLQNotificationLQDidReceiveValues;
NSString * const LQDidLoadValues = kLQNotificationLQDidLoadValues;
NSString * const LQDidIdentifyUser = kLQNotificationLQDidIdentifyUser;

#pragma mark - Singletons

+ (Liquid *)sharedInstanceWithToken:(NSString *)apiToken {
    return [Liquid sharedInstanceWithToken:apiToken development:NO];
}

+ (Liquid *)sharedInstanceWithToken:(NSString *)apiToken development:(BOOL)development {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[super alloc] initWithToken:apiToken development:development];
    });
    return sharedInstance;
}

+ (Liquid *)sharedInstance {
    if (sharedInstance == nil) {
        NSAssert(false, @"<Liquid> Error: %@ sharedInstance called before sharedInstanceWithToken:", self);
        LQLog(kLQLogLevelError, @"<Liquid> Error: %@ sharedInstance called before sharedInstanceWithToken:", self);
    }
    return sharedInstance;
}

#pragma mark - Initialization

- (instancetype)initWithToken:(NSString *)apiToken {
    return [self initWithToken:apiToken development:NO];
}

-(void)invalidateTargetThatIncludesVariable:(NSString *)variableName {
    LQLiquidPackage *loadedLiquidPackage = [_loadedLiquidPackage copy];
    NSInteger numberOfInvalidatedValues = [loadedLiquidPackage invalidateTargetThatIncludesVariable:variableName];
    _loadedLiquidPackage = loadedLiquidPackage;

    if (numberOfInvalidatedValues > 0) {
        __block __strong LQLiquidPackage *liquidPackageToStore = [loadedLiquidPackage copy];
        dispatch_async(self.queue, ^() {
            [liquidPackageToStore saveToDiskForToken:_apiToken];
        });
    }

    if (numberOfInvalidatedValues > 1) { // if included on a target
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyDelegatesAndObserversAboutNewValues];
        });
    }
}

- (instancetype)initWithToken:(NSString *)apiToken development:(BOOL)development {
    [self veryFirstMoment];
    _firstEventSent = NO;
    if (development) {
        _developmentMode = YES;
    } else {
        _developmentMode = NO;
    }
    if (apiToken == nil) apiToken = @"";
    if ([apiToken length] == 0) {
        NSAssert(false, @"<Liquid> Error: %@ empty API Token", self);
        LQLog(kLQLogLevelError, @"<Liquid> Error: %@ empty API Token", self);
    }
    if (self = [self init]) {
        self.httpQueue = [Liquid unarchiveQueueForToken:apiToken];
        
        // Initialization
        self.apiToken = apiToken;
        self.serverURL = kLQServerUrl;
        self.device = [[LQDevice alloc] initWithLiquidVersion:kLQVersion];
        _sendFallbackValuesInDevelopmentMode = kLQSendFallbackValuesInDevelopmentMode;
        NSString *queueLabel = [NSString stringWithFormat:@"%@.%@.%p", kLQBundle, apiToken, self];
        self.queue = dispatch_queue_create([queueLabel UTF8String], DISPATCH_QUEUE_SERIAL);
        
        // Start auto flush timer
        [self startFlushTimer];

        if(!_loadedLiquidPackage) {
            [self loadLiquidPackageSynced:YES];
        }

        // Load user from previous launch:
        _previousUser = [self loadLastUserFromDisk];
        [self autoIdentifyUser];

        // Bind notifications:
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
                               selector:@selector(applicationDidBecomeActive:)
                                   name:UIApplicationDidBecomeActiveNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(applicationWillResignActive:)
                                   name:UIApplicationWillResignActiveNotification
                                 object:nil];
        
        LQLog(kLQLogLevelInfoVerbose, @"<Liquid> Initialized Liquid with API Token %@", apiToken);
    }
    return self;
}

#pragma mark - Lazy initialization

- (BOOL)inBackground {
    if (!_inBackground) _inBackground = NO;
    return _inBackground;
}

- (NSDate *)veryFirstMoment {
    if (!_veryFirstMoment) _veryFirstMoment = [NSDate new];
    return _veryFirstMoment;
}

- (BOOL)flushOnBackground {
    if (!_flushOnBackground) _flushOnBackground = kLQDefaultFlushOnBackground;
    return _flushOnBackground;
}

- (NSUInteger)queueSizeLimit {
    if (!_queueSizeLimit) _queueSizeLimit = kLQDefaultHttpQueueSizeLimit;
    return _queueSizeLimit;
}

- (NSUInteger)flushInterval {
    @synchronized(self) {
        if (!_flushInterval) _flushInterval = kLQDefaultFlushInterval;
        if (_flushInterval < kLQMinFlushInterval) return kLQMinFlushInterval;
        return _flushInterval;
    }
}

- (void)setQueueSizeLimit:(NSUInteger)queueSizeLimit {
    @synchronized(self) {
        _queueSizeLimit = queueSizeLimit;
    }
}

- (void)setFlushInterval:(NSUInteger)interval {
    [self stopFlushTimer];
    @synchronized(self) {
        if (_flushInterval < kLQMinFlushInterval) _flushInterval = kLQMinFlushInterval;
        _flushInterval = interval;
    }
    [self startFlushTimer];
}

- (NSInteger)sessionTimeout {
    @synchronized(self) {
        if (!_sessionTimeout) _sessionTimeout = kLQDefaultSessionTimeout;
        return _sessionTimeout;
    }
}

- (void)setSessionTimeout:(NSInteger)sessionTimeout {
    @synchronized(self) {
        _sessionTimeout = sessionTimeout;
    }
}

- (NSString *)liquidUserAgent {
    if(!_liquidUserAgent) {
        _liquidUserAgent = [NSString stringWithFormat:@"Liquid/%@ (%@ ; %@)", kLQVersion, kLQDevicePlatform, [LQDevice deviceModel]];
    }
    return _liquidUserAgent;
}

- (NSArray *)valuesSentToServer {
    if (!_valuesSentToServer) {
        _valuesSentToServer = [[NSMutableArray alloc] init];
    }
    return _valuesSentToServer;
}

#pragma mark - UIApplication notifications

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Check for session timeout on app resume
    BOOL sessionTimedOut = [self checkSessionTimeout];
    
    // Restart flush timer
    [self startFlushTimer];

    dispatch_async(self.queue, ^() {
        self.enterBackgroundTime = nil;
        // Restore queue from plist
        self.httpQueue = [Liquid unarchiveQueueForToken:self.apiToken];
    });

    if(!sessionTimedOut && self.inBackground) {
        [self track:@"_resumeSession" attributes:nil allowLqdEvents:YES];
        _inBackground = NO;
    }

    // Request variables on app resume
    [self loadLiquidPackageSynced:YES];
}

- (void)applicationWillResignActive:(NSNotificationCenter *)notification {
    self.enterBackgroundTime = [NSDate new];
    self.inBackground = YES;

    // Stop flush timer on app pause
    [self stopFlushTimer];
    
    [self track:@"_pauseSession" attributes:nil allowLqdEvents:YES];

    if (self.flushOnBackground) {
        [self flush];
    }

    // Request variables on app pause
    [self requestNewLiquidPackageSynced];
}

#pragma mark - User identifying methods (real methods)

-(void)identifyUserWithIdentifier:(NSString *)identifier attributes:(NSDictionary *)attributes alias:(BOOL)alias {
    NSDictionary *validAttributes = [LQUser assertAttributesTypesAndKeys:attributes];
    if (identifier && identifier.length == 0) {
        LQLog(kLQLogLevelError, @"<Liquid> Error (%@): No User identifier was given: %@", self, identifier);
        return;
    }
    LQUser *newUser = [[LQUser alloc] initWithIdentifier:[identifier copy] attributes:[validAttributes copy]];
    [self identifyUserSynced:newUser alias:alias];
}

-(void)identifyUserSynced:(LQUser *)user alias:(BOOL)alias {
    LQUser *newUser = [user copy];
    LQUser *currentUser = [self.currentUser copy];
    if (newUser.identifier == currentUser.identifier) {
        self.currentUser.attributes = newUser.attributes;
        LQLog(kLQLogLevelInfoVerbose, @"<Liquid> Already identified with user %@. Not identifying again.", user.identifier);
        return;
    }

    if ([self.currentSession inProgress]) {
        [self endSessionNow];
    }
    _previousUser = currentUser;
    _currentUser = newUser;
    [self newSessionInCurrentThread:YES];
    [self requestNewLiquidPackage];

    // Notifiy the outside world:
    NSDictionary *notificationUserInfo = [NSDictionary dictionaryWithObjectsAndKeys:newUser, @"identifier", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:LQDidIdentifyUser object:nil userInfo:notificationUserInfo];
    if([self.delegate respondsToSelector:@selector(liquidDidIdentifyUserWithIdentifier:)]) {
        [self.delegate performSelectorOnMainThread:@selector(liquidDidIdentifyUserWithIdentifier:)
                                        withObject:newUser.identifier
                                     waitUntilDone:NO];
    }

    [self saveCurrentUserToDisk];
    
    if (alias) {
        [self aliasUserWithPreviousAnonymousUser];
    }

    LQLog(kLQLogLevelInfo, @"<Liquid> From now on, we're identifying the User by identifier '%@'", newUser.identifier);
}

#pragma mark - User identifying methods (alias methods)

// Deprecated:
- (void)identifyUser {
    [self resetUser];
}

// Deprecated:
- (void)identifyUserWithAttributes:(NSDictionary *)attributes {
    [self identifyUserWithIdentifier:nil attributes:[LQUser assertAttributesTypesAndKeys:attributes] alias:NO];
}

// Deprecated:
- (void)identifyUserWithIdentifier:(NSString *)identifier attributes:(NSDictionary *)attributes location:(CLLocation *)location {
    [self identifyUserWithIdentifier:identifier attributes:attributes alias:YES];
    dispatch_async(self.queue, ^() {
        [self setCurrentLocation:location];
    });
}

- (void)autoIdentifyUser {
    if (self.previousUser) {
        LQLog(kLQLogLevelInfo, @"<Liquid> Identifying user (using cached user: %@)", _previousUser.identifier);
        [self identifyUserSynced:_previousUser alias:NO];
    } else {
        LQLog(kLQLogLevelInfo, @"<Liquid> Auto identifying user: creating a new auto identified user (%@)", _currentUser.identifier);
        [self identifyUserWithIdentifier:nil attributes:nil alias:NO];
    }
}

- (void)resetUser {
    [self identifyUserWithIdentifier:nil attributes:nil alias:NO];
}

- (void)identifyUserWithIdentifier:(NSString *)identifier {
    [self identifyUserWithIdentifier:identifier attributes:nil alias:YES];
}

- (void)identifyUserWithIdentifier:(NSString *)identifier attributes:(NSDictionary *)attributes {
    [self identifyUserWithIdentifier:identifier attributes:attributes alias:YES];
}

- (void)identifyUserSynced:(LQUser *)user {
    [self identifyUserSynced:user alias:YES];
}

- (void)identifyUserWithIdentifier:(NSString *)identifier alias:(BOOL)alias {
    [self identifyUserWithIdentifier:identifier alias:alias];
}

#pragma mark - User related stuff

-(NSString *)userIdentifier {
    if(self.currentUser == nil) {
        LQLog(kLQLogLevelError, @"<Liquid> Error: A user has not been identified yet.");
    }
    return self.currentUser.identifier;
}

- (NSString *)deviceIdentifier {
    return [self.device uid];
}

-(void)setUserAttribute:(id)attribute forKey:(NSString *)key {
    if (![LQUser assertAttributeType:attribute andKey:key]) return;

    dispatch_async(self.queue, ^() {
        if(self.currentUser == nil) {
            LQLog(kLQLogLevelError, @"<Liquid> Error: A user has not been identified yet.");
            return;
        }
        [self.currentUser setAttribute:attribute
                                forKey:key];
        [self saveCurrentUserToDisk];
    });
}

// Deprecated:
-(void)setUserLocation:(CLLocation *)location {
    [self setCurrentLocation:location];
}

-(void)setCurrentLocation:(CLLocation *)location {
    dispatch_async(self.queue, ^() {
        if(self.currentUser == nil) {
            LQLog(kLQLogLevelError, @"<Liquid> Error: A user has not been identified yet.");
            return;
        }
        [self.device setLocation:location];
    });
}

- (void)saveCurrentUserToDisk {
    __block LQUser *user = [self.currentUser copy];
    dispatch_async(self.queue, ^() {
        [user saveToDiskForToken:_apiToken];
    });
}

- (LQUser *)loadLastUserFromDisk {
    LQUser *user = [LQUser loadFromDiskForToken:_apiToken];
    self.currentUser = [user copy];
    return user;
}

#pragma mark - User aliasing of auto identified users

- (void)aliasUserWithPreviousAnonymousUser {
    LQUser *previousUser = [self.previousUser copy];
    if ([previousUser isAutoIdentified]) {
        [self reidentifyUser:previousUser withIdentifier:self.currentUser.identifier];
    }
}

- (void)reidentifyUser:(LQUser *)user withIdentifier:(NSString *)newIdentifier {
    __block LQUser *userToReidentify = [user copy];
    __block NSString *newUserIdentifier = [newIdentifier copy];
    if (![userToReidentify isAutoIdentified]) {
        LQLog(kLQLogLevelError, @"<Liquid> Error: You're trying to reidentify an already identified user %@. It is only possible to reidentify auto identified users", userToReidentify.identifier);
        return;
    }
    LQLog(kLQLogLevelInfo, @"<Liquid> Reidentifying auto identified user (%@) with a new identifier (%@)", userToReidentify.identifier, newUserIdentifier);
    dispatch_async(self.queue, ^{
        NSDictionary *params = [[NSDictionary alloc] initWithObjectsAndKeys:newIdentifier, @"new_user_id", nil];
        NSString *endpoint = [NSString stringWithFormat:@"%@users/%@/devices/%@/reidentify", self.serverURL, userToReidentify.identifier, self.device.uid];
        [self addToHttpQueue:params
                    endPoint:[NSString stringWithFormat:endpoint, self.serverURL]
                  httpMethod:@"POST"];
    });
}

#pragma mark - Sessions

- (void)endSessionAt:(NSDate *)endAt {
    // adding a millisecond, just to ensure that session is ended after all anything else
    NSDate *fixedEndAt = [[endAt copy] dateByAddingTimeInterval:0.001];
    if (self.currentUser != nil && self.currentSession != nil && self.currentSession.inProgress) {
        [[self currentSession] endSessionOnDate:fixedEndAt];
        [self track:@"_endSession" attributes:nil allowLqdEvents:YES withDate:fixedEndAt];
    }
}

- (void)endSessionNow {
    [self endSessionAt:[NSDate date]];
}

- (void)newSessionInCurrentThread:(BOOL)inThread {
    __block NSDate *now;
    if (!_firstEventSent) {
        now = [self veryFirstMoment];
        _firstEventSent = YES;
    } else {
        now = [NSDate new];
    }
    __block void (^newSessionBlock)() = ^() {
        if(self.currentUser == nil) {
            LQLog(kLQLogLevelError, @"<Liquid> Error: A user has not been identified yet.");
            return;
        }
        self.currentSession = [[LQSession alloc] initWithDate:now timeout:[NSNumber numberWithInt:(int)_sessionTimeout]];
        [self track:@"_startSession" attributes:nil allowLqdEvents:YES withDate:now];
    };
    if(inThread) {
        newSessionBlock();
    } else {
        dispatch_async(self.queue, newSessionBlock);
    }
}

- (BOOL)checkSessionTimeout {
    if(self.currentSession != nil) {
        NSDate *now = [NSDate new];
        NSTimeInterval interval = [now timeIntervalSinceDate:self.enterBackgroundTime];
        if(interval >= _sessionTimeout || interval > kLQDefaultSessionMaxLimit) {
            if ([self.currentSession inProgress]) {
                [self endSessionAt:self.enterBackgroundTime];
            }
            [self newSessionInCurrentThread:NO];
            return YES;
        }
    }
    return NO;
}

- (NSString *)sessionIdentifier {
    return self.currentSession.identifier;
}

#pragma mark - Event

-(void)track:(NSString *)eventName {
    [self track:eventName attributes:nil allowLqdEvents:NO];
}

-(void)track:(NSString *)eventName attributes:(NSDictionary *)attributes {
    NSDictionary *validAttributes = [LQEvent assertAttributesTypesAndKeys:attributes];

    [self track:eventName attributes:validAttributes allowLqdEvents:NO];
}

-(void)track:(NSString *)eventName attributes:(NSDictionary *)attributes allowLqdEvents:(BOOL)allowLqdEvents {
    [self track:eventName attributes:attributes allowLqdEvents:allowLqdEvents withDate:nil];
}

-(void)track:(NSString *)eventName attributes:(NSDictionary *)attributes allowLqdEvents:(BOOL)allowLqdEvents withDate:(NSDate *)eventDate {
    __block NSDictionary *validAttributes = [LQEvent assertAttributesTypesAndKeys:attributes];

    if([eventName hasPrefix:@"_"] && !allowLqdEvents) {
        NSAssert(false, @"<Liquid> Event names cannot start with _");
        LQLog(kLQLogLevelAssert, @"<Liquid> Event names cannot start with _");
        return;
    }

    if(!self.currentUser) {
        [self autoIdentifyUser];
    }

    __block NSDate *now;
    if (eventDate) {
        now = eventDate;
    } else {
        now = [NSDate new];
    }
    
    if ([eventName hasPrefix:@"_"]) {
        LQLog(kLQLogLevelInfoVerbose, @"<Liquid> Tracking Liquid event %@ (%@)", eventName, [NSDateFormatter iso8601StringFromDate:now]);
    } else {
        LQLog(kLQLogLevelInfo, @"<Liquid> Tracking event %@ (%@)", eventName, [NSDateFormatter iso8601StringFromDate:now]);
    }
    
    __block NSString *finalEventName = eventName;
    if (eventName == nil || [eventName length] == 0) {
        LQLog(kLQLogLevelInfo, @"<Liquid> Tracking unnammed event.");
        finalEventName = @"unnamedEvent";
    }
    __block __strong LQEvent *event = [[LQEvent alloc] initWithName:finalEventName attributes:validAttributes date:now];
    __block __strong LQUser *user = [self.currentUser copy];
    __block __strong LQDevice *device = [self.device copy];
    __block __strong LQSession *session = [self.currentSession copy];
    __block __strong NSArray *loadedValues = [_loadedLiquidPackage.values copy];
    dispatch_async(self.queue, ^{
        LQDataPoint *dataPoint = [[LQDataPoint alloc] initWithDate:now
                                                              user:user
                                                            device:device
                                                           session:session
                                                             event:event
                                                            values:loadedValues];
        NSString *endPoint = [NSString stringWithFormat:@"%@data_points", self.serverURL, nil];
        [self addToHttpQueue:[dataPoint jsonDictionary]
                endPoint:endPoint
              httpMethod:@"POST"];
    });
}

#pragma mark - Liquid Package

-(LQLiquidPackage *)requestNewLiquidPackageSynced {
    if(!self.currentUser) {
        [self autoIdentifyUser];
    }
    NSString *endPoint = [NSString stringWithFormat:@"%@users/%@/devices/%@/liquid_package", self.serverURL, self.currentUser.identifier, self.device.uid, nil];
    NSData *dataFromServer = [self getDataFromEndpoint:endPoint];
    LQLiquidPackage *liquidPackage = nil;
    if(dataFromServer != nil) {
        NSDictionary *liquidPackageDictionary = [Liquid fromJSON:dataFromServer];
        if(liquidPackageDictionary == nil) {
            return nil;
        }
        liquidPackage = [[LQLiquidPackage alloc] initFromDictionary:liquidPackageDictionary];
        [liquidPackage saveToDiskForToken:_apiToken];

        [[NSNotificationCenter defaultCenter] postNotificationName:LQDidReceiveValues object:nil];
        if([self.delegate respondsToSelector:@selector(liquidDidReceiveValues)]) {
            [self.delegate performSelectorOnMainThread:@selector(liquidDidReceiveValues)
                                            withObject:nil
                                         waitUntilDone:NO];
        }
        if(_autoLoadValues) {
            [self loadLiquidPackageSynced:NO];
        }
    }
    return liquidPackage;
}

-(void)requestNewLiquidPackage {
    dispatch_async(self.queue, ^{
        [self requestNewLiquidPackageSynced];
    });
}

-(void)requestValues {
    [self requestNewLiquidPackage];
}

-(LQLiquidPackage *)loadLiquidPackageFromDisk {
    // Ensure legacy:
    if (_loadedLiquidPackage && ![_loadedLiquidPackage liquidVersion]) {
        LQLog(kLQLogLevelNone, @"<Liquid> SDK was updated: destroying cached Liquid Package to ensure legacy");
        [LQLiquidPackage destroyCachedLiquidPackageForToken:_apiToken];
    }

    LQLiquidPackage *cachedLiquidPackage = [LQLiquidPackage loadFromDiskForToken:_apiToken];
    if (cachedLiquidPackage) {
        return cachedLiquidPackage;
    }
    return [[LQLiquidPackage alloc] initWithValues:[[NSArray alloc] initWithObjects:nil]];
}

-(void)loadLiquidPackageSynced:(BOOL)synced {
    if (synced) {
        _loadedLiquidPackage = [self loadLiquidPackageFromDisk];
    } else {
        dispatch_async(self.queue, ^{
            _loadedLiquidPackage = [self loadLiquidPackageFromDisk];
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self notifyDelegatesAndObserversAboutNewValues];
            });
        });
    }
}

-(void)loadValues {
    [self loadLiquidPackageSynced:NO];
}

-(void)notifyDelegatesAndObserversAboutNewValues {
    NSDictionary *userInfo = [[NSDictionary alloc] initWithObjectsAndKeys:[_loadedLiquidPackage dictOfVariablesAndValues], @"values", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:LQDidLoadValues object:nil userInfo:userInfo];
    if([self.delegate respondsToSelector:@selector(liquidDidLoadValues)]) {
        [self.delegate performSelectorOnMainThread:@selector(liquidDidLoadValues)
                                        withObject:nil
                                     waitUntilDone:NO];
    }
    LQLog(kLQLogLevelInfoVerbose, @"<Liquid> Loaded Values: %@", [_loadedLiquidPackage dictOfVariablesAndValues]);
}

#pragma mark - Development functionalities

-(void)sendVariable:(NSString *)variableName fallback:(id)fallbackValue liquidType:(NSString *)typeString {
    dispatch_async(self.queue, ^{
        if ([self.valuesSentToServer indexOfObject:variableName] == NSNotFound) {
            [self.valuesSentToServer addObject:variableName];
            NSDictionary *variable = [[NSDictionary alloc] initWithObjectsAndKeys:variableName, @"name",
                                      typeString, @"data_type",
                                      (fallbackValue?fallbackValue:[NSNull null]), @"default_value", nil];
            NSData *json = [Liquid toJSON:variable];
            LQLog(kLQLogLevelInfoVerbose, @"<Liquid> Sending fallback Variable to server: %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
            NSInteger res = [self sendData:json
                                toEndpoint:[NSString stringWithFormat:@"%@variables", self.serverURL]
                               usingMethod:@"POST"];
            if(res != LQQueueStatusOk) LQLog(kLQLogLevelHttp, @"<Liquid> Could not send variables to server %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
        }
    });
}

#pragma mark - Values with Data Types

-(NSDate *)dateForKey:(NSString *)variableName fallback:(NSDate *)fallbackValue {
    if(_developmentMode && self.sendFallbackValuesInDevelopmentMode && fallbackValue) {
        [self sendVariable:variableName fallback:fallbackValue liquidType:kLQDataTypeDateTime];
    }

    NSError *error;
    LQValue *value = [_loadedLiquidPackage valueForKey:variableName error:&error];
    if(error == nil) {
        if(value == nil) {
            return nil;
        }
        if([value.variable matchesLiquidType:kLQDataTypeDateTime]) {
            NSDate *date = [NSDateFormatter dateFromISO8601String:value.value];
            if(!date) {
                [self invalidateTargetThatIncludesVariable:variableName];
                return fallbackValue;
            }
            return date;
        }
    }
    [self invalidateTargetThatIncludesVariable:variableName];
    return fallbackValue;
}

-(UIColor *)colorForKey:(NSString *)variableName fallback:(UIColor *)fallbackValue {
    if(_developmentMode && self.sendFallbackValuesInDevelopmentMode && fallbackValue) {
        [self sendVariable:variableName fallback:fallbackValue liquidType:kLQDataTypeColor];
    }
    
    NSError *error;
    LQValue *value = [_loadedLiquidPackage valueForKey:variableName error:&error];
    if(error == nil) {
        if(value == nil)
            return nil;
        if([value.variable matchesLiquidType:kLQDataTypeColor]) {
            @try {
                id color = [UIColor colorFromHexadecimalString:value.value];
                if([color isKindOfClass:[UIColor class]]) {
                    return color;
                }
                [self invalidateTargetThatIncludesVariable:variableName];
                return fallbackValue;
            }
            @catch (NSException *exception) {
                LQLog(kLQLogLevelError, @"<Liquid> Variable '%@' value cannot be converted to a color: <%@> %@", variableName, exception.name, exception.reason);
                [self invalidateTargetThatIncludesVariable:variableName];
                return fallbackValue;
            }
        }
    }
    [self invalidateTargetThatIncludesVariable:variableName];
    return fallbackValue;
}

-(NSString *)stringForKey:(NSString *)variableName fallback:(NSString *)fallbackValue {
    if(_developmentMode && self.sendFallbackValuesInDevelopmentMode && fallbackValue) {
        [self sendVariable:variableName fallback:fallbackValue liquidType:kLQDataTypeString];
    }

    NSError *error;
    LQValue *value = [_loadedLiquidPackage valueForKey:variableName error:&error];
    if(error == nil) {
        if(value == nil) {
            return nil;
        }
        if([value.variable matchesLiquidType:kLQDataTypeString]) {
            return value.value;
        }
    }
    [self invalidateTargetThatIncludesVariable:variableName];
    return fallbackValue;
}

-(NSInteger)intForKey:(NSString *)variableName fallback:(NSInteger)fallbackValue {
    if(_developmentMode && self.sendFallbackValuesInDevelopmentMode) {
        [self sendVariable:variableName fallback:[NSNumber numberWithInteger:fallbackValue] liquidType:kLQDataTypeInteger];
    }

    NSError *error;
    LQValue *value = [_loadedLiquidPackage valueForKey:variableName error:&error];
    if(error == nil) {
        if([value.variable matchesLiquidType:kLQDataTypeInteger]) {
            return [value.value integerValue];
        }
    }
    [self invalidateTargetThatIncludesVariable:variableName];
    return fallbackValue;
}

-(CGFloat)floatForKey:(NSString *)variableName fallback:(CGFloat)fallbackValue {
    if(_developmentMode && self.sendFallbackValuesInDevelopmentMode) {
        [self sendVariable:variableName fallback:[NSNumber numberWithFloat:fallbackValue] liquidType:kLQDataTypeFloat];
    }

    NSError *error;
    LQValue *value = [_loadedLiquidPackage valueForKey:variableName error:&error];
    if(error == nil) {
        if([value.variable matchesLiquidType:kLQDataTypeFloat]) {
            return [value.value floatValue];
        }
    }
    [self invalidateTargetThatIncludesVariable:variableName];
    return fallbackValue;
}

-(BOOL)boolForKey:(NSString *)variableName fallback:(BOOL)fallbackValue {
    if(_developmentMode && self.sendFallbackValuesInDevelopmentMode) {
        [self sendVariable:variableName fallback:[NSNumber numberWithBool:fallbackValue] liquidType:kLQDataTypeBoolean];
    }

    NSError *error;
    LQValue *value = [_loadedLiquidPackage valueForKey:variableName error:&error];
    if(error == nil) {
        if([value.variable matchesLiquidType:kLQDataTypeBoolean]) {
            return [value.value boolValue];
        }
    }
    [self invalidateTargetThatIncludesVariable:variableName];
    return fallbackValue;
}

#pragma mark - Queueing

-(void)addToHttpQueue:(NSDictionary*)dictionary endPoint:(NSString*)endPoint httpMethod:(NSString*)httpMethod {
    NSData *json = [Liquid toJSON:dictionary];
    LQQueue *queuedEvent = [[LQQueue alloc] initWithUrl:endPoint
                                         withHttpMethod:httpMethod
                                               withJSON:json];

    if (self.httpQueue.count >= self.queueSizeLimit) {
        LQLog(kLQLogLevelWarning, @"<Liquid> Queue exceeded its limit size (%ld). Removing oldest event from queue.", (long) self.queueSizeLimit);
        [self.httpQueue removeObjectAtIndex:0];
    }
    [self.httpQueue addObject:queuedEvent];
    [Liquid archiveQueue:self.httpQueue forToken:self.apiToken];
}

-(void)flush {
    dispatch_async(self.queue, ^{
        if (![self.device reachesInternet]) {
            LQLog(kLQLogLevelWarning, @"<Liquid> There's no Internet connection. Will try to deliver data points later.");
        } else {
            NSMutableArray *failedQueue = [NSMutableArray new];
            while (self.httpQueue.count > 0) {
                LQQueue *queuedHttp = [self.httpQueue firstObject];
                if ([[NSDate date] compare:[queuedHttp nextTryAfter]] > NSOrderedAscending) {
                    LQLog(kLQLogLevelHttp, @"<Liquid> Flushing: %@", [[NSString alloc] initWithData:queuedHttp.json encoding:NSUTF8StringEncoding]);
                    NSInteger res = [self sendData:queuedHttp.json
                                   toEndpoint:queuedHttp.url
                                  usingMethod:queuedHttp.httpMethod];
                    [self.httpQueue removeObject:queuedHttp];
                    if(res != LQQueueStatusOk) {
                        if([[queuedHttp numberOfTries] intValue] < kLQHttpMaxTries) {
                            if (res == LQQueueStatusUnauthorized) {
                                [queuedHttp incrementNumberOfTries];
                                [queuedHttp incrementNextTryDateIn:(kLQHttpUnreachableWait + [Liquid randomInt:kLQHttpUnreachableWait/2])];
                            }
                            if (res == LQQueueStatusRejected) {
                                [queuedHttp incrementNumberOfTries];
                                [queuedHttp incrementNextTryDateIn:(kLQHttpRejectedWait + [Liquid randomInt:kLQHttpRejectedWait/2])];
                            }
                            [failedQueue addObject:queuedHttp];
                        }
                    }
                } else {
                    [self.httpQueue removeObject:queuedHttp];
                    [failedQueue addObject:queuedHttp];
                    LQLog(kLQLogLevelInfoVerbose, @"<Liquid> Queued failed request is too recent. Waiting for a while to try again (%d/%d)", [[queuedHttp numberOfTries] intValue], kLQHttpMaxTries);
                }
            }
            [self.httpQueue addObjectsFromArray:failedQueue];
            [Liquid archiveQueue:self.httpQueue forToken:_apiToken];
        }
    });
}

- (void)startFlushTimer {
    //[self stopFlushTimer];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.flushInterval > 0 && self.timer == nil) {
            self.timer = [NSTimer scheduledTimerWithTimeInterval:self.flushInterval
                                                          target:self
                                                        selector:@selector(flush)
                                                        userInfo:nil
                                                         repeats:YES];
            LQLog(kLQLogLevelInfoVerbose, @"<Liquid> %@ started flush timer: %@", self, self.timer);
        }
    });
    
}

- (void)stopFlushTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.timer) {
            [self.timer invalidate];
            LQLog(kLQLogLevelInfoVerbose,@"<Liquid> %@ stopped flush timer: %@", self, self.timer);
        }
        self.timer = nil;
    });
}

#pragma mark - Resetting

+ (void)destroySingleton {
    sharedInstance.currentUser = nil;
    sharedInstance.currentSession = nil;
    sharedInstance.enterBackgroundTime = nil;
    sharedInstance.timer = nil;
    sharedInstance.httpQueue = nil;
    sharedInstance.loadedLiquidPackage = nil;
    sharedInstance.firstEventSent = NO;
    [sharedInstance veryFirstMoment];
}

+ (void)softReset {
    [LQLiquidPackage destroyCachedLiquidPackageForAllTokens];
    [LQUser destroyLastUserForAllTokens];
    [Liquid destroySingleton];
    [NSThread sleepForTimeInterval:0.2f];
    LQLog(kLQLogLevelInfo, @"<Liquid> Soft reset Liquid");
}

+ (void)hardResetForApiToken:(NSString *)token {
    [self softReset];
    [Liquid deleteFileIfExists:[Liquid liquidQueueFileForToken:token] error:nil];
    LQLog(kLQLogLevelInfo, @"<Liquid> Hard reset Liquid");
}

- (void)softReset {
    [Liquid softReset];
}

- (void)hardReset {
    [Liquid hardResetForApiToken:self.apiToken];
}

#pragma mark - Networking

- (NSInteger)sendData:(NSData *)data toEndpoint:(NSString *)endpoint usingMethod:(NSString *)method {
    NSURL *url = [NSURL URLWithString:endpoint];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:method];
    [request setValue:[NSString stringWithFormat:@"Token %@", self.apiToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:self.liquidUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.lqd.v1+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)[data length]] forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody:data];

    NSURLResponse *response;
    NSError *error = nil;
    NSData *responseData = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&error];
    NSString __unused *responseString = [[NSString alloc] initWithData:responseData
                                                     encoding:NSUTF8StringEncoding];

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (error) {
        if (error.code == NSURLErrorCannotFindHost || error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorNetworkConnectionLost) {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while sending data to server: Server is unreachable", (long)error.code);
            return LQQueueStatusUnreachable;
        } else if(error.code == NSURLErrorUserCancelledAuthentication || error.code == NSURLErrorUserAuthenticationRequired) {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while sending data to server: Unauthorized (check App Token)", (long)error.code);
            return LQQueueStatusUnauthorized;
        } else {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while sending data to server: Server error", (long)error.code);
            return LQQueueStatusRejected;
        }
    } else {
        LQLog(kLQLogLevelHttp, @"<Liquid> Response from server: %@", responseString);
        if(httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            return LQQueueStatusOk;
        } else {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while sending data to server: Server error", (long)httpResponse.statusCode);
            return LQQueueStatusRejected;
        }
    }
}

- (NSData *)getDataFromEndpoint:(NSString *)endpoint {
    NSURL *url = [NSURL URLWithString:endpoint];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:[NSString stringWithFormat:@"Token %@", self.apiToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:self.liquidUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.lqd.v1+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    
    NSURLResponse *response;
    NSError *error = nil;
    NSData *responseData = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&error];
    NSString __unused *responseString = [[NSString alloc] initWithData:responseData
                                                     encoding:NSUTF8StringEncoding];

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (error) {
        if (error.code == NSURLErrorCannotFindHost || error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorNetworkConnectionLost) {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while getting data from server: Server is unreachable", (long)error.code);
        } else if(error.code == NSURLErrorUserCancelledAuthentication || error.code == NSURLErrorUserAuthenticationRequired) {
            LQLog(kLQLogLevelError, @"<Liquid> Error (%ld) while getting data from server: Unauthorized (check App Token)", (long)error.code);
        } else {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while getting data from server: Server error", (long)error.code);
        }
        return nil;
    } else {
        LQLog(kLQLogLevelHttp, @"<Liquid> Response from server: %@", responseString);
        if(httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            return responseData;
        } else {
            LQLog(kLQLogLevelWarning, @"<Liquid> Error (%ld) while getting data from server: Server error", (long)httpResponse.statusCode);
            return nil;
        }
    }
}

#pragma mark - File Management

+(NSMutableArray*)unarchiveQueueForToken:(NSString*)apiToken {
    NSMutableArray *plistArray =  [NSKeyedUnarchiver unarchiveObjectWithFile:[Liquid liquidQueueFileForToken:apiToken]];
    if(plistArray == nil)
        plistArray = [NSMutableArray new];
    LQLog(kLQLogLevelData, @"<Liquid> Loading queue with %ld items from disk", (unsigned long)plistArray.count);
    return plistArray;
}

+(BOOL)archiveQueue:(NSArray *)queue forToken:(NSString*)apiToken {
    if (queue.count > 0) {
        LQLog(kLQLogLevelData, @"<Liquid> Saving queue with %ld items to disk", (unsigned long)queue.count);
        return [NSKeyedArchiver archiveRootObject:queue
                                           toFile:[Liquid liquidQueueFileForToken:apiToken]];
    } else {
        [Liquid deleteFileIfExists:[Liquid liquidQueueFileForToken:apiToken] error:nil];
        return FALSE;
    }
}

+(BOOL)deleteFileIfExists:(NSString *)fileName error:(NSError **)err {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:fileName];
    if (exists == YES) return [fm removeItemAtPath:fileName error:err];
    return exists;
}

+(NSString*)liquidQueueFileForToken:(NSString*)apiToken {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *liquidDirectory = [documentsDirectory stringByAppendingPathComponent:kLQDirectory];
    NSError *error;
    if (![[NSFileManager defaultManager] fileExistsAtPath:liquidDirectory])
        [[NSFileManager defaultManager] createDirectoryAtPath:liquidDirectory
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:&error];
    NSString *md5apiToken = [NSString md5ofString:apiToken];
    NSString *liquidFile = [liquidDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.queue", md5apiToken]];
    LQLog(kLQLogLevelPaths,@"<Liquid> File location %@", liquidFile);
    return liquidFile;
}

#pragma mark - Static Helpers

+ (id)fromJSON:(NSData *)data {
    if (!data) return nil;
    __autoreleasing NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data
                                                options:kNilOptions
                                                  error:&error];
    if (error != nil) {
        LQLog(kLQLogLevelError, @"<Liquid> Error parsing JSON: %@", [error localizedDescription]);
        return nil;
    }
    return result;
}

+ (NSData*)toJSON:(NSDictionary *)object {
    __autoreleasing NSError *error = nil;
    NSData *data = (id) [Liquid normalizeDataTypes:object];
    id result = [NSJSONSerialization dataWithJSONObject:data
                                                options:NSJSONWritingPrettyPrinted
                                                  error:&error];
    if (error != nil) {
        LQLog(kLQLogLevelError, @"<Liquid> Error creating JSON: %@", [error localizedDescription]);
        return nil;
    }
    return result;
}

+ (NSDictionary *)normalizeDataTypes:(NSDictionary *)dictionary {
    NSMutableDictionary *newDictionary = [NSMutableDictionary new];
    for (id key in dictionary) {
        id element = [dictionary objectForKey:key];
        if ([element isKindOfClass:[NSDate class]]) {
            [newDictionary setObject:[NSDateFormatter iso8601StringFromDate:element] forKey:key];
        } else if ([element isKindOfClass:[UIColor class]]) {
            [newDictionary setObject:[UIColor hexadecimalStringFromUIColor:element] forKey:key];
        } else if ([element isKindOfClass:[NSDictionary class]]) {
            [newDictionary setObject:[Liquid normalizeDataTypes:element] forKey:key];
        } else {
            [newDictionary setObject:element forKey:key];
        }
    }
    return newDictionary;
}

+ (NSUInteger)randomInt:(NSUInteger)max {
    int r = 0;
    if (arc4random_uniform != NULL) {
        r = arc4random_uniform ((int) max);
    } else {
        r = (arc4random() % max);
    }
    return (int) r;
}

@end
