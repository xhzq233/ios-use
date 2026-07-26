#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Narrow selector declarations used by the pinned Objective-C PlayTools
/// sources.  Keeping this private bridge avoids an Objective-C/Swift generated
/// header build cycle inside the single mixed framework.
@interface PlaySettings : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) NSString *deviceModel;
@property(nonatomic, readonly) NSString *oemID;
@property(nonatomic, readonly) double customScaler;
@property(nonatomic, readonly) BOOL adaptiveDisplay;
@property(nonatomic, readonly) BOOL inverseScreenValues;
@property(nonatomic, readonly) BOOL resizableWindow;
@property(nonatomic, readonly) BOOL notch;
@property(nonatomic, readonly) NSInteger windowFixMethod;
@property(nonatomic, readonly) BOOL playChain;
@property(nonatomic, readonly) BOOL playChainDebugging;
@property(nonatomic, readonly) BOOL blockSleepSpamming;
@property(nonatomic, readonly) BOOL checkMicPermissionSync;
@property(nonatomic, readonly) BOOL limitMotionUpdateFrequency;
@property(nonatomic, readonly) BOOL disableBuiltinMouse;
@property(nonatomic, readonly) BOOL ignoreUnityKeyboardInitializationError;
@end

@interface PlayInfo : NSObject
+ (BOOL)isUnrealEngine;
@end

@interface PlayKeychain : NSObject
+ (OSStatus)copyMatching:(NSDictionary *)query
                  result:(CFTypeRef _Nullable * _Nullable)result;
+ (OSStatus)add:(NSDictionary *)attributes
         result:(CFTypeRef _Nullable * _Nullable)result;
+ (OSStatus)update:(NSDictionary *)query
attributesToUpdate:(NSDictionary *)attributes;
+ (OSStatus)delete:(NSDictionary *)query;
+ (SecKeyRef _Nullable)keyCreateRandomKey:(NSDictionary *)parameters
                                    error:
    (CFErrorRef _Nullable * _Nullable)error CF_RETURNS_RETAINED;
+ (OSStatus)keyGeneratePair:(NSDictionary *)parameters
                  publicKey:
    (SecKeyRef _Nullable * _Nullable)publicKey
                 privateKey:
    (SecKeyRef _Nullable * _Nullable)privateKey;
+ (void)debugLogger:(NSString *)message;
+ (NSDictionary<NSString *, id> *)storageIdentity;
@end

@interface PlayCover : NSObject
+ (void)launch;
+ (void)initMenuWithMenu:(NSObject *)menu;
@end

@interface PlayScreen : NSObject
+ (CGRect)frame:(CGRect)rect;
+ (CGRect)bounds:(CGRect)rect;
+ (CGRect)nativeBounds:(CGRect)rect;
+ (NSInteger)width:(NSInteger)size;
+ (NSInteger)height:(NSInteger)size;
+ (CGSize)sizeAspectRatio:(CGSize)size;
+ (CGRect)frameReversedDefault:(CGRect)rect;
+ (CGRect)frameDefault:(CGRect)rect;
+ (CGRect)boundsDefault:(CGRect)rect;
+ (CGRect)nativeBoundsDefault:(CGRect)rect;
+ (CGSize)sizeAspectRatioDefault:(CGSize)size;
+ (CGRect)frameInternalDefault:(CGRect)rect;
+ (CGRect)boundsResizable:(CGRect)rect;
@end

@interface IOSUsePlayTouchBridge : NSObject
+ (NSNumber * _Nullable)sendAtPoint:(CGPoint)point
                              phase:(NSInteger)phase
                            touchID:(NSNumber * _Nullable)touchID
                             window:(UIWindow *)window
                               view:(UIView *)view;
@end

NS_ASSUME_NONNULL_END
