#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class UIView;

typedef BOOL (^IOSUsePlayRuntimeCancellationCheck)(void);

typedef NS_ENUM(NSInteger, IOSUsePlayRuntimeWebAccessibilityAction) {
    IOSUsePlayRuntimeWebAccessibilityActionActivate = 1,
    IOSUsePlayRuntimeWebAccessibilityActionFocusInput = 2,
};

/// Executes a fresh UIKit accessibility traversal and returns the command's
/// `dom` object. The function may be called off-main; UIKit work is marshalled
/// to the main queue. On failure, `commandError` contains the complete JSON
/// error object (`code`, `message`, and optional structured `details`).
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeDOMCommand(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> * _Nullable * _Nullable commandError
);

/// Polls fresh UIKit accessibility snapshots for the requested selector and
/// returns the command's `waitFor` object.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeWaitForCommand(
    NSDictionary<NSString *, id> *arguments,
    IOSUsePlayRuntimeCancellationCheck cancellationCheck,
    NSDictionary<NSString *, id> * _Nullable * _Nullable commandError
);

/// Returns the exact value and selection of the active public HTML text
/// control that contains `hitView`. The JavaScript is Runtime-owned and fixed;
/// callers cannot provide scripts or selectors.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeWebInputState(
    UIView *hitView,
    NSDictionary<NSString *, id> * _Nullable bridgedElement,
    NSString * _Nullable * _Nullable failureMessage
);

/// Returns YES for the closed serialized shape used by the Runtime-owned
/// WKWebView accessibility bridge. Actual actions additionally require the
/// current in-memory proxy record, so a stale bridged target fails rather than
/// silently falling back to synthetic touch.
FOUNDATION_EXPORT BOOL
IOSUsePlayRuntimeIsWebAccessibilityElement(
    NSDictionary<NSString *, id> *element
);

/// Resolves the exact weak live identity recorded while building the current
/// fresh DOM generation. The registry is main-thread-only, is replaced for
/// every fresh snapshot, and never serializes object addresses. Either output
/// may be nil when its weak object has already gone away.
FOUNDATION_EXPORT BOOL
IOSUsePlayRuntimeDOMResolveLiveIdentity(
    NSDictionary<NSString *, id> *element,
    id _Nullable * _Nullable object,
    UIView * _Nullable * _Nullable interactionView,
    NSString * _Nullable * _Nullable nativeAlertActionLabel
);

/// Revalidates and performs one bounded accessibility action against the
/// exact bridged element from a fresh Runtime DOM snapshot. The bridge owns
/// its JavaScript and accepts neither caller scripts nor CSS/XPath selectors.
/// On success the returned evidence names the bridge backend explicitly.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimePerformWebAccessibilityAction(
    UIView *hitView,
    NSDictionary<NSString *, id> *element,
    IOSUsePlayRuntimeWebAccessibilityAction action,
    NSString * _Nullable * _Nullable failureCode,
    NSString * _Nullable * _Nullable failureMessage
);

NS_ASSUME_NONNULL_END
