// Real GPU buffer/texture aliasing, including video-plane formats and later writes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;
static BOOL finish(id<MTLCommandBuffer> command) {
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        NSLog(@"[linear] GPU error %@", command.error);
        return NO;
    }
    return YES;
}

static int exercise(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline,
                    MTLPixelFormat format, NSUInteger channels, NSUInteger width, NSUInteger height) {
    NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:format];
    NSUInteger offset = alignment, row = ((width * channels + alignment - 1) / alignment) * alignment;
    NSUInteger size = offset + row * height + alignment;
    id<MTLBuffer> source = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
    id<MTLBuffer> staging = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [device newBufferWithLength:row * height options:MTLResourceStorageModeShared];
    id<MTLBuffer> sampled = [device newBufferWithLength:width * height * 4 options:MTLResourceStorageModeShared];
    memset(source.contents, 0xa5, size);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    CFTimeInterval before = NSProcessInfo.processInfo.systemUptime;
    id<MTLTexture> texture = [source newTextureWithDescriptor:descriptor offset:offset bytesPerRow:row];
    double creationMilliseconds = (NSProcessInfo.processInfo.systemUptime - before) * 1000;
    if (!texture) return 10;
    if (texture.buffer != source || texture.storageMode != MTLStorageModeShared
        || texture.bufferOffset != offset || texture.bufferBytesPerRow != row) return 11;
    for (unsigned frame = 0; frame < 8; frame++) {
        for (NSUInteger y = 0; y < height; y++) for (NSUInteger x = 0; x < width * channels; x++)
            ((uint8_t *)source.contents)[offset + y * row + x] = (uint8_t)(frame * 31 + x * 3 + y * 7);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(width, height, 1) toBuffer:output destinationOffset:0
            destinationBytesPerRow:row destinationBytesPerImage:row * height];
        [blit endEncoding];
        id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
        [compute setComputePipelineState:pipeline];
        [compute setTexture:texture atIndex:0];
        [compute setBuffer:sampled offset:0 atIndex:0];
        [compute dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [compute endEncoding];
        if (!finish(command)) return 12;
        for (NSUInteger y = 0; y < height; y++) for (NSUInteger x = 0; x < width * channels; x++)
            if (((uint8_t *)output.contents)[y * row + x] != (uint8_t)(frame * 31 + x * 3 + y * 7)) return 13;
        for (NSUInteger y = 0; y < height; y++) for (NSUInteger x = 0; x < width; x++) {
            for (NSUInteger c = 0; c < 4; c++) {
                NSUInteger inputChannel = format == MTLPixelFormatBGRA8Unorm && c < 3 ? 2 - c : c;
                uint8_t expected = inputChannel < channels
                    ? (uint8_t)(frame * 31 + (x * channels + inputChannel) * 3 + y * 7) : c == 3 ? 255 : 0;
                if (((uint8_t *)sampled.contents)[(y * width + x) * 4 + c] != expected) return 14;
            }
        }
        for (NSUInteger y = 0; y < height; y++) for (NSUInteger x = 0; x < width * channels; x++)
            ((uint8_t *)staging.contents)[y * row + x] = (uint8_t)(frame * 17 + x * 5 + y * 11);
        command = [queue commandBuffer];
        blit = [command blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * height
            sourceSize:MTLSizeMake(width, height, 1) toTexture:texture destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        if (!finish(command)) return 15;
        for (NSUInteger y = 0; y < height; y++) for (NSUInteger x = 0; x < width * channels; x++)
            if (((uint8_t *)source.contents)[offset + y * row + x] != (uint8_t)(frame * 17 + x * 5 + y * 11)) return 16;
    }
    for (NSUInteger i = 0; i < size; i++) {
        BOOL written = i >= offset && i < offset + row * height && (i - offset) % row < width * channels;
        if (!written && ((uint8_t *)source.contents)[i] != 0xa5) return 17;
    }
    printf("[linear] format=%lu size=%lux%lu row=%lu create=%.3fms eight bidirectional updates, sampling, padding passed\n",
        (unsigned long)format, (unsigned long)width, (unsigned long)height, (unsigned long)row, creationMilliseconds);
    return 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    setbuf(stdout, NULL);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 2;
    if (argc > 1) {
        // A different descriptor error must still be rejected inside the scoped
        // adapter call. Run in a separate process because Metal aborts on error.
        id<MTLBuffer> buffer = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:0 height:4 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [buffer newTextureWithDescriptor:descriptor offset:0 bytesPerRow:64];
        return texture ? 90 : 0;
    }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "kernel void sample(texture2d<float> image [[texture(0)]], device uchar4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
         "constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);"
         "out[p.y * image.get_width() + p.x] = uchar4(round(image.sample(s, float2(p) + 0.5) * 255.0)); }"
        options:nil error:&error];
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"sample"] error:&error];
    if (!pipeline) { NSLog(@"[linear] pipeline %@", error); return 3; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    const MTLPixelFormat formats[] = {MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm, MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm};
    const NSUInteger channels[] = {1, 2, 4, 4};
    for (unsigned i = 0; i < 4; i++) {
        int status = exercise(device, queue, pipeline, formats[i], channels[i], 17, 9);
        if (status) { printf("[linear] format=%lu failed=%d\n", (unsigned long)formats[i], status); return status; }
    }
    int status = exercise(device, queue, pipeline, MTLPixelFormatR8Unorm, 1, 1920, 1080);
    if (status) return status;
    pid_t child;
    char *arguments[] = {argv[0], "invalid", NULL};
    if (posix_spawn(&child, argv[0], NULL, NULL, arguments, environ)) return 18;
    if (waitpid(child, &status, 0) != child) return 19;
    BOOL rejected = (WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT)
        || (WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("[linear] invalid descriptor rejected=%d\n", rejected);
    return rejected ? 0 : 20;
}}
