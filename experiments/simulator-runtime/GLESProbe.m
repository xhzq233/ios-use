// Exercise EAGL/CoreVideo callers without knowing which GLES implementation runs.
#define GLES_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/ES2/glext.h>
#import <CoreVideo/CoreVideo.h>
#import <GLKit/GLKTextureLoader.h>

static BOOL bufferIsColor(CVPixelBufferRef buffer, uint8_t red, uint8_t green, uint8_t blue) {
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly)) return NO;
    const uint8_t *bytes = CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    BOOL correct = YES;
    for (size_t y = 0; y < CVPixelBufferGetHeight(buffer); y++)
        for (size_t x = 0; x < CVPixelBufferGetWidth(buffer); x++) {
            const uint8_t *pixel = bytes + y * stride + x * 4;
            correct &= pixel[0] == blue && pixel[1] == green && pixel[2] == red && pixel[3] == 255;
        }
    return CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) == 0 && correct;
}

static BOOL drawGreenTriangle(void) {
    const char *vertexSource = "attribute vec2 position;void main(){gl_Position=vec4(position,0,1);}";
    const char *fragmentSource = "precision highp float;void main(){gl_FragColor=vec4(0,1,0,1);}";
    GLuint vertex = glCreateShader(GL_VERTEX_SHADER), fragment = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(vertex, 1, &vertexSource, NULL); glCompileShader(vertex);
    glShaderSource(fragment, 1, &fragmentSource, NULL); glCompileShader(fragment);
    GLuint program = glCreateProgram(); glAttachShader(program, vertex); glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "position"); glLinkProgram(program);
    GLint linked = 0; glGetProgramiv(program, GL_LINK_STATUS, &linked);
    const GLfloat positions[] = {-1, -1, 3, -1, -1, 3};
    GLuint buffer = 0; glGenBuffers(1, &buffer); glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(positions), positions, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL); glEnableVertexAttribArray(0);
    glUseProgram(program); glViewport(0, 0, 16, 16); glDrawArrays(GL_TRIANGLES, 0, 3); glFinish();
    BOOL success = linked && glGetError() == GL_NO_ERROR;
    glUseProgram(0); glDisableVertexAttribArray(0); glDeleteBuffers(1, &buffer);
    glDeleteProgram(program); glDeleteShader(vertex); glDeleteShader(fragment);
    return success;
}

static int runAPI(EAGLRenderingAPI api) {
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:api];
    if (!context || ![EAGLContext setCurrentContext:context]) return 80;
    fprintf(stderr, "[gles] API=%lu renderer=%s version=%s\n", (unsigned long)api,
            glGetString(GL_RENDERER), glGetString(GL_VERSION));
    GLuint texture = 0, framebuffer = 0;
    glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    glClearColor(1, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glFinish();
    uint8_t pixel[4] = {0}; glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    BOOL direct = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
        glGetError() == GL_NO_ERROR && pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255;
    if (!direct) return 83;
    GLuint multisampleFBO = 0, multisampleColor = 0;
    glGenFramebuffers(1, &multisampleFBO); glBindFramebuffer(GL_FRAMEBUFFER, multisampleFBO);
    glGenRenderbuffers(1, &multisampleColor); glBindRenderbuffer(GL_RENDERBUFFER, multisampleColor);
    glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, 4, GL_RGBA8, 16, 16);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, multisampleColor);
    BOOL multisample = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glClearColor(0, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, multisampleFBO);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, framebuffer);
    glResolveMultisampleFramebufferAPPLE();
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    multisample &= glGetError() == GL_NO_ERROR && pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255;
    fprintf(stderr, "[gles] direct=%d APPLE multisample resolve=%d\n", direct, multisample);
    glDeleteRenderbuffers(1, &multisampleColor); glDeleteFramebuffers(1, &multisampleFBO);
    glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture);

    uint8_t imagePixels[16 * 16 * 4];
    for (int i = 0; i < 16 * 16; i++) {
        imagePixels[i * 4] = 0; imagePixels[i * 4 + 1] = 0;
        imagePixels[i * 4 + 2] = 255; imagePixels[i * 4 + 3] = 255;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(imagePixels, 16, 16, 8, 16 * 4, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    NSError *imageError = nil;
    GLKTextureInfo *loaded = [GLKTextureLoader textureWithCGImage:image options:nil error:&imageError];
    BOOL imported = loaded && glIsTexture(loaded.name);
    if (loaded) {
        GLuint fbo = 0; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, loaded.target, loaded.name, 0);
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        imported &= glGetError() == GL_NO_ERROR && pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255;
        glDeleteFramebuffers(1, &fbo); GLuint name = loaded.name; glDeleteTextures(1, &name);
    }
    fprintf(stderr, "[gles] GLKit image import=%d error=%s\n", imported, imageError.description.UTF8String ?: "none");
    CGImageRelease(image); CGContextRelease(bitmap); CGColorSpaceRelease(colorSpace);

    EAGLContext *sibling = [[EAGLContext alloc] initWithAPI:api sharegroup:context.sharegroup];
    if (!sibling) return 84;
    int success = 0;
    for (int compatible = 0; compatible < 2; compatible++) {
        [EAGLContext setCurrentContext:context];
        CVOpenGLESTextureCacheRef cache = NULL;
        CVReturn cached = CVOpenGLESTextureCacheCreate(NULL, NULL, context, NULL, &cache);
        if (cached || !cache) return 81;
        NSMutableDictionary *attributes = [@{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}} mutableCopy];
        if (compatible) attributes[(__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey] = @YES;
        CVPixelBufferRef buffer = NULL;
        CVReturn created = CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attributes, &buffer);
        CVOpenGLESTextureRef shared = NULL;
        CVReturn mapped = buffer ? CVOpenGLESTextureCacheCreateTextureFromImage(NULL, cache, buffer, NULL,
            GL_TEXTURE_2D, GL_RGBA, 16, 16, GL_BGRA, GL_UNSIGNED_BYTE, 0, &shared) : -1;
        fprintf(stderr, "[gles] API=%lu compatible=%d buffer=%d texture=%d\n", (unsigned long)api, compatible, created, mapped);
        if (shared) {
            GLenum target = CVOpenGLESTextureGetTarget(shared);
            GLuint name = CVOpenGLESTextureGetName(shared);
            // The public texture keeps its storage alive after the cache is released.
            CVOpenGLESTextureCacheFlush(cache, 0); CFRelease(cache); cache = NULL;
            BOOL correct = [EAGLContext setCurrentContext:sibling] && glIsTexture(name);
            glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, name, 0);
            correct &= glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
            glClearColor(0, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glFinish();
            correct &= bufferIsColor(buffer, 0, 255, 0);
            // CPU writes must be visible through the same texture/FBO after unlocking.
            correct &= CVPixelBufferLockBaseAddress(buffer, 0) == 0;
            uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
            size_t stride = CVPixelBufferGetBytesPerRow(buffer);
            for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
                uint8_t *p = base + y * stride + x * 4; p[0] = 255; p[1] = 0; p[2] = 0; p[3] = 255;
            }
            correct &= CVPixelBufferUnlockBaseAddress(buffer, 0) == 0;
            glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            correct &= pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255;
            correct &= drawGreenTriangle() && bufferIsColor(buffer, 0, 255, 0);
            correct &= EAGLContext.currentContext == sibling && glGetError() == GL_NO_ERROR;
            fprintf(stderr, "[gles] API=%lu compatible=%d sharedContextAndPixels=%d\n", (unsigned long)api, compatible, correct);
            glDeleteFramebuffers(1, &framebuffer); CFRelease(shared);
            success += correct;
        }
        if (cache) CFRelease(cache);
        if (buffer) CFRelease(buffer);
    }
    [EAGLContext setCurrentContext:nil];
    return success != 2 ? 82 : !imported ? 85 : multisample ? 0 : 83;
}
int main(void) {
    @autoreleasepool {
        int es3 = runAPI(kEAGLRenderingAPIOpenGLES3);
        int es2 = runAPI(kEAGLRenderingAPIOpenGLES2);
        return es3 ?: es2;
    }
}
