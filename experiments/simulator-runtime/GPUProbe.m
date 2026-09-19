#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        printf("[probe] iOS=%s UIKit=%s\n", UIDevice.currentDevice.systemVersion.UTF8String,
               class_getImageName(UIView.class));
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 10;
        printf("[probe] GPU class=%s image=%s\n", object_getClassName(device),
               class_getImageName(object_getClass(device)));
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (!queue || !texture) return 11;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass];
        if (!render) return 11;
        [render endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            NSLog(@"Render failed: %@", command.error);
            return 12;
        }
        uint8_t pixels[64] = {0};
        [texture getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
        const uint8_t expected[] = {191, 128, 64, 255};
        for (int i = 0; i < 64; ++i) {
            if (abs((int)pixels[i] - expected[i % 4]) > 1) return 13;
        }
        printf("[probe] render: 16 pixels verified, BGRA=%u,%u,%u,%u\n",
               pixels[0], pixels[1], pixels[2], pixels[3]);

        NSError *error = nil;
        id<MTLLibrary> library;
        if (argc == 2) {
            library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
        } else {
            MTLCompileOptions *options = [MTLCompileOptions new];
            options.languageVersion = MTLLanguageVersion3_0;
            library = [device newLibraryWithSource:
                @"#include <metal_stdlib>\nusing namespace metal;\n"
                 "kernel void probe(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = 42; }"
                options:options error:&error];
        }
        if (!library) { NSLog(@"Library failed: %@", error); return 14; }
        id<MTLFunction> function = [library newFunctionWithName:@"probe"];
        if (!function) return 15;
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) { NSLog(@"Pipeline failed: %@", error); return 16; }
        id<MTLBuffer> output = [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (!output) return 17;
        *(uint32_t *)output.contents = 0;
        command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
        if (!compute) return 17;
        [compute setComputePipelineState:pipeline];
        [compute setBuffer:output offset:0 atIndex:0];
        [compute dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [compute endEncoding];
        [command commit];
        [command waitUntilCompleted];
        printf("[probe] compute=%u status=%lu mode=%s\n", *(uint32_t *)output.contents,
               (unsigned long)command.status, argc == 2 ? "metallib" : "source");
        return command.status == MTLCommandBufferStatusCompleted && *(uint32_t *)output.contents == 42 ? 0 : 18;
    }
}
