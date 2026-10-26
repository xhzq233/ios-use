#import "IOSUsePlayAudio.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <math.h>
#include <stdatomic.h>
static atomic_bool queueStopping;
extern NSDictionary *IOSUsePlayAudioTestMeter(void);
extern void IOSUsePlayAudioTestScale(AudioBuffer *, AudioStreamBasicDescription, float);

static void waitSeconds(double seconds) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }
static void configure(int volume, BOOL mute) {
    NSError *error=nil;
    assert(IOSUsePlayConfigureAudio(@{@"volume":@(volume),@"muted":@(mute)},&error)); assert(!error);
}
static void checkGain(double expected) {
    unsigned long initial=[IOSUsePlayAudioTestMeter()[@"callbacks"] unsignedLongValue];
    for(int i=0;i<40;i++) {
        waitSeconds(.025); NSDictionary *meter=IOSUsePlayAudioTestMeter();
        if([meter[@"callbacks"] unsignedLongValue]>initial+2 && fabs([meter[@"ratio"] doubleValue]-expected)<.002) return;
    }
    fprintf(stderr,"audio output did not reach gain %.2f: %s\n",expected,IOSUsePlayAudioTestMeter().description.UTF8String); abort();
}
static void unitTests(void) {
    unsetenv("IOS_USE_MAC_MUTE"); unsetenv("IOS_USE_MAC_VOLUME");
    IOSUsePlayAudioInitialize();
    assert([IOSUsePlayAudioState()[@"muted"] boolValue]);
    assert([IOSUsePlayAudioState()[@"volume"] intValue]==100);
    setenv("IOS_USE_MAC_MUTE","0",1); IOSUsePlayAudioInitialize();
    assert(![IOSUsePlayAudioState()[@"muted"] boolValue]);
    setenv("IOS_USE_MAC_MUTE","1",1); IOSUsePlayAudioInitialize();
    assert([IOSUsePlayAudioState()[@"muted"] boolValue]);
    AudioStreamBasicDescription format={.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBitsPerChannel=32,.mChannelsPerFrame=1,.mBytesPerFrame=4};
    float values[]={-1,-.25,0,.25,1};AudioBuffer b={1,sizeof(values),values};
    IOSUsePlayAudioTestScale(&b,format,.25);assert(values[0]==-.25 && values[4]==.25);
    IOSUsePlayAudioTestScale(&b,format,0);for(int i=0;i<5;i++)assert(values[i]==0);
    double d[]={-.5,.5};b=(AudioBuffer){1,sizeof(d),d};format.mBitsPerChannel=64;format.mBytesPerFrame=8;
    IOSUsePlayAudioTestScale(&b,format,.5);assert(d[0]==-.25&&d[1]==.25);
    int16_t small[]={INT16_MIN,INT16_MAX};b=(AudioBuffer){1,sizeof(small),small};format.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;format.mBitsPerChannel=16;format.mBytesPerFrame=2;
    IOSUsePlayAudioTestScale(&b,format,.5);assert(small[0]==-16384&&small[1]==16383);
    int32_t large[]={INT32_MIN,INT32_MAX};b=(AudioBuffer){1,sizeof(large),large};format.mBitsPerChannel=32;format.mBytesPerFrame=4;
    IOSUsePlayAudioTestScale(&b,format,.5);assert(large[0]==-1073741824&&large[1]==1073741823);
    format.mFormatID=kAudioFormatAC3;IOSUsePlayAudioTestScale(&b,format,0);assert(large[1]==1073741823);
    configure(37,YES);
    assert(CFGetTypeID((__bridge CFTypeRef)IOSUsePlayAudioState()[@"muted"])==CFBooleanGetTypeID());
    for(id invalid in @[@-1,@101,@1.5,@YES,@"25",[NSNull null],@(NAN)]) {
        NSError *error=nil;assert(!IOSUsePlayConfigureAudio(@{@"volume":invalid},&error));assert(error);
        assert([IOSUsePlayAudioState()[@"volume"] intValue]==37);
    }
    assert(!IOSUsePlayConfigureAudio(@{@"muted":@1},NULL));
    assert(!IOSUsePlayConfigureAudio(@{@"volume":@20,@"unknown":@1},NULL));
    assert([IOSUsePlayAudioState()[@"volume"] intValue]==37);
    assert(IOSUsePlayConfigureAudio(@{@"muted":@NO},NULL));
    assert([IOSUsePlayAudioState()[@"effectiveVolume"] intValue]==37);
    puts("[audio] PCM formats, mute/restore and invalid configuration PASS");
}
static void fill(AudioBufferList *out) {
    for(UInt32 i=0;i<out->mNumberBuffers;i++) {float *p=out->mBuffers[i].mData;if(p)for(UInt32 j=0;j<out->mBuffers[i].mDataByteSize/4;j++)p[j]=(j%2?.01f:-.01f);}
}
static OSStatus render(AudioObjectID d,const AudioTimeStamp*n,const AudioBufferList*i,const AudioTimeStamp*it,AudioBufferList*o,const AudioTimeStamp*ot,void*c){fill(o);return noErr;}
static void queueFill(void *data,AudioQueueRef queue,AudioQueueBufferRef buffer) {
    if(atomic_load(&queueStopping)) return;
    buffer->mAudioDataByteSize=buffer->mAudioDataBytesCapacity;
    float *p=buffer->mAudioData;for(UInt32 i=0;i<buffer->mAudioDataByteSize/4;i++)p[i]=i%2?.01f:-.01f;
    OSStatus result=AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
    assert(result==noErr || atomic_load(&queueStopping));
}
int main(int argc,char **argv) { @autoreleasepool {
    IOSUsePlayAudioInitialize();
    if(argc<2 || !strcmp(argv[1],"unit")){unitTests();return 0;}
    NSString *mode=@(argv[1]); NSURL *tone=[NSURL fileURLWithPath:@(argv[2])];
    id player=nil;AudioDeviceIOProcID proc=NULL, secondProc=NULL;AudioQueueRef queue=NULL;AudioObjectID device=0;
    AudioObjectPropertyAddress address={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=sizeof(device);
    assert(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,&device)==noErr && device);
    configure(100,NO);
    if([mode isEqual:@"player"]||[mode isEqual:@"control"]) {
        AVAudioPlayer *p=[[AVAudioPlayer alloc] initWithContentsOfURL:tone error:NULL];p.numberOfLoops=-1;p.volume=.4;assert([p play]);player=p;
    } else if([mode isEqual:@"avplayer"]) {AVPlayer *p=[AVPlayer playerWithURL:tone];[p play];player=p;}
    else if([mode isEqual:@"engine"]) {
        AVAudioEngine *engine=[AVAudioEngine new];AVAudioFormat *f=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        AVAudioSourceNode *source=[[AVAudioSourceNode alloc] initWithFormat:f renderBlock:^OSStatus(BOOL *silent,const AudioTimeStamp *ts,AVAudioFrameCount frames,AudioBufferList *out){fill(out);return noErr;}];
        [engine attachNode:source];[engine connect:source to:engine.mainMixerNode format:f];assert([engine startAndReturnError:NULL]);player=engine;
    } else if([mode isEqual:@"queue"]) {
        AudioStreamBasicDescription f={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=8,.mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
        assert(AudioQueueNewOutput(&f,queueFill,NULL,NULL,NULL,0,&queue)==noErr);
        for(int i=0;i<3;i++){AudioQueueBufferRef b;assert(AudioQueueAllocateBuffer(queue,8192,&b)==noErr);queueFill(NULL,queue,b);}assert(AudioQueueStart(queue,NULL)==noErr);
    } else if([mode isEqual:@"dual"]) {
        assert(AudioDeviceCreateIOProcID(device,render,NULL,&proc)==noErr);
        assert(AudioDeviceCreateIOProcID(device,render,NULL,&secondProc)==noErr);
        assert(AudioDeviceStart(device,proc)==noErr);assert(AudioDeviceStart(device,secondProc)==noErr);
        assert([IOSUsePlayAudioState()[@"outputCallbacks"] intValue]>=2);
    }
    else if([mode isEqual:@"callback"]) {assert(AudioDeviceCreateIOProcID(device,render,NULL,&proc)==noErr);assert(AudioDeviceStart(device,proc)==noErr);}
    else if([mode isEqual:@"block"]) {assert(AudioDeviceCreateIOProcIDWithBlock(&proc,device,NULL,^(const AudioTimeStamp*n,const AudioBufferList*i,const AudioTimeStamp*it,AudioBufferList*o,const AudioTimeStamp*ot){fill(o);})==noErr);assert(AudioDeviceStart(device,proc)==noErr);}
    else abort();
    checkGain(1);
    if([mode isEqual:@"control"]){for(int i=0;i<80;i++){waitSeconds(.1);checkGain(1);}}
    else {
        configure(25,NO);checkGain(.25);configure(25,YES);checkGain(0);
        configure(60,YES);checkGain(0);IOSUsePlayConfigureAudio(@{@"muted":@NO},NULL);checkGain(.6);
        configure(0,NO);checkGain(0);configure(100,NO);checkGain(1);
    }
    if([player isKindOfClass:AVAudioPlayer.class]){assert(((AVAudioPlayer*)player).volume==.4f);[(AVAudioPlayer*)player stop];}
    if([player isKindOfClass:AVPlayer.class])[(AVPlayer*)player pause];
    if([player isKindOfClass:AVAudioEngine.class])[(AVAudioEngine*)player stop];
    if(queue){atomic_store(&queueStopping,true);AudioQueueStop(queue,true);AudioQueueDispose(queue,true);}
    if(proc){AudioDeviceStop(device,proc);assert(AudioDeviceDestroyIOProcID(device,proc)==noErr);}
    if(secondProc){configure(25,NO);checkGain(.25);AudioDeviceStop(device,secondProc);assert(AudioDeviceDestroyIOProcID(device,secondProc)==noErr);}
    printf("[audio] %s output gain/mute/isolation PASS\n",argv[1]);
    return 0;
}}
