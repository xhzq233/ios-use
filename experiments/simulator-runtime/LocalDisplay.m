// Fixed offscreen display metadata; this does not provide a compositor or input.
#import <UIKit/UIKit.h>
#include <stdbool.h>
#include <stdio.h>

@interface NSObject (LocalDisplayAPI)
+ (id)_virtualDisplayConfigurationWithIdentifier:(NSString *)identifier;
+ (id)mainDisplay;
- (id)initWithCADisplay:(id)display isMainDisplay:(BOOL)main;
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
static bool startDisplay(void);

id IOSUseLocalDisplayConfiguration(void) { return localConfiguration; }

static void configureDisplay(void) {
    id display = [NSClassFromString(@"CADisplay") mainDisplay];
    // FBS "virtualized" metadata deliberately has no CADisplay and crashes
    // screen-bound MTKView display links. Describe the actual local CA display.
    id initial = display ? [[NSClassFromString(@"FBSDisplayConfiguration") alloc]
                            initWithCADisplay:display isMainDisplay:YES]
                         : [NSClassFromString(@"FBSDisplayConfiguration")
                            _virtualDisplayConfigurationWithIdentifier:@"LCD"];
    id builder = [[NSClassFromString(@"FBSDisplayConfigurationBuilder") alloc] initWithConfiguration:initial];
    id mode = [[NSClassFromString(@"FBSDisplayMode") alloc]
               _initWithWidth:pixelWidth height:pixelHeight scale:displayScale refreshRate:30 gamut:1 hdr:0];
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
    if (!localConfiguration) configureDisplay();
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

extern int originalUIApplicationMain(int, char **, NSString *, NSString *) __asm__("_UIApplicationMain");
static int applicationMain(int argc, char **argv, NSString *principal, NSString *delegate) {
    // AppDelegate stored-property initializers can create a window before BKS
    // starts. Wait until +load has finished, then supply its screen before main.
    startDisplay();
    return originalUIApplicationMain(argc, argv, principal, delegate);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} replacements[] = {
    {(void *)applicationMain, (void *)originalUIApplicationMain},
    {(void *)startDisplay, (void *)BKSDisplayServicesStart},
    {(void *)screenInfo, (void *)BKSDisplayServicesGetMainScreenInfo}
};
