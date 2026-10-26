// End-to-end HTTPS observation, using normal NSURLSession authentication.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

@interface RuntimeNetworkDelegate : NSObject <NSURLSessionDelegate>
@end
@implementation RuntimeNetworkDelegate
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (trust) {
        CFErrorRef error = NULL;
        BOOL valid = SecTrustEvaluateWithError(trust, &error);
        fprintf(stderr, "[network] host=%s valid=%d error=%ld\n", challenge.protectionSpace.host.UTF8String,
                valid, error ? (long)CFErrorGetCode(error) : 0);
        if (error) CFRelease(error);
    }
    completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 15;
        configuration.timeoutIntervalForResource = 20;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
            delegate:[RuntimeNetworkDelegate new] delegateQueue:nil];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@(argv[1])]];
        request.HTTPMethod = @"HEAD";
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int result = 52;
        [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            fprintf(stderr, "[network] HTTP=%ld error=%s/%ld\n", (long)status,
                    error ? error.domain.UTF8String : "none", (long)error.code);
            result = !error && status >= 200 && status < 400 ? 0 : 52;
            dispatch_semaphore_signal(done);
        }] resume];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25*NSEC_PER_SEC))) return 53;
        return result;
    }
}
