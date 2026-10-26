#import "IOSUsePlayAudio.h"
#import <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>

// HAL output callbacks cover players/engines/queues without stacking gain at
// each player layer. Keep the realtime path free of locks, allocations and ObjC.
static atomic_uint audioSetting = 100; // low 8 bits: volume, bit 8: muted
static pthread_mutex_t registryLock = PTHREAD_MUTEX_INITIALIZER;
@class IOSUsePlayAudioContext;
static NSMutableDictionary<NSString *, IOSUsePlayAudioContext *> *contexts;
static _Thread_local unsigned creationDepth;
static const unsigned maxBuffers = 64;
typedef NS_ENUM(unsigned, SampleKind) { Unsupported, Float32PCM, Float64PCM, Int16PCM, Int32PCM };

static SampleKind sampleKind(AudioStreamBasicDescription f) {
    if (f.mFormatID != kAudioFormatLinearPCM ||
        (f.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        !(f.mFormatFlags & kAudioFormatFlagIsPacked)) return Unsupported;
    UInt32 channels = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f.mChannelsPerFrame;
    if (!channels || f.mBytesPerFrame != channels * (f.mBitsPerChannel / 8)) return Unsupported;
    if (f.mFormatFlags & kAudioFormatFlagIsFloat) {
        if (f.mBitsPerChannel == 32) return Float32PCM;
        if (f.mBitsPerChannel == 64) return Float64PCM;
    } else if (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        if (f.mBitsPerChannel == 16) return Int16PCM;
        if (f.mBitsPerChannel == 32) return Int32PCM;
    }
    return Unsupported;
}

static void scaleBuffer(AudioBuffer *buffer, SampleKind kind, float gain) {
    if (!buffer->mData || gain == 1 || kind == Unsupported) return;
    if (gain == 0) { memset(buffer->mData, 0, buffer->mDataByteSize); return; }
    switch (kind) {
        case Float32PCM: { float *p = buffer->mData; for (UInt32 i=0;i<buffer->mDataByteSize/sizeof(*p);i++) p[i] *= gain; break; }
        case Float64PCM: { double *p = buffer->mData; for (UInt32 i=0;i<buffer->mDataByteSize/sizeof(*p);i++) p[i] *= gain; break; }
        case Int16PCM: { int16_t *p = buffer->mData; for (UInt32 i=0;i<buffer->mDataByteSize/sizeof(*p);i++) p[i] = (int16_t)((double)p[i]*gain); break; }
        case Int32PCM: { int32_t *p = buffer->mData; for (UInt32 i=0;i<buffer->mDataByteSize/sizeof(*p);i++) p[i] = (int32_t)((double)p[i]*gain); break; }
        default: break;
    }
}

@interface IOSUsePlayAudioContext : NSObject {
@public
    AudioDeviceIOProc callback;
    void *clientData;
    atomic_uint formats[64];
    atomic_uint bufferCount;
    atomic_uint formatGeneration;
    atomic_bool unsupported;
}
@property AudioObjectID device;
@property NSArray<NSNumber *> *streams;
@property(copy) AudioObjectPropertyListenerBlock formatListener;
- (void)refreshFormats;
- (void)removeListeners;
@end

static dispatch_queue_t audioQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("io.ios-use.audio", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

@implementation IOSUsePlayAudioContext
- (void)refreshFormats {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    unsigned kinds[64] = {0}, count = 0;
    BOOL bad = NO;
    if (AudioObjectGetPropertyDataSize(self.device, &address, 0, NULL, &size) != noErr || size > 64*sizeof(AudioStreamID)) {
        bad = YES;
    } else {
        AudioStreamID streams[64];
        if (AudioObjectGetPropertyData(self.device, &address, 0, NULL, &size, streams) != noErr) bad = YES;
        else for (UInt32 i=0; i<size/sizeof(AudioStreamID); i++) {
            AudioStreamBasicDescription format = {0};
            UInt32 bytes = sizeof(format);
            AudioObjectPropertyAddress a = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            if (AudioObjectGetPropertyData(streams[i], &a, 0, NULL, &bytes, &format) != noErr) { bad=YES; break; }
            SampleKind kind = sampleKind(format);
            unsigned buffers = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? format.mChannelsPerFrame : 1;
            if (kind == Unsupported || buffers > maxBuffers-count) bad=YES;
            if (buffers > maxBuffers-count) break;
            for (unsigned b=0;b<buffers;b++) kinds[count++] = kind;
        }
    }
    // Invalidate while replacing the format map. A rare format transition can
    // pass one buffer through, but cannot reinterpret samples using a new type.
    atomic_fetch_add(&formatGeneration, 1);
    atomic_store(&bufferCount, 0);
    for (unsigned i=0;i<maxBuffers;i++) atomic_store(&formats[i], kinds[i]);
    atomic_store(&unsupported, bad);
    atomic_store(&bufferCount, count);
    atomic_fetch_add(&formatGeneration, 1);
}
- (void)removeListeners {
    if (!self.formatListener) return;
    AudioObjectPropertyAddress a = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    for (NSNumber *stream in self.streams) AudioObjectRemovePropertyListenerBlock(stream.unsignedIntValue, &a, audioQueue(), self.formatListener);
    self.formatListener = nil;
}
- (void)dealloc { [self removeListeners]; }
@end

static IOSUsePlayAudioContext *makeContext(AudioObjectID device) {
    IOSUsePlayAudioContext *context = [IOSUsePlayAudioContext new];
    context.device = device;
    [context refreshFormats];
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioStreamID streams[64]; UInt32 size=sizeof(streams);
    NSMutableArray *ids = [NSMutableArray array];
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, streams) == noErr) {
        __weak IOSUsePlayAudioContext *weak = context;
        context.formatListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) { [weak refreshFormats]; };
        a = (AudioObjectPropertyAddress){ kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        for (UInt32 i=0;i<size/sizeof(AudioStreamID);i++) {
            if (AudioObjectAddPropertyListenerBlock(streams[i], &a, audioQueue(), context.formatListener) == noErr) [ids addObject:@(streams[i])];
        }
    }
    context.streams = ids;
    return context;
}

#ifdef IOS_USE_PLAY_AUDIO_TESTING
static atomic_ulong observedCallbacks;
static _Atomic(double) beforeEnergy, afterEnergy;
#endif
static void scaleOutput(IOSUsePlayAudioContext *context, AudioBufferList *output) {
    unsigned setting = atomic_load_explicit(&audioSetting, memory_order_relaxed);
    float gain = (setting & 256) ? 0 : (setting & 255)/100.0f;
#ifndef IOS_USE_PLAY_AUDIO_TESTING
    if (gain == 1) return;
#endif
    unsigned generation = atomic_load(&context->formatGeneration);
    if (generation & 1) return;
    unsigned count = atomic_load(&context->bufferCount);
    unsigned kinds[64];
    for (unsigned i=0;i<count;i++) kinds[i]=atomic_load(&context->formats[i]);
    if (generation != atomic_load(&context->formatGeneration)) return;
    if (!output || count != output->mNumberBuffers) {
        if (output && output->mNumberBuffers) atomic_store(&context->unsupported, true);
        return;
    }
#ifdef IOS_USE_PLAY_AUDIO_TESTING
    double before=0,after=0;
#endif
    for (UInt32 i=0;i<output->mNumberBuffers;i++) {
        SampleKind kind = kinds[i];
#ifdef IOS_USE_PLAY_AUDIO_TESTING
        AudioBuffer b=output->mBuffers[i];
        if (kind==Float32PCM && b.mData) for(UInt32 j=0;j<b.mDataByteSize/4;j++) before+=((float*)b.mData)[j]*((float*)b.mData)[j];
#endif
        scaleBuffer(&output->mBuffers[i], kind, gain);
#ifdef IOS_USE_PLAY_AUDIO_TESTING
        if (kind==Float32PCM && b.mData) for(UInt32 j=0;j<b.mDataByteSize/4;j++) after+=((float*)b.mData)[j]*((float*)b.mData)[j];
#endif
    }
#ifdef IOS_USE_PLAY_AUDIO_TESTING
    if(before>0){atomic_store(&beforeEnergy,before);atomic_store(&afterEnergy,after);atomic_fetch_add(&observedCallbacks,1);}
#endif
}

static OSStatus audioCallback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *data) {
    __unsafe_unretained IOSUsePlayAudioContext *context = (__bridge IOSUsePlayAudioContext *)data;
    OSStatus result = context->callback(device, now, input, inputTime, output, outputTime, context->clientData);
    scaleOutput(context, output);
    return result;
}
static NSString *contextKey(AudioObjectID device, AudioDeviceIOProcID proc) {
    return [NSString stringWithFormat:@"%u:%p", device, proc];
}
static void remember(AudioDeviceIOProcID proc, IOSUsePlayAudioContext *context) {
    pthread_mutex_lock(&registryLock);
    if (!contexts) contexts=[NSMutableDictionary dictionary];
    contexts[contextKey(context.device, proc)]=context;
    pthread_mutex_unlock(&registryLock);
}
static OSStatus createProc(AudioObjectID device, AudioDeviceIOProc proc, void *data, AudioDeviceIOProcID *out) {
    if (creationDepth || !proc || !out) return AudioDeviceCreateIOProcID(device,proc,data,out);
    IOSUsePlayAudioContext *context = makeContext(device);
    context->callback=proc; context->clientData=data;
    creationDepth++;
    OSStatus result=AudioDeviceCreateIOProcID(device,audioCallback,(__bridge void *)context,out);
    creationDepth--;
    if (result==noErr) remember(*out,context);
    return result;
}
static OSStatus createBlock(AudioDeviceIOProcID *out, AudioObjectID device, dispatch_queue_t queue, AudioDeviceIOBlock block) {
    if (creationDepth || !block || !out) return AudioDeviceCreateIOProcIDWithBlock(out,device,queue,block);
    IOSUsePlayAudioContext *context=makeContext(device);
    creationDepth++;
    OSStatus result=AudioDeviceCreateIOProcIDWithBlock(out,device,queue,^(const AudioTimeStamp *now,const AudioBufferList *input,
        const AudioTimeStamp *inputTime,AudioBufferList *output,const AudioTimeStamp *outputTime) {
        block(now,input,inputTime,output,outputTime); scaleOutput(context,output);
    });
    creationDepth--;
    if(result==noErr) remember(*out,context);
    return result;
}
static OSStatus destroyProc(AudioObjectID device,AudioDeviceIOProcID proc) {
    OSStatus result=AudioDeviceDestroyIOProcID(device,proc);
    if(result==noErr) {
        pthread_mutex_lock(&registryLock);
        IOSUsePlayAudioContext *context=contexts[contextKey(device, proc)];
        [contexts removeObjectForKey:contextKey(device, proc)];
        pthread_mutex_unlock(&registryLock);
        [context removeListeners];
    }
    return result;
}
#define AUDIO_INTERPOSE(replacement, original) \
__attribute__((used)) static struct { const void *r; const void *o; } interpose_##replacement \
__attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original };
AUDIO_INTERPOSE(createProc,AudioDeviceCreateIOProcID)
AUDIO_INTERPOSE(createBlock,AudioDeviceCreateIOProcIDWithBlock)
AUDIO_INTERPOSE(destroyProc,AudioDeviceDestroyIOProcID)

NSDictionary *IOSUsePlayAudioState(void) {
    unsigned setting=atomic_load(&audioSetting);
    pthread_mutex_lock(&registryLock);
    NSUInteger unsupported=0;
    for (IOSUsePlayAudioContext *context in contexts.allValues) if(atomic_load(&context->unsupported)) unsupported++;
    NSUInteger outputs=contexts.count;
    pthread_mutex_unlock(&registryLock);
    return @{ @"volume": @(setting&255), @"muted": (setting&256) ? @YES : @NO,
        @"effectiveVolume": @((setting&256)?0:(setting&255)), @"outputCallbacks": @(outputs),
        @"unsupportedOutputs": @(unsupported) };
}
NSDictionary *IOSUsePlayConfigureAudio(NSDictionary *changes, NSError **error) {
    unsigned old=atomic_load(&audioSetting),volume=old&255; BOOL muted=(old&256)!=0;
    for(NSString *key in changes) {
        id v=changes[key];
        BOOL boolean=[v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID();
        if([key isEqual:@"volume"] && [v isKindOfClass:NSNumber.class] && !boolean && isfinite([v doubleValue]) &&
            [v doubleValue]>=0 && [v doubleValue]<=100 && floor([v doubleValue])==[v doubleValue]) volume=[v unsignedIntValue];
        else if([key isEqual:@"muted"] && boolean) muted=[v boolValue];
        else { if(error)*error=[NSError errorWithDomain:@"io.ios-use.audio" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Audio volume must be an integer from 0 to 100 and muted must be a boolean"}]; return nil; }
    }
    atomic_store(&audioSetting,volume|(muted?256:0));
    return IOSUsePlayAudioState();
}
void IOSUsePlayAudioInitialize(void) {
    const char *v=getenv("IOS_USE_MAC_VOLUME"),*m=getenv("IOS_USE_MAC_MUTE");
    unsigned volume=100;
    if(v){char *end;long n=strtol(v,&end,10);if(*v && !*end && n>=0 && n<=100)volume=(unsigned)n;}
    atomic_store(&audioSetting,volume|((m && !strcmp(m,"1"))?256:0));
}
#ifdef IOS_USE_PLAY_AUDIO_TESTING
NSDictionary *IOSUsePlayAudioTestMeter(void) {
    double before=atomic_load(&beforeEnergy),after=atomic_load(&afterEnergy);
    return @{ @"callbacks": @(atomic_load(&observedCallbacks)), @"ratio": @(before>0?sqrt(after/before):-1) };
}
void IOSUsePlayAudioTestScale(AudioBuffer *buffer, AudioStreamBasicDescription format, float gain) { scaleBuffer(buffer,sampleKind(format),gain); }
#endif
