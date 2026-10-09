// Private rendezvous layout shared by the native broker and runtime adapter.
enum {
    RuntimeMetal, RuntimeCompiler, RuntimeSurface, RuntimeTrust,
    RuntimeTCC, RuntimePhotos, RuntimeLaunchServices, RuntimeUserNotification, RuntimeKeychain, RuntimeEndpointCount
};
enum {
    RuntimeCompilerReady = 300, RuntimeTrustReady, RuntimeTCCReady,
    RuntimePhotosReady, RuntimeNotifyReady, RuntimeLaunchServicesReady, RuntimeKeychainReady
};
