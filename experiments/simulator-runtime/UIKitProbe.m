#import <UIKit/UIKit.h>
#import <objc/runtime.h>

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        printf("[uikit] image=%s\n", class_getImageName(UIView.class));
        UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 180)];
        view.backgroundColor = UIColor.systemBlueColor;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 30, 280, 100)];
        label.text = @"UIKit 26\nStandalone runtime";
        label.numberOfLines = 2;
        label.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        label.textColor = UIColor.whiteColor;
        [view addSubview:label];
        UIView *capsule = [[UIView alloc] initWithFrame:CGRectMake(20, 130, 280, 36)];
        capsule.backgroundColor = UIColor.systemGreenColor;
        if (@available(iOS 26.0, *)) {
            capsule.cornerConfiguration = UICornerConfiguration.capsuleConfiguration;
        } else {
            return 34;
        }
        [view addSubview:capsule];
        [view layoutIfNeeded];

        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
            initWithSize:view.bounds.size format:format];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [view.layer renderInContext:context.CGContext];
        }];
        if (!image.CGImage || CGImageGetWidth(image.CGImage) != 320 || CGImageGetHeight(image.CGImage) != 180) return 30;
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"uikit.png"];
        BOOL saved = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
        printf("[uikit] PNG=%s saved=%d\n", path.UTF8String, saved);
        if (!saved) return 31;
        uint8_t *pixels = calloc(320 * 180, 4);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(pixels, 320, 180, 8, 320 * 4,
            colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colorSpace);
        if (!bitmap) { free(pixels); return 32; }
        CGContextDrawImage(bitmap, CGRectMake(0, 0, 320, 180), image.CGImage);
        unsigned whitePixels = 0;
        for (int i = 0; i < 320 * 180; ++i) {
            if (pixels[4*i] > 240 && pixels[4*i+1] > 240 && pixels[4*i+2] > 240) ++whitePixels;
        }
        CGContextRelease(bitmap);
        free(pixels);
        printf("[uikit] white text pixels=%u\n", whitePixels);
        return whitePixels > 100 ? 0 : 33;
    }
}
