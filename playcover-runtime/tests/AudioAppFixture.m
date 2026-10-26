#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <math.h>

// A small real iPhoneOS App for managed-slot config/restart acceptance. It uses
// synthetic, quiet PCM only; no microphone, network, account or private data.
@interface IOSUseAudioFixtureDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) AVAudioPlayer *player;
@end
@implementation IOSUseAudioFixtureDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSMutableData *wave=[NSMutableData data];
    uint32_t rate=48000,bytes=rate*2,size=36+bytes,fmtSize=16,byteRate=rate*2;
    uint16_t pcm=1,channels=1,align=2,bits=16;
    [wave appendBytes:"RIFF" length:4];[wave appendBytes:&size length:4];[wave appendBytes:"WAVEfmt " length:8];
    [wave appendBytes:&fmtSize length:4];[wave appendBytes:&pcm length:2];[wave appendBytes:&channels length:2];
    [wave appendBytes:&rate length:4];[wave appendBytes:&byteRate length:4];[wave appendBytes:&align length:2];[wave appendBytes:&bits length:2];
    [wave appendBytes:"data" length:4];[wave appendBytes:&bytes length:4];
    for(unsigned i=0;i<rate;i++){int16_t n=(int16_t)(300*sin(2*M_PI*440*i/rate));[wave appendBytes:&n length:2];}
    self.player=[[AVAudioPlayer alloc] initWithData:wave error:NULL];self.player.numberOfLoops=-1;self.player.volume=.4f;
    [self.player play];
    UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(20,130,390,180)];label.numberOfLines=0;
    label.text=@"Audio fixture playing\nApp player volume: 40%\nUse config --mac --volume / --mute";
    [vc.view addSubview:label];
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=vc;[self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(IOSUseAudioFixtureDelegate.class));}}
