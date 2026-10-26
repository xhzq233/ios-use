#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// App-process output gain; never writes a hardware/system volume property.
FOUNDATION_EXPORT void IOSUsePlayAudioInitialize(void);
FOUNDATION_EXPORT NSDictionary *IOSUsePlayAudioState(void);
FOUNDATION_EXPORT NSDictionary * _Nullable IOSUsePlayConfigureAudio(NSDictionary *changes, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
