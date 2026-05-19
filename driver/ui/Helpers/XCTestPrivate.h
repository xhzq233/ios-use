#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>

/// Calls XCUICoordinate's private press+drag with numeric velocity.
void XCPressAndDrag(XCUICoordinate *start, XCUICoordinate *end,
                    double pressDuration, double velocity, double holdDuration);

XCUIApplication * _Nullable GetActiveApplication(void);

/// Takes a raw snapshot of an XCUIElement via `snapshotWithError:`.
id _Nullable SnapshotOfElement(XCUIElement * _Nonnull element);

/// Best-effort keyboard Clear key event (WDA-style IOHID shortcut).
BOOL XCPerformKeyboardClear(void);

/// WDA-style synthesized text input using XCSynthesizedEventRecord +
/// XCPointerEventPath(initForTextInput). Returns NO and assigns `error`
/// when the event synthesizer reports a failure.
BOOL XCFBTypeText(NSString * _Nonnull text, NSUInteger typingSpeed, NSError * _Nullable * _Nullable error);

/// WDA-style synthesized tap/long press using XCSynthesizedEventRecord +
/// XCPointerEventPath(initForTouchAtPoint:offset:) + liftUpAtOffset:.
BOOL XCSynthesizeTapAtPoint(CGPoint point, NSError * _Nullable * _Nullable error);
BOOL XCSynthesizeLongPressAtPoint(CGPoint point, double duration, NSError * _Nullable * _Nullable error);

/// Captures a screenshot through XCTest daemon `_XCT_requestScreenshot`
/// using JPEG encoding with the provided compression quality.
NSData * _Nullable XCRequestScreenshotJPEG(double compressionQuality, NSError * _Nullable * _Nullable error);

/// Matches WDA's defaultTypingFrequency:
/// NSUserDefaults["com.apple.xctest.iOSMaximumTypingFrequency"] or 60.
NSUInteger XCDefaultTypingFrequency(void);

/// Identity compare of two snapshot-like objects via XCTest private
/// `_matchesElement:` selector. Returns NO if the selector is not available.
/// Doc §5.4.
BOOL SnapshotMatchesElement(id _Nonnull a, id _Nonnull b);

// MARK: - SafeSnapshot

/// ObjC wrapper around raw XCElementSnapshot.
/// NSString properties are [copy]'d to avoid dangling references after autorelease pool drain.
/// Caches raw snapshot on app.lastSnapshot (XCUIElement built-in retain property).
/// Reference: WDA XCUIElement+FBUtilities.m:58 — self.lastSnapshot = snapshot
@interface SafeSnapshot : NSObject

+ (instancetype _Nullable)snapshotOfApp:(XCUIApplication * _Nonnull)app;
- (instancetype _Nonnull)initWithRaw:(id _Nonnull)raw
                            appFrame:(CGRect)appFrame;

@property (nonatomic, readonly, nonnull) id raw;
@property (nonatomic, readonly, nullable) NSString *label;
@property (nonatomic, readonly, nullable) NSString *identifier;
@property (nonatomic, readonly, nullable) NSString *baseDisplayLabel;
@property (nonatomic, readonly, nullable) NSString *displayLabel;
@property (nonatomic, readonly, nullable) NSString *value;
@property (nonatomic, readonly, nullable) NSString *placeholderValue;
@property (nonatomic, readonly) NSUInteger elementType;
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) CGRect visibleFrame;
@property (nonatomic, readonly) BOOL isVisible;
@property (nonatomic, readonly) BOOL isEnabled;
@property (nonatomic, readonly) BOOL isSelected;
@property (nonatomic, readonly) BOOL hasFocus;
@property (nonatomic, readonly) BOOL hasKeyboardFocus;
@property (nonatomic, readonly, nonnull) NSArray<SafeSnapshot *> *children;
/// Parent snapshot lazily wrapped from raw `parent`. Returns nil for the root.
@property (nonatomic, readonly, nullable) SafeSnapshot *parent;
/// Flat list of every descendant (excluding self). Rooted traversal.
@property (nonatomic, readonly, nonnull) NSArray<SafeSnapshot *> *allDescendants;

- (void)setAutoLabelIfDisplayLabelNil:(NSString * _Nonnull)label;
- (void)setDisplayLabelAliasIfNeeded:(NSString * _Nonnull)label;

@end
