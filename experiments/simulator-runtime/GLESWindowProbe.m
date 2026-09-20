// Real EAGL drawable presentation, checked in the composed window rather than its FBO.
#define GLES_SILENCE_DEPRECATION
#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>

@interface GLESProbeView : UIView
@end
@implementation GLESProbeView
+ (Class)layerClass { return CAEAGLLayer.class; }
@end

static const uint8_t colors[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}};
@interface GLESWindowDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) GLESProbeView *glView;
@property(nonatomic, strong) EAGLContext *context;
@property(nonatomic, strong) dispatch_semaphore_t renderRequest;
@property(nonatomic, strong) dispatch_semaphore_t renderDone;
@property(nonatomic) int requestedPhase;
@property(nonatomic) BOOL renderResult;
@property(nonatomic) GLuint framebuffer;
@property(nonatomic) GLuint renderbuffer;
@end
@implementation GLESWindowDelegate
- (BOOL)drawPhase:(int)phase {
    self.requestedPhase = phase;
    dispatch_semaphore_signal(self.renderRequest);
    dispatch_semaphore_wait(self.renderDone, DISPATCH_TIME_FOREVER);
    return self.renderResult;
}
- (BOOL)renderPhase:(int)phase {
    if (![EAGLContext setCurrentContext:self.context]) return NO;
    glBindFramebuffer(GL_FRAMEBUFFER, self.framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, self.renderbuffer);
    CAEAGLLayer *layer = (CAEAGLLayer *)self.glView.layer;
    layer.contentsScale = 2;
    layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking:@YES, kEAGLDrawablePropertyColorFormat:kEAGLColorFormatRGBA8};
    if (![self.context renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) return NO;
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.renderbuffer);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return NO;
    GLint width = 0, height = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
    if (width != (GLint)(self.glView.bounds.size.width * 2) || height != (GLint)(self.glView.bounds.size.height * 2)) return NO;
    glEnable(GL_SCISSOR_TEST);
    for (int quadrant = 0; quadrant < 4; quadrant++) {
        const uint8_t *color = colors[(quadrant + phase) % 4];
        glScissor((quadrant % 2) * width / 2, (1 - quadrant / 2) * height / 2, width / 2, height / 2);
        glClearColor(color[0] / 255.0f, color[1] / 255.0f, color[2] / 255.0f, 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    // Presentation must copy the whole drawable and preserve the caller's GL state.
    glViewport(7, 11, 80, 64); glScissor(3, 5, 10, 12);
    BOOL presented = [self.context presentRenderbuffer:GL_RENDERBUFFER];
    GLint viewport[4], scissor[4], read = 0, draw = 0, renderbuffer = 0;
    glGetIntegerv(GL_VIEWPORT, viewport); glGetIntegerv(GL_SCISSOR_BOX, scissor);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
    BOOL state = glIsEnabled(GL_SCISSOR_TEST) && viewport[0] == 7 && viewport[1] == 11 && viewport[2] == 80 && viewport[3] == 64 &&
        scissor[0] == 3 && scissor[1] == 5 && scissor[2] == 10 && scissor[3] == 12 &&
        read == self.framebuffer && draw == self.framebuffer && renderbuffer == self.renderbuffer;
    GLenum error = glGetError();
    fprintf(stderr, "[gles-window] phase=%d size=%dx%d presented=%d state=%d error=%x\n", phase, width, height, presented, state, error);
    return presented && state && !error;
}
- (BOOL)capturePhase:(int)phase {
    IOSurfaceRef (*copySurface)(UIWindow *) = dlsym(RTLD_DEFAULT, "IOSUseCopyPresentedWindowSurface");
    IOSurfaceRef surface = copySurface ? copySurface(self.window) : NULL;
    if (!surface) return NO;
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) { CFRelease(surface); return NO; }
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    CGRect frame = self.glView.frame;
    BOOL correct = YES;
    for (int quadrant = 0; quadrant < 4; quadrant++) {
        int x = frame.origin.x + frame.size.width * (quadrant % 2 ? 0.75 : 0.25);
        int y = frame.origin.y + frame.size.height * (quadrant / 2 ? 0.75 : 0.25);
        const uint8_t *pixel = base + y * stride + x * 4;
        const uint8_t *expected = colors[(quadrant + phase) % 4];
        BOOL matches = abs(pixel[2] - expected[0]) <= 3 && abs(pixel[1] - expected[1]) <= 3 && abs(pixel[0] - expected[2]) <= 3 && pixel[3] == 255;
        fprintf(stderr, "[gles-window] phase=%d quadrant=%d RGB=%u,%u,%u matches=%d\n", phase, quadrant, pixel[2], pixel[1], pixel[0], matches);
        correct &= matches;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate((void *)base, IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), 8, stride,
                                               colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"gles-window-%d.png", phase]];
    if (image) {
        correct &= [UIImagePNGRepresentation([UIImage imageWithCGImage:image]) writeToFile:path atomically:YES];
        CGImageRelease(image);
    } else correct = NO;
    if (bitmap) CGContextRelease(bitmap);
    CGColorSpaceRelease(colorSpace); IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL); CFRelease(surface);
    return correct;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    self.glView = [[GLESProbeView alloc] initWithFrame:CGRectMake(30, 120, 240, 160)];
    [self.window.rootViewController.view addSubview:self.glView];
    [self.window makeKeyAndVisible];
    self.renderRequest = dispatch_semaphore_create(0);
    self.renderDone = dispatch_semaphore_create(0);
    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (![EAGLContext setCurrentContext:self.context]) exit(100);
    GLuint framebuffer = 0, renderbuffer = 0;
    glGenFramebuffers(1, &framebuffer); glGenRenderbuffers(1, &renderbuffer);
    self.framebuffer = framebuffer; self.renderbuffer = renderbuffer;
    [EAGLContext setCurrentContext:nil];
    // Match an app-owned long-lived rendering thread: no run loop and no
    // per-frame autorelease-pool drain that could commit CA on our behalf.
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            for (;;) {
                dispatch_semaphore_wait(self.renderRequest, DISPATCH_TIME_FOREVER);
                if (self.requestedPhase < 0) {
                    [EAGLContext setCurrentContext:self.context];
                    glDeleteRenderbuffers(1, &renderbuffer); glDeleteFramebuffers(1, &framebuffer);
                    [EAGLContext setCurrentContext:nil];
                    break;
                }
                self.renderResult = [self renderPhase:self.requestedPhase];
                dispatch_semaphore_signal(self.renderDone);
            }
        }
        dispatch_semaphore_signal(self.renderDone);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (![self drawPhase:0]) exit(101);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (![self capturePhase:0]) exit(102);
            self.glView.frame = CGRectMake(50, 360, 160, 100);
            if (![self drawPhase:1]) exit(103);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (![self capturePhase:1]) exit(104);
                self.requestedPhase = -1;
                dispatch_semaphore_signal(self.renderRequest);
                dispatch_semaphore_wait(self.renderDone, DISPATCH_TIME_FOREVER);
                fprintf(stderr, "[gles-window] drawable child layers after deletion=%lu\n", (unsigned long)self.glView.layer.sublayers.count);
                if (self.glView.layer.sublayers.count) exit(105);
                [EAGLContext setCurrentContext:nil];
                exit(0);
            });
        });
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(106); });
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(GLESWindowDelegate.class));
    }
}
