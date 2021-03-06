//
//  NSData+LQData.m
//  Liquid
//
//  Created by Liquid Data Intelligence, S.A. (lqd.io) on 15/05/14.
//  Copyright (c) Liquid Data Intelligence, S.A. All rights reserved.
//

#import "NSData+LQData.h"
#import "LQHelpers.h"
#import "LQDefaults.h"
#import <CommonCrypto/CommonDigest.h>

@implementation NSData (LQData)

+ (NSData *)randomDataOfLength:(size_t)length {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes);
    return data;
}

- (NSString *)hexadecimalString {
    NSMutableString *hexToken;
    const unsigned char *iterator = (const unsigned char *) [self bytes];
    if (iterator) {
        hexToken = [[NSMutableString alloc] init];
        for (NSInteger i = 0; i < self.length; i++) {
            [hexToken appendString:[NSString stringWithFormat:@"%02lx", (unsigned long) iterator[i]]];
        }
        return hexToken;
    }
    return nil;
}

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
    NSData *data = (id) [LQHelpers normalizeDataTypes:object];
    id result = [NSJSONSerialization dataWithJSONObject:data
                                                options:NSJSONWritingPrettyPrinted
                                                  error:&error];
    if (error != nil) {
        LQLog(kLQLogLevelError, @"<Liquid> Error creating JSON: %@", [error localizedDescription]);
        return nil;
    }
    return result;
}

- (NSString *)md5digest {
    return [[self class] md5digest:self];
}

+ (NSString *)md5digest:(NSData *)input {
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(input.bytes, (unsigned int)input.length, result);
    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];
    for (int i = 0; i<CC_MD5_DIGEST_LENGTH; i++) {
        [ret appendFormat:@"%02x",result[i]];
    }
    return ret;
}

@end
