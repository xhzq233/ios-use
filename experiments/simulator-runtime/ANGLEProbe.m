// Real GLES shader drawing through the installed runtime ANGLE Metal backend.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <OpenGLES/ES3/gl.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/ES3/glext.h>
// EGL values from the Khronos API and ANGLE's Metal/IOSurface extensions.
enum {
    EGL_NONE = 0x3038, EGL_PLATFORM_ANGLE = 0x3202,
    EGL_PLATFORM_ANGLE_TYPE = 0x3203, EGL_PLATFORM_ANGLE_METAL = 0x3489,
    EGL_SURFACE_TYPE = 0x3033, EGL_PBUFFER_BIT = 1,
    EGL_RENDERABLE_TYPE = 0x3040, EGL_OPENGL_ES3_BIT = 0x40,
    EGL_RED_SIZE = 0x3024, EGL_GREEN_SIZE = 0x3023, EGL_BLUE_SIZE = 0x3022, EGL_ALPHA_SIZE = 0x3021,
    EGL_OPENGL_ES_API = 0x30A0, EGL_CONTEXT_CLIENT_VERSION = 0x3098,
    EGL_WIDTH = 0x3057, EGL_HEIGHT = 0x3056,
    EGL_TEXTURE_FORMAT = 0x3080, EGL_TEXTURE_RGBA = 0x305E,
    EGL_TEXTURE_TARGET = 0x3081, EGL_TEXTURE_2D = 0x305F,
    EGL_IOSURFACE = 0x3454, EGL_IOSURFACE_PLANE = 0x345A,
    EGL_TEXTURE_TYPE = 0x345C, EGL_TEXTURE_INTERNAL_FORMAT = 0x345D,
    EGL_BACK_BUFFER = 0x3084
};
#define LOAD_EGL(name, type, ...) type (*name)(__VA_ARGS__)=(void *)dlsym(library,"EGL_" #name)
#define LOAD_GL(name, type, ...) type (*gl##name)(__VA_ARGS__)=(void *)dlsym(library,"GL_" #name)
int main(void) {
 @autoreleasepool {
  void *library=dlopen("/System/Library/PrivateFrameworks/WebCore.framework/Frameworks/libANGLE-shared.dylib",RTLD_NOW|RTLD_LOCAL);
  if(!library){fprintf(stderr,"[angle] load=%s\n",dlerror());return 90;}
  LOAD_EGL(GetPlatformDisplayEXT,void *,unsigned,void *,const int *);
  LOAD_EGL(Initialize,unsigned,void *,int *,int *);
  LOAD_EGL(GetError,int,void);
  LOAD_EGL(ChooseConfig,unsigned,void *,const int *,void **,int,int *);
  LOAD_EGL(BindAPI,unsigned,unsigned);
  LOAD_EGL(CreateContext,void *,void *,void *,void *,const int *);
  LOAD_EGL(CreatePbufferSurface,void *,void *,void *,const int *);
  LOAD_EGL(MakeCurrent,unsigned,void *,void *,void *,void *);
  LOAD_EGL(DestroySurface,unsigned,void *,void *);
  LOAD_EGL(DestroyContext,unsigned,void *,void *);
  LOAD_EGL(Terminate,unsigned,void *);
  LOAD_EGL(CreatePbufferFromClientBuffer,void *,void *,unsigned,void *,void *,const int *);
  LOAD_EGL(BindTexImage,unsigned,void *,void *,int);
  LOAD_EGL(ReleaseTexImage,unsigned,void *,void *,int);
  int displayAttributes[]={EGL_PLATFORM_ANGLE_TYPE,EGL_PLATFORM_ANGLE_METAL,EGL_NONE};
  void *display=GetPlatformDisplayEXT(EGL_PLATFORM_ANGLE,NULL,displayAttributes);
  int major=0,minor=0;
  unsigned initialized=Initialize(display,&major,&minor);
  fprintf(stderr,"[angle] display=%p initialized=%u version=%d.%d error=%x\n",display,initialized,major,minor,GetError());
  if(!initialized)return 91;
  int configAttributes[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
  void *config=NULL;int count=0;
  unsigned chosen=ChooseConfig(display,configAttributes,&config,1,&count);
  fprintf(stderr,"[angle] config=%u count=%d error=%x\n",chosen,count,GetError());
  if(!chosen||!count)return 92;
  BindAPI(EGL_OPENGL_ES_API);
  int contextAttributes[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
  void *context=CreateContext(display,config,NULL,contextAttributes);
  int surfaceAttributes[]={EGL_WIDTH,16,EGL_HEIGHT,16,EGL_NONE};
  void *surface=CreatePbufferSurface(display,config,surfaceAttributes);
  unsigned current=MakeCurrent(display,surface,surface,context);
  fprintf(stderr,"[angle] context=%p surface=%p current=%u error=%x\n",context,surface,current,GetError());
  if(!current)return 93;
  LOAD_GL(GetString,const GLubyte *,GLenum);
  LOAD_GL(ClearColor,void,GLfloat,GLfloat,GLfloat,GLfloat);
  LOAD_GL(Clear,void,GLbitfield);
  LOAD_GL(Finish,void,void);
  LOAD_GL(ReadPixels,void,GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void *);
  LOAD_GL(GetError,GLenum,void);
  fprintf(stderr,"[angle] renderer=%s version=%s\n",glGetString(GL_RENDERER),glGetString(GL_VERSION));
  glClearColor(1,0,0,1);glClear(GL_COLOR_BUFFER_BIT);glFinish();
  uint8_t pixel[4]={0};glReadPixels(0,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);
  GLenum error=glGetError();fprintf(stderr,"[angle] error=%x pixel=%u,%u,%u,%u\n",error,pixel[0],pixel[1],pixel[2],pixel[3]);
  LOAD_GL(GenTextures,void,GLsizei,GLuint *);
  LOAD_GL(BindTexture,void,GLenum,GLuint);
  LOAD_GL(GenFramebuffers,void,GLsizei,GLuint *);
  LOAD_GL(BindFramebuffer,void,GLenum,GLuint);
  LOAD_GL(FramebufferTexture2D,void,GLenum,GLenum,GLenum,GLuint,GLint);
  LOAD_GL(CheckFramebufferStatus,GLenum,GLenum);
  LOAD_GL(CreateShader,GLuint,GLenum);
  LOAD_GL(ShaderSource,void,GLuint,GLsizei,const GLchar *const *,const GLint *);
  LOAD_GL(CompileShader,void,GLuint);
  LOAD_GL(GetShaderiv,void,GLuint,GLenum,GLint *);
  LOAD_GL(CreateProgram,GLuint,void);
  LOAD_GL(AttachShader,void,GLuint,GLuint);
  LOAD_GL(LinkProgram,void,GLuint);
  LOAD_GL(GetProgramiv,void,GLuint,GLenum,GLint *);
  LOAD_GL(UseProgram,void,GLuint);
  LOAD_GL(Viewport,void,GLint,GLint,GLsizei,GLsizei);
  LOAD_GL(DrawArrays,void,GLenum,GLint,GLsizei);
  LOAD_GL(GenVertexArrays,void,GLsizei,GLuint *);
  LOAD_GL(BindVertexArray,void,GLuint);
  LOAD_GL(DeleteFramebuffers,void,GLsizei,const GLuint *);
  LOAD_GL(DeleteTextures,void,GLsizei,const GLuint *);
  LOAD_GL(DeleteShader,void,GLuint);
  LOAD_GL(DeleteProgram,void,GLuint);
  LOAD_GL(DeleteVertexArrays,void,GLsizei,const GLuint *);
  CVPixelBufferRef buffer=NULL;
  NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
  CVReturn allocated=CVPixelBufferCreate(NULL,16,16,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&buffer);
  if(allocated)return 95;
  CVPixelBufferLockBaseAddress(buffer,0);
  uint8_t *base=CVPixelBufferGetBaseAddress(buffer);size_t stride=CVPixelBufferGetBytesPerRow(buffer);
  for(int y=0;y<16;y++)for(int x=0;x<16;x++){uint8_t *p=base+y*stride+x*4;p[0]=0;p[1]=0;p[2]=255;p[3]=255;}
  CVPixelBufferUnlockBaseAddress(buffer,0);
  int sharedAttributes[]={EGL_WIDTH,16,EGL_HEIGHT,16,EGL_TEXTURE_FORMAT,EGL_TEXTURE_RGBA,EGL_TEXTURE_TARGET,EGL_TEXTURE_2D,EGL_TEXTURE_TYPE,GL_UNSIGNED_BYTE,EGL_TEXTURE_INTERNAL_FORMAT,GL_BGRA,EGL_IOSURFACE_PLANE,0,EGL_NONE};
  void *shared=CreatePbufferFromClientBuffer(display,EGL_IOSURFACE,CVPixelBufferGetIOSurface(buffer),config,sharedAttributes);
  GLuint texture=0,framebuffer=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
  unsigned bound=shared?BindTexImage(display,shared,EGL_BACK_BUFFER):0;
  fprintf(stderr,"[angle] IOSurface pbuffer=%p bound=%u error=%x\n",shared,bound,GetError());
  if(!bound)return 96;
  glGenFramebuffers(1,&framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
  GLenum complete=glCheckFramebufferStatus(GL_FRAMEBUFFER);
  uint8_t before[4]={0};glReadPixels(0,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,before);
  fprintf(stderr,"[angle] shared framebuffer=%x before=%u,%u,%u,%u\n",complete,before[0],before[1],before[2],before[3]);
  const char *vertexSource="#version 300 es\nvoid main(){vec2 p=gl_VertexID==0?vec2(-1,-1):gl_VertexID==1?vec2(3,-1):vec2(-1,3);gl_Position=vec4(p,0,1);}";
  const char *fragmentSource="#version 300 es\nprecision highp float;out vec4 color;void main(){color=vec4(0,1,0,1);}";
  GLuint vertex=glCreateShader(GL_VERTEX_SHADER),fragment=glCreateShader(GL_FRAGMENT_SHADER);
  glShaderSource(vertex,1,&vertexSource,NULL);glCompileShader(vertex);
  glShaderSource(fragment,1,&fragmentSource,NULL);glCompileShader(fragment);
  GLint vertexOK=0,fragmentOK=0,linked=0;glGetShaderiv(vertex,GL_COMPILE_STATUS,&vertexOK);glGetShaderiv(fragment,GL_COMPILE_STATUS,&fragmentOK);
  GLuint program=glCreateProgram();glAttachShader(program,vertex);glAttachShader(program,fragment);glLinkProgram(program);glGetProgramiv(program,GL_LINK_STATUS,&linked);
  fprintf(stderr,"[angle] shaders=%d/%d linked=%d\n",vertexOK,fragmentOK,linked);
  GLuint vao=0;glGenVertexArrays(1,&vao);glBindVertexArray(vao);glUseProgram(program);glViewport(0,0,16,16);glDrawArrays(GL_TRIANGLES,0,3);glFinish();
  uint8_t rendered[4]={0};glReadPixels(8,8,1,1,GL_RGBA,GL_UNSIGNED_BYTE,rendered);
  unsigned released=ReleaseTexImage(display,shared,EGL_BACK_BUFFER);GLenum renderError=glGetError();
  CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);base=CVPixelBufferGetBaseAddress(buffer);uint8_t *after=base+8*stride+8*4;
  fprintf(stderr,"[angle] released=%u error=%x rendered=%u,%u,%u,%u buffer=%u,%u,%u,%u\n",released,renderError,rendered[0],rendered[1],rendered[2],rendered[3],after[0],after[1],after[2],after[3]);
  BOOL roundtrip=before[0]==255&&before[1]==0&&before[2]==0&&before[3]==255;
  for(int y=0;y<16;y++)for(int x=0;x<16;x++) {
   const uint8_t *pixel=base+y*stride+x*4;
   roundtrip &= pixel[0]==0&&pixel[1]==255&&pixel[2]==0&&pixel[3]==255;
  }
  CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
  glBindFramebuffer(GL_FRAMEBUFFER,0);glDeleteFramebuffers(1,&framebuffer);glDeleteTextures(1,&texture);glDeleteVertexArrays(1,&vao);glDeleteProgram(program);glDeleteShader(vertex);glDeleteShader(fragment);
  DestroySurface(display,shared);CFRelease(buffer);
  MakeCurrent(display,NULL,NULL,NULL);DestroySurface(display,surface);DestroyContext(display,context);Terminate(display);
  return !error&&!renderError&&vertexOK&&fragmentOK&&linked&&released&&roundtrip?0:94;
 }
}
