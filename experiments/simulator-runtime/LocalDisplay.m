// Fixed offscreen display metadata; this does not provide a compositor or input.
#import <UIKit/UIKit.h>
#include <stdbool.h>
#include <stdio.h>

@interface NSObject (LocalDisplayAPI)
+ (id)_virtualDisplayConfigurationWithIdentifier:(NSString *)identifier;
- (id)initWithConfiguration:(id)configuration;
- (id)_initWithWidth:(NSUInteger)width height:(NSUInteger)height scale:(NSUInteger)scale
        refreshRate:(double)rate gamut:(NSUInteger)gamut hdr:(NSUInteger)hdr;
- (void)setCurrentMode:(id)current preferredMode:(id)preferred otherModes:(NSSet *)other;
- (void)setPixelSize:(CGSize)pixels nativeBounds:(CGRect)nativeBounds bounds:(CGRect)bounds;
- (void)setUIKitMainLike;
- (id)buildConfigurationWithError:(NSError **)error;
- (void)_updateDisplayConfiguration:(id)configuration;
@end

static id localConfiguration;
static const NSUInteger pixelWidth = 1206, pixelHeight = 2622, displayScale = 3;

id IOSUseLocalDisplayConfiguration(void) { return localConfiguration; }

__attribute__((constructor)) static void configureDisplay(void) {
    id initial = [NSClassFromString(@"FBSDisplayConfiguration")
                  _virtualDisplayConfigurationWithIdentifier:@"iosuse.offscreen"];
    id builder = [[NSClassFromString(@"FBSDisplayConfigurationBuilder") alloc] initWithConfiguration:initial];
    id mode = [[NSClassFromString(@"FBSDisplayMode") alloc]
               _initWithWidth:pixelWidth height:pixelHeight scale:displayScale refreshRate:60 gamut:1 hdr:0];
    [builder setCurrentMode:mode preferredMode:mode otherModes:[NSSet set]];
    [builder setPixelSize:CGSizeMake(pixelWidth, pixelHeight)
            nativeBounds:CGRectMake(0, 0, pixelWidth, pixelHeight)
                  bounds:CGRectMake(0, 0, pixelWidth / displayScale, pixelHeight / displayScale)];
    [builder setUIKitMainLike];
    NSError *error = nil;
    localConfiguration = [builder buildConfigurationWithError:&error];
    if (!localConfiguration) {
        NSLog(@"[local-display] invalid configuration: %@", error);
        exit(38);
    }
}

extern bool BKSDisplayServicesStart(void);
extern int BKSDisplayServicesGetMainScreenInfo(float *, float *, float *, float *);
extern void GSSetMainScreenInfo(double, double, float, float);

static bool startDisplay(void) {
    GSSetMainScreenInfo(pixelWidth, pixelHeight, displayScale, 460);
    // UIKit creates a zero-sized fallback screen without an initial display context.
    // Supply the real FBS configuration through its own update implementation.
    [UIScreen.mainScreen _updateDisplayConfiguration:localConfiguration];
    fprintf(stderr, "[local-display] offscreen screen 402x874 @3\n");
    return true;
}

static int screenInfo(float *width, float *height, float *scale, float *pitch) {
    if (width) *width = pixelWidth;
    if (height) *height = pixelHeight;
    if (scale) *scale = displayScale;
    if (pitch) *pitch = 460;
    return 0;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} replacements[] = {
    {(void *)startDisplay, (void *)BKSDisplayServicesStart},
    {(void *)screenInfo, (void *)BKSDisplayServicesGetMainScreenInfo}
};
