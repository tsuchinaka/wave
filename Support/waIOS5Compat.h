#ifndef WA_IOS5_COMPAT_H
#define WA_IOS5_COMPAT_H

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#ifndef NS_ENUM
#if defined(__has_feature) && __has_feature(objc_fixed_enum)
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#else
#define NS_ENUM(_type, _name) _type _name; enum
#endif
#endif
#ifndef NS_OPTIONS
#define NS_OPTIONS(_type, _name) NS_ENUM(_type, _name)
#endif

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000

// iOS 5 SDK defines YES/NO as (BOOL)1/(BOOL)0, which breaks @YES/@NO boxing.
#undef YES
#undef NO
#define YES 1
#define NO  0

#ifndef NSTextAlignmentLeft
#define NSTextAlignment UITextAlignment
#define NSTextAlignmentLeft UITextAlignmentLeft
#define NSTextAlignmentCenter UITextAlignmentCenter
#define NSTextAlignmentRight UITextAlignmentRight
#endif

#ifndef NSLineBreakByWordWrapping
#define NSLineBreakMode UILineBreakMode
#define NSLineBreakByWordWrapping UILineBreakModeWordWrap
#define NSLineBreakByCharWrapping UILineBreakModeCharacterWrap
#define NSLineBreakByClipping UILineBreakModeClip
#define NSLineBreakByTruncatingHead UILineBreakModeHeadTruncation
#define NSLineBreakByTruncatingTail UILineBreakModeTailTruncation
#define NSLineBreakByTruncatingMiddle UILineBreakModeMiddleTruncation
#endif

@interface NSArray (waIOS5Subscript)
- (id)objectAtIndexedSubscript:(NSUInteger)idx;
@end

@interface NSMutableArray (waIOS5Subscript)
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)idx;
@end

@interface NSDictionary (waIOS5Subscript)
- (id)objectForKeyedSubscript:(id)key;
@end

@interface NSMutableDictionary (waIOS5Subscript)
- (void)setObject:(id)obj forKeyedSubscript:(id)key;
@end

#endif

#endif
#endif
