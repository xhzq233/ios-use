// Preserve buffer/texture aliasing through the existing Simulator Metal transport.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <stdatomic.h>

typedef id<MTLTexture> (*NewTexture)(id, SEL, MTLTextureDescriptor *, NSUInteger, NSUInteger)
    __attribute__((ns_returns_retained));
static NewTexture originalNewTexture;
static _Thread_local BOOL sharedLinearCall;

static id<MTLTexture> newTexture(id<MTLBuffer> buffer, SEL selector, MTLTextureDescriptor *descriptor,
                               NSUInteger offset, NSUInteger row) __attribute__((ns_returns_retained));
static id<MTLTexture> newTexture(id<MTLBuffer> buffer, SEL selector, MTLTextureDescriptor *descriptor,
                               NSUInteger offset, NSUInteger row) {
    BOOL previous = sharedLinearCall;
    sharedLinearCall = buffer.storageMode == MTLStorageModeShared
        && descriptor.storageMode == MTLStorageModeShared;
    @try {
        id<MTLTexture> texture = originalNewTexture(buffer, selector, descriptor, offset, row);
        if (sharedLinearCall && texture) {
            static atomic_uint count;
            unsigned created = atomic_fetch_add(&count, 1) + 1;
            if (created <= 8 || created % 300 == 0)
                fprintf(stderr, "[metal-buffer] shared texture=%u format=%lu size=%lux%lu offset=%lu row=%lu\n",
                    created, (unsigned long)descriptor.pixelFormat, (unsigned long)descriptor.width,
                    (unsigned long)descriptor.height, (unsigned long)offset, (unsigned long)row);
        }
        return texture;
    } @finally {
        sharedLinearCall = previous;
    }
}

extern void originalFailure(uint64_t, const char *, unsigned, NSString *, ...) __asm__("_MTLReportFailure");
static void reportFailure(uint64_t type, const char *method, unsigned line, NSString *format, ...) {
    // This is one Simulator-only storage restriction on the measured Apple
    // GPU path. Keep descriptor, alignment, bounds, and host Metal validation.
    // Do not change resource storage modes or manufacture a copied texture.
    if (sharedLinearCall && !strcmp(method, "-[MTLSimBuffer newTextureWithDescriptor:offset:bytesPerRow:]")
        && [format isEqualToString:@"Linear texture can only be created on buffers with MTLStorageModePrivate in the simulator"])
        return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    originalFailure(type, method, line, @"%@", message);
}

__attribute__((constructor)) static void installBufferContext(void) {
    // The broker describes the actual host GPU, not the simulated feature set.
    if (!getenv("IOS_USE_RUNTIME_SHARED_LINEAR_TEXTURES")) return;
    dlopen("/System/Library/PrivateFrameworks/MTLSimDriver.framework/MTLSimDriver", RTLD_NOW);
    Method method = class_getInstanceMethod(NSClassFromString(@"MTLSimBuffer"),
        @selector(newTextureWithDescriptor:offset:bytesPerRow:));
    originalNewTexture = (NewTexture)method_setImplementation(method, (IMP)newTexture);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} overrides[] = {{(void *)reportFailure, (void *)originalFailure}};
