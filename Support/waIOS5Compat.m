#import "waIOS5Compat.h"

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 60000

@implementation NSArray (waIOS5Subscript)
- (id)objectAtIndexedSubscript:(NSUInteger)idx {
    return [self objectAtIndex:idx];
}
@end

@implementation NSMutableArray (waIOS5Subscript)
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)idx {
    if (idx == self.count) [self addObject:obj];
    else [self replaceObjectAtIndex:idx withObject:obj];
}
@end

@implementation NSDictionary (waIOS5Subscript)
- (id)objectForKeyedSubscript:(id)key {
    return [self objectForKey:key];
}
@end

@implementation NSMutableDictionary (waIOS5Subscript)
- (void)setObject:(id)obj forKeyedSubscript:(id)key {
    if (!key) return;
    if (obj) [self setObject:obj forKey:key];
    else [self removeObjectForKey:key];
}
@end

#endif
