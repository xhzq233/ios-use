// Experimental EAGL and BGRA CoreVideo texture bridge to the runtime's ANGLE.
// Compiled without ARC: init-family swizzles and CF create/release ownership are explicit.
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/ES2/glext.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *newFunction; const void *oldFunction; } \
    interpose_##replacement = { (const void *)&replacement, (const void *)&original }

static void *angleLibrary, *display, *config;
static void missingFunction(const char *name) {
    fprintf(stderr, "[angle-adapter] unsupported GLES entry point: %s\n", name);
    abort();
}
#include "GLESForwarders.inc"

#define EGL_FUNCTION(name, result, ...) static result (*egl##name)(__VA_ARGS__)
EGL_FUNCTION(GetPlatformDisplayEXT, void *, unsigned, void *, const int *);
EGL_FUNCTION(Initialize, unsigned, void *, int *, int *);
EGL_FUNCTION(ChooseConfig, unsigned, void *, const int *, void **, int, int *);
EGL_FUNCTION(BindAPI, unsigned, unsigned);
EGL_FUNCTION(CreateContext, void *, void *, void *, void *, const int *);
EGL_FUNCTION(DestroyContext, unsigned, void *, void *);
EGL_FUNCTION(CreateWindowSurface, void *, void *, void *, void *, const int *);
EGL_FUNCTION(SwapBuffers, unsigned, void *, void *);
EGL_FUNCTION(CreatePbufferSurface, void *, void *, void *, const int *);
EGL_FUNCTION(CreatePbufferFromClientBuffer, void *, void *, unsigned, void *, void *, const int *);
EGL_FUNCTION(DestroySurface, unsigned, void *, void *);
EGL_FUNCTION(MakeCurrent, unsigned, void *, void *, void *, void *);
EGL_FUNCTION(GetCurrentContext, void *, void);
EGL_FUNCTION(GetCurrentSurface, void *, int);
EGL_FUNCTION(GetCurrentDisplay, void *, void);
EGL_FUNCTION(GetError, int, void);
EGL_FUNCTION(BindTexImage, unsigned, void *, void *, int);
EGL_FUNCTION(ReleaseTexImage, unsigned, void *, void *, int);

enum { EGL_NONE = 0x3038, EGL_BACK_BUFFER = 0x3084, EGL_DRAW = 0x3059, EGL_READ = 0x305A };
static const char contextKey, sharegroupKey;
static BOOL (*originalSetCurrent)(id, SEL, EAGLContext *);
static id (*originalInitAPI)(id, SEL, EAGLRenderingAPI);
static id (*originalInitShared)(id, SEL, EAGLRenderingAPI, EAGLSharegroup *);

@interface RuntimeANGLEGroup : NSObject {
@public void *anchor;
    NSMutableDictionary *drawables;
}
@end
@implementation RuntimeANGLEGroup
- (void)dealloc { [drawables release]; if (anchor) eglDestroyContext(display, anchor); [super dealloc]; }
@end

@interface RuntimeANGLEContext : NSObject {
@public void *context, *surface;
    RuntimeANGLEGroup *group;
    GLuint presentationReadFramebuffer;
}
@end
@implementation RuntimeANGLEContext
- (void)dealloc {
    if (surface) eglDestroySurface(display, surface);
    if (context) eglDestroyContext(display, context);
    [group release];
    [super dealloc];
}
@end

static BOOL initializeDisplay(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int attributes[] = {0x3203, 0x3489, EGL_NONE}; // ANGLE type Metal
        display = eglGetPlatformDisplayEXT(0x3202, NULL, attributes);
        if (!eglInitialize(display, NULL, NULL)) { display = NULL; return; }
        int options[] = {0x3033, 5, 0x3040, 0x44, 0x3024, 8, 0x3023, 8,
                         0x3022, 8, 0x3021, 8, EGL_NONE}; // pbuffer + window, ES 2/3, RGBA8
        int count = 0;
        if (!eglChooseConfig(display, options, &config, 1, &count) || !count) config = NULL;
    });
    return display && config;
}

static id attachContext(EAGLContext *object, EAGLRenderingAPI api) {
    if (!object || objc_getAssociatedObject(object, &contextKey)) return object;
    if ((api != 2 && api != 3) || !initializeDisplay()) {
        fprintf(stderr, "[angle-adapter] context initialization failed API=%lu EGL=%x\n", (unsigned long)api, eglGetError());
        [object release]; return nil;
    }
    eglBindAPI(0x30A0);
    int attributes[] = {0x3098, (int)api, EGL_NONE};
    RuntimeANGLEContext *state = [RuntimeANGLEContext new];
    @synchronized (object.sharegroup) {
        RuntimeANGLEGroup *group = objc_getAssociatedObject(object.sharegroup, &sharegroupKey);
        if (!group) {
            group = [[RuntimeANGLEGroup alloc] init];
            group->drawables = [NSMutableDictionary new];
            group->anchor = eglCreateContext(display, config, NULL, attributes);
            objc_setAssociatedObject(object.sharegroup, &sharegroupKey, group, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [group release];
        }
        state->group = [group retain];
        state->context = group->anchor ? eglCreateContext(display, config, group->anchor, attributes) : NULL;
    }
    int surfaceAttributes[] = {0x3057, 1, 0x3056, 1, EGL_NONE};
    state->surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
    if (!state->context || !state->surface) {
        fprintf(stderr, "[angle-adapter] EGL context creation failed error=%x\n", eglGetError());
        [state release]; [object release]; return nil;
    }
    objc_setAssociatedObject(object, &contextKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state release];
    fprintf(stderr, "[angle-adapter] EAGL API=%lu connected to Metal\n", (unsigned long)api);
    return object;
}
static id initAPI(id self, SEL cmd, EAGLRenderingAPI api) {
    return attachContext(originalInitAPI(self, cmd, api), api);
}
static id initShared(id self, SEL cmd, EAGLRenderingAPI api, EAGLSharegroup *group) {
    return attachContext(originalInitShared(self, cmd, api, group), api);
}
static BOOL setCurrent(id self, SEL cmd, EAGLContext *context) {
    RuntimeANGLEContext *state = objc_getAssociatedObject(context, &contextKey);
    if (context && !state) return NO;
    if (!display && !context) return originalSetCurrent(self, cmd, nil);
    if (!eglMakeCurrent(display, state ? state->surface : NULL,
                        state ? state->surface : NULL, state ? state->context : NULL)) return NO;
    return originalSetCurrent(self, cmd, context);
}

// Internal texture maintenance changes only EGL current state, restoring it before
// returning. Callers still serialize use of an EAGL context, as CoreVideo requires.
typedef struct { void *display, *context, *draw, *read; } EGLCurrent;
static EGLCurrent saveCurrent(void) {
    return (EGLCurrent){eglGetCurrentDisplay(), eglGetCurrentContext(),
        eglGetCurrentSurface(EGL_DRAW), eglGetCurrentSurface(EGL_READ)};
}
static void restoreCurrent(EGLCurrent current) {
    eglMakeCurrent(current.display ?: display, current.draw, current.read, current.context);
}

// A retained app renderbuffer is copied on-GPU into ANGLE's CAMetalLayer.
// The existing CA compositor owns refresh and forwards its composed IOSurfaces.
@interface RuntimeANGLEDrawable : NSObject {
@public CAMetalLayer *layer;
    void *surface;
    GLsizei width, height;
}
@end
@implementation RuntimeANGLEDrawable
- (void)dealloc {
    if (surface) eglDestroySurface(display, surface);
    [layer removeFromSuperlayer]; [layer release];
    [super dealloc];
}
@end

static BOOL renderbufferStorage(EAGLContext *self, SEL cmd, NSUInteger target, id<EAGLDrawable> drawable) {
    RuntimeANGLEContext *state = objc_getAssociatedObject(self, &contextKey);
    if (!state || EAGLContext.currentContext != self || target != GL_RENDERBUFFER) return NO;
    GLint name = 0; angle_glGetIntegerv(GL_RENDERBUFFER_BINDING, &name);
    if (!name) return NO;
    if (!drawable) {
        @synchronized (state->group) { [state->group->drawables removeObjectForKey:@(name)]; }
        angle_glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 0, 0);
        return YES;
    }
    if (![(id)drawable isKindOfClass:CAEAGLLayer.class]) return NO;
    CALayer *parent = (CALayer *)drawable;
    GLsizei width = (GLsizei)llround(parent.bounds.size.width * parent.contentsScale);
    GLsizei height = (GLsizei)llround(parent.bounds.size.height * parent.contentsScale);
    if (width <= 0 || height <= 0) return NO;
    NSString *color = drawable.drawableProperties[kEAGLDrawablePropertyColorFormat] ?: kEAGLColorFormatRGBA8;
    GLenum storageFormat = [color isEqual:kEAGLColorFormatRGBA8] ? GL_RGBA8 :
        [color isEqual:kEAGLColorFormatRGB565] ? GL_RGB565 : 0;
    if (!storageFormat) {
        fprintf(stderr, "[angle-adapter] unsupported drawable color format=%s\n", color.UTF8String);
        return NO;
    }
    @synchronized (state->group) {
        RuntimeANGLEDrawable *output = state->group->drawables[@(name)];
        if (output && output->layer.superlayer != parent) {
            [state->group->drawables removeObjectForKey:@(name)]; output = nil;
        }
        BOOL created = output == nil;
        if (created) {
            output = [[RuntimeANGLEDrawable alloc] init];
            output->layer = [CAMetalLayer new];
        }
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        output->layer.frame = parent.bounds;
        output->layer.contentsScale = parent.contentsScale;
        output->layer.opaque = parent.opaque;
        output->layer.drawableSize = CGSizeMake(width, height);
        if (created) [parent addSublayer:output->layer];
        [CATransaction commit];
        if (created) {
            int attributes[] = {EGL_NONE};
            output->surface = eglCreateWindowSurface(display, config, output->layer, attributes);
            if (!output->surface) {
                fprintf(stderr, "[angle-adapter] window surface creation failed EGL=%x\n", eglGetError());
                [output release];
                return NO;
            }
            state->group->drawables[@(name)] = output;
        }
        output->width = width; output->height = height;
        if (created) [output release];
    }
    angle_glRenderbufferStorage(GL_RENDERBUFFER, storageFormat, width, height);
    GLint actualWidth = 0, actualHeight = 0;
    angle_glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &actualWidth);
    angle_glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &actualHeight);
    fprintf(stderr, "[angle-adapter] drawable storage=%dx%d allocated=%dx%d\n", width, height, actualWidth, actualHeight);
    return width == actualWidth && height == actualHeight;
}

static BOOL presentRenderbuffer(EAGLContext *self, SEL cmd, NSUInteger target) {
    RuntimeANGLEContext *state = objc_getAssociatedObject(self, &contextKey);
    if (!state || EAGLContext.currentContext != self || target != GL_RENDERBUFFER) return NO;
    GLint name = 0; angle_glGetIntegerv(GL_RENDERBUFFER_BINDING, &name);
    RuntimeANGLEDrawable *output;
    @synchronized (state->group) { output = [state->group->drawables[@(name)] retain]; }
    if (!output) return NO;
    EGLCurrent previous = saveCurrent();
    GLint read = 0, draw = 0;
    angle_glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
    angle_glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
    BOOL scissor = angle_glIsEnabled(GL_SCISSOR_TEST);
    BOOL success = eglMakeCurrent(display, output->surface, output->surface, state->context);
    if (success) {
        if (!state->presentationReadFramebuffer) angle_glGenFramebuffers(1, &state->presentationReadFramebuffer);
        angle_glBindFramebuffer(GL_READ_FRAMEBUFFER, state->presentationReadFramebuffer);
        angle_glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, name);
        angle_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        success = angle_glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
            angle_glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        if (success) {
            angle_glDisable(GL_SCISSOR_TEST);
            angle_glBlitFramebuffer(0, 0, output->width, output->height, 0, 0, output->width, output->height,
                                    GL_COLOR_BUFFER_BIT, GL_NEAREST);
            success = eglSwapBuffers(display, output->surface);
        }
        // Do not keep an app renderbuffer alive through our private framebuffer.
        angle_glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, 0);
        if (scissor) angle_glEnable(GL_SCISSOR_TEST);
        angle_glBindFramebuffer(GL_READ_FRAMEBUFFER, read);
        angle_glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw);
        restoreCurrent(previous);
    }
    // App-owned rendering threads may never run a CFRunLoop or drain a pool.
    // Publish their implicit layer transaction; UIKit retains its main-loop commit.
    if (success && !NSThread.isMainThread) [CATransaction flush];
    if (!success) fprintf(stderr, "[angle-adapter] drawable presentation failed EGL=%x\n", eglGetError());
    [output release];
    return success;
}

static void (*angleDeleteRenderbuffers)(GLsizei, const GLuint *);
static void deleteRenderbuffers(GLsizei count, const GLuint *names) {
    RuntimeANGLEContext *state = objc_getAssociatedObject(EAGLContext.currentContext, &contextKey);
    if (state) @synchronized (state->group) {
        for (GLsizei i = 0; i < count; i++) [state->group->drawables removeObjectForKey:@(names[i])];
    }
    angleDeleteRenderbuffers(count, names);
}
INTERPOSE(deleteRenderbuffers, glDeleteRenderbuffers);

@interface RuntimeANGLECache : NSObject {
@public EAGLContext *owner;
}
@end
@implementation RuntimeANGLECache
- (void)dealloc { [owner release]; [super dealloc]; }
@end

static NSMapTable *bufferTextures;
static NSRecursiveLock *textureLock;
@interface RuntimeANGLETexture : NSObject {
@public RuntimeANGLECache *cache;
    CVPixelBufferRef buffer;
    void *surface;
    GLuint name;
    BOOL bound;
}
- (BOOL)setBound:(BOOL)value;
@end
@implementation RuntimeANGLETexture
- (BOOL)setBound:(BOOL)value {
    if (bound == value) return YES;
    RuntimeANGLEContext *state = objc_getAssociatedObject(cache->owner, &contextKey);
    EGLCurrent previous = saveCurrent();
    if (!eglMakeCurrent(display, state->surface, state->surface, state->context)) {
        fprintf(stderr, "[angle-adapter] texture context unavailable error=%x\n", eglGetError());
        return NO;
    }
    GLint binding = 0;
    angle_glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding);
    angle_glBindTexture(GL_TEXTURE_2D, name);
    BOOL success = value ? eglBindTexImage(display, surface, EGL_BACK_BUFFER)
                        : eglReleaseTexImage(display, surface, EGL_BACK_BUFFER);
    angle_glBindTexture(GL_TEXTURE_2D, binding);
    if (success) bound = value;
    else fprintf(stderr, "[angle-adapter] texture binding=%d failed EGL=%x\n", value, eglGetError());
    restoreCurrent(previous);
    return success;
}
- (void)dealloc {
    [textureLock lock];
    NSHashTable *textures = [bufferTextures objectForKey:(id)buffer];
    [textures removeObject:self];
    if (!textures.count) [bufferTextures removeObjectForKey:(id)buffer];
    [textureLock unlock];
    if (surface) {
        [self setBound:NO];
        RuntimeANGLEContext *state = objc_getAssociatedObject(cache->owner, &contextKey);
        EGLCurrent previous = saveCurrent();
        if (eglMakeCurrent(display, state->surface, state->surface, state->context))
            angle_glDeleteTextures(1, &name);
        eglDestroySurface(display, surface);
        restoreCurrent(previous);
    }
    if (buffer) CFRelease(buffer);
    [cache release]; [super dealloc];
}
@end

static CVReturn createCache(CFAllocatorRef allocator, CFDictionaryRef attributes,
                            EAGLContext *context, CFDictionaryRef textureAttributes,
                            CVOpenGLESTextureCacheRef *out) {
    *out = NULL;
    if (!objc_getAssociatedObject(context, &contextKey)) return kCVReturnInvalidArgument;
    RuntimeANGLECache *cache = [RuntimeANGLECache new];
    cache->owner = [context retain];
    *out = (CVOpenGLESTextureCacheRef)cache;
    return kCVReturnSuccess;
}
INTERPOSE(createCache, CVOpenGLESTextureCacheCreate);

static CVReturn createTexture(CFAllocatorRef allocator, CVOpenGLESTextureCacheRef cacheRef,
                              CVImageBufferRef image, CFDictionaryRef attributes,
                              GLenum target, GLint internalFormat, GLsizei width, GLsizei height,
                              GLenum format, GLenum type, size_t plane, CVOpenGLESTextureRef *out) {
    *out = NULL;
    RuntimeANGLECache *cache = (id)cacheRef;
    if (target != GL_TEXTURE_2D || internalFormat != GL_RGBA || type != GL_UNSIGNED_BYTE || plane != 0 ||
        (format != GL_BGRA && format != GL_RGBA) || CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_32BGRA ||
        width != CVPixelBufferGetWidth(image) || height != CVPixelBufferGetHeight(image) || !CVPixelBufferGetIOSurface(image)) {
        fprintf(stderr, "[angle-adapter] unsupported CV texture target=%x internal=%x format=%x type=%x plane=%zu\n", target, internalFormat, format, type, plane);
        return kCVReturnPixelBufferNotOpenGLCompatible;
    }
    RuntimeANGLETexture *texture = [RuntimeANGLETexture new];
    texture->cache = [cache retain]; texture->buffer = (CVPixelBufferRef)CFRetain(image);
    int options[] = {0x3057, width, 0x3056, height, 0x3080, 0x305E, 0x3081, 0x305F,
                     0x345C, GL_UNSIGNED_BYTE, 0x345D, GL_BGRA, 0x345A, 0, EGL_NONE};
    texture->surface = eglCreatePbufferFromClientBuffer(display, 0x3454, CVPixelBufferGetIOSurface(image), config, options);
    RuntimeANGLEContext *state = objc_getAssociatedObject(cache->owner, &contextKey);
    EGLCurrent previous = saveCurrent();
    BOOL current = eglMakeCurrent(display, state->surface, state->surface, state->context);
    if (current) angle_glGenTextures(1, &texture->name);
    restoreCurrent(previous);
    if (!texture->surface || !texture->name || ![texture setBound:YES]) {
        [texture release]; return kCVReturnError;
    }
    [textureLock lock];
    NSHashTable *textures = [bufferTextures objectForKey:(id)image];
    if (!textures) {
        textures = [NSHashTable weakObjectsHashTable];
        [bufferTextures setObject:textures forKey:(id)image];
    }
    [textures addObject:texture];
    [textureLock unlock];
    *out = (CVOpenGLESTextureRef)texture;
    return kCVReturnSuccess;
}
INTERPOSE(createTexture, CVOpenGLESTextureCacheCreateTextureFromImage);
static GLuint textureName(CVOpenGLESTextureRef texture) { return ((RuntimeANGLETexture *)texture)->name; }
static GLenum textureTarget(CVOpenGLESTextureRef texture) { return GL_TEXTURE_2D; }
static Boolean textureFlipped(CVOpenGLESTextureRef texture) { return false; }
static void textureCoords(CVOpenGLESTextureRef texture, GLfloat *ll, GLfloat *lr, GLfloat *ur, GLfloat *ul) {
    ll[0]=0; ll[1]=0; lr[0]=1; lr[1]=0; ur[0]=1; ur[1]=1; ul[0]=0; ul[1]=1;
}
static void flushCache(CVOpenGLESTextureCacheRef cache, CVOptionFlags flags) {
    // No unused texture pool: each public texture owns and releases its EGL image.
}
INTERPOSE(textureName, CVOpenGLESTextureGetName);
INTERPOSE(textureTarget, CVOpenGLESTextureGetTarget);
INTERPOSE(textureFlipped, CVOpenGLESTextureIsFlipped);
INTERPOSE(textureCoords, CVOpenGLESTextureGetCleanTexCoords);
INTERPOSE(flushCache, CVOpenGLESTextureCacheFlush);

static NSArray *texturesForBuffer(CVPixelBufferRef buffer) {
    [textureLock lock];
    NSArray *textures = [[[bufferTextures objectForKey:(id)buffer] allObjects] retain];
    [textureLock unlock];
    return [textures autorelease];
}
// ANGLE's Simulator IOSurface contents are undefined while bound. Release on CPU
// access, then import the updated buffer again, preserving the public GL name.
static CVReturn lockBuffer(CVPixelBufferRef buffer, CVPixelBufferLockFlags flags) {
    for (RuntimeANGLETexture *texture in texturesForBuffer(buffer))
        if (![texture setBound:NO]) return kCVReturnError;
    return CVPixelBufferLockBaseAddress(buffer, flags);
}
static CVReturn unlockBuffer(CVPixelBufferRef buffer, CVPixelBufferLockFlags flags) {
    CVReturn result = CVPixelBufferUnlockBaseAddress(buffer, flags);
    if (result) return result;
    for (RuntimeANGLETexture *texture in texturesForBuffer(buffer))
        if (![texture setBound:YES]) return kCVReturnError;
    return kCVReturnSuccess;
}
INTERPOSE(lockBuffer, CVPixelBufferLockBaseAddress);
INTERPOSE(unlockBuffer, CVPixelBufferUnlockBaseAddress);

// APPLE allows RGBA internal storage with BGRA source bytes. ANGLE exposes the
// EXT rule, which requires matching BGRA internal/external tokens; bytes are unchanged.
static void (*angleTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
static void texImage2D(GLenum target, GLint level, GLint internalFormat, GLsizei width, GLsizei height,
                       GLint border, GLenum format, GLenum type, const void *pixels) {
    if (internalFormat == GL_RGBA && format == GL_BGRA && type == GL_UNSIGNED_BYTE)
        internalFormat = GL_BGRA;
    angleTexImage2D(target, level, internalFormat, width, height, border, format, type, pixels);
}
INTERPOSE(texImage2D, glTexImage2D);

// APPLE multisample uses the currently bound read/draw framebuffers, like ES 3.
static void resolveMultisample(void) {
    GLint renderbuffer = 0, width = 0, height = 0;
    angle_glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                               GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &renderbuffer);
    GLint previous = 0; angle_glGetIntegerv(GL_RENDERBUFFER_BINDING, &previous);
    angle_glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    angle_glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    angle_glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
    angle_glBindRenderbuffer(GL_RENDERBUFFER, previous);
    angle_glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
}
INTERPOSE(resolveMultisample, glResolveMultisampleFramebufferAPPLE);

__attribute__((constructor)) static void configureANGLE(void) {
    angleLibrary = dlopen("/System/Library/PrivateFrameworks/WebCore.framework/Frameworks/libANGLE-shared.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!angleLibrary) { fprintf(stderr, "[angle-adapter] load failed: %s\n", dlerror()); abort(); }
    loadGLFunctions();
    angleDeleteRenderbuffers = dlsym(angleLibrary, "GL_DeleteRenderbuffers");
    angleTexImage2D = dlsym(angleLibrary, "GL_TexImage2D");
#define LOAD(name) egl##name = dlsym(angleLibrary, "EGL_" #name)
    LOAD(CreateWindowSurface); LOAD(SwapBuffers);
    LOAD(GetPlatformDisplayEXT); LOAD(Initialize); LOAD(ChooseConfig); LOAD(BindAPI);
    LOAD(CreateContext); LOAD(DestroyContext); LOAD(CreatePbufferSurface); LOAD(CreatePbufferFromClientBuffer);
    LOAD(DestroySurface); LOAD(MakeCurrent); LOAD(GetCurrentContext); LOAD(GetCurrentSurface);
    LOAD(GetCurrentDisplay); LOAD(GetError); LOAD(BindTexImage); LOAD(ReleaseTexImage);
    bufferTextures = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                             valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    textureLock = [NSRecursiveLock new];
    originalInitAPI = (void *)method_setImplementation(class_getInstanceMethod(EAGLContext.class, @selector(initWithAPI:)), (IMP)initAPI);
    originalInitShared = (void *)method_setImplementation(class_getInstanceMethod(EAGLContext.class, @selector(initWithAPI:sharegroup:)), (IMP)initShared);
    originalSetCurrent = (void *)method_setImplementation(class_getClassMethod(EAGLContext.class, @selector(setCurrentContext:)), (IMP)setCurrent);
    method_setImplementation(class_getInstanceMethod(EAGLContext.class, @selector(renderbufferStorage:fromDrawable:)), (IMP)renderbufferStorage);
    method_setImplementation(class_getInstanceMethod(EAGLContext.class, @selector(presentRenderbuffer:)), (IMP)presentRenderbuffer);
    fprintf(stderr, "[angle-adapter] client EAGL/GLES/BGRA bridge installed\n");
}
