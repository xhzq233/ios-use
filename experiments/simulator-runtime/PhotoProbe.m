// Uses only a generated image and the broker-owned temporary photo library.
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) return 2;
        fprintf(stderr, "[photos-probe] bundle=%s home=%s\n",
                NSBundle.mainBundle.bundleIdentifier.UTF8String, NSHomeDirectory().UTF8String);
        PHAuthorizationStatus before = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        fprintf(stderr, "[photos-probe] initial status=%ld\n", (long)before);
        if (!strcmp(argv[1], "photo-status")) {
            PHAuthorizationStatus expected = argc == 3 ? strtol(argv[2], NULL, 10) : PHAuthorizationStatusNotDetermined;
            return before == expected ? 0 : 61;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block PHAuthorizationStatus result = before;
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
            result = status;
            fprintf(stderr, "[photos-probe] requested status=%ld\n", (long)status);
            dispatch_semaphore_signal(done);
        }];
        dispatch_time_t deadline = getenv("IOS_USE_RUNTIME_PRESENT") ? DISPATCH_TIME_FOREVER
            : dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(done, deadline)) return 60;
        if (!strcmp(argv[1], "photo-prompt")) {
            PHAuthorizationStatus expected = argc == 3 ? strtol(argv[2], NULL, 10) : PHAuthorizationStatusAuthorized;
            return result == expected ? 0 : 61;
        }
        if (result != PHAuthorizationStatusAuthorized && result != PHAuthorizationStatusLimited) return 61;
        if (strcmp(argv[1], "photo-roundtrip")) return 0;

        BOOL fixture = argc == 3 && !strcmp(argv[2], "fixture");
        size_t width = fixture ? 1024 : 64, height = fixture ? 768 : 48;
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colors, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        uint8_t *pixels = CGBitmapContextGetData(bitmap);
        for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
            size_t i = (y * width + x) * 4;
            pixels[i] = x * 255 / (width - 1);
            pixels[i + 1] = y * 255 / (height - 1);
            pixels[i + 2] = fixture && ((x / 128 + y / 128) % 2) ? 32 : 192;
            pixels[i + 3] = 255;
        }
        CGImageRef image = CGBitmapContextCreateImage(bitmap);
        NSMutableData *png = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(destination, image, NULL);
        BOOL encoded = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image);
        CGContextRelease(bitmap);
        CGColorSpaceRelease(colors);
        if (!encoded) return 62;
        CGImageSourceRef decoded = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
        CGImageRef checked = CGImageSourceCreateImageAtIndex(decoded, 0, NULL);
        BOOL dimensionsMatch = checked && CGImageGetWidth(checked) == width && CGImageGetHeight(checked) == height;
        fprintf(stderr, "[photos-probe] pngBytes=%lu dimensionsMatch=%d conformsImage=%d\n",
                (unsigned long)png.length, dimensionsMatch, [UTTypePNG conformsToType:UTTypeImage]);
        CGImageRelease(checked);
        CFRelease(decoded);
        if (!dimensionsMatch) return 62;

        PHPhotoLibrary *library = [PHPhotoLibrary sharedPhotoLibrary];
        __block NSString *identifier = nil;
        NSError *error = nil;
        BOOL created = [library performChangesAndWait:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            PHAssetResourceCreationOptions *resource = [PHAssetResourceCreationOptions new];
            resource.originalFilename = @"fixture.png";
            resource.uniformTypeIdentifier = @"public.png";
            [request addResourceWithType:PHAssetResourceTypePhoto data:png options:resource];
            identifier = request.placeholderForCreatedAsset.localIdentifier;
        } error:&error];
        fprintf(stderr, "[photos-probe] created=%d error=%s\n", created, error.description.UTF8String);
        if (!created) return 63;
        PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
        fprintf(stderr, "[photos-probe] fetched=%d size=%lux%lu\n",
                asset != nil, (unsigned long)asset.pixelWidth, (unsigned long)asset.pixelHeight);
        if (!asset || asset.pixelWidth != width || asset.pixelHeight != height) return 64;
        PHImageRequestOptions *options = [PHImageRequestOptions new];
        options.synchronous = YES;
        options.version = PHImageRequestOptionsVersionOriginal;
        __block BOOL equal = NO;
        [[PHImageManager defaultManager] requestImageDataAndOrientationForAsset:asset options:options
            resultHandler:^(NSData *data, NSString *uti, CGImagePropertyOrientation orientation, NSDictionary *info) {
                equal = [data isEqualToData:png];
                fprintf(stderr, "[photos-probe] returned=%lu originalEqual=%d error=%s\n",
                        (unsigned long)data.length, equal, [info[PHImageErrorKey] description].UTF8String);
            }];
        return equal ? 0 : 65;
    }
}
