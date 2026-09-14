#import <XCTest/XCTest.h>
#import "../ui/Helpers/XCTestPrivate.h"

@interface LifetimeRawSnapshot : NSObject
@property (nonatomic, copy) NSArray<LifetimeRawSnapshot *> *children;
@property (nonatomic, weak) LifetimeRawSnapshot *parent;
- (instancetype)initWithChildren:(NSArray<LifetimeRawSnapshot *> *)children;
@end

@implementation LifetimeRawSnapshot
- (instancetype)initWithChildren:(NSArray<LifetimeRawSnapshot *> *)children {
    self = [super init];
    if (self) {
        _children = [children copy];
        for (LifetimeRawSnapshot *child in children) {
            child.parent = self;
        }
    }
    return self;
}
@end

@interface SafeSnapshotLifetimeTests : XCTestCase
@end

@implementation SafeSnapshotLifetimeTests

- (void)testTraversedTreeReleasesWrappersAndRawSnapshots {
    __weak SafeSnapshot *releasedRoot;
    __weak SafeSnapshot *releasedChild;
    __weak SafeSnapshot *releasedLeaf;
    __weak LifetimeRawSnapshot *releasedRawRoot;
    __weak LifetimeRawSnapshot *releasedRawChild;
    __weak LifetimeRawSnapshot *releasedRawLeaf;

    @autoreleasepool {
        LifetimeRawSnapshot *rawLeaf = [[LifetimeRawSnapshot alloc] initWithChildren:@[]];
        LifetimeRawSnapshot *rawChild = [[LifetimeRawSnapshot alloc] initWithChildren:@[rawLeaf]];
        LifetimeRawSnapshot *rawRoot = [[LifetimeRawSnapshot alloc] initWithChildren:@[rawChild]];
        SafeSnapshot *root = [[SafeSnapshot alloc] initWithRaw:rawRoot appFrame:CGRectZero];
        NSArray<SafeSnapshot *> *descendants = root.allDescendants;
        XCTAssertEqual(descendants.count, 2u);
        SafeSnapshot *child = descendants[0];
        SafeSnapshot *leaf = descendants[1];
        XCTAssertEqual(root.children.firstObject, child);
        XCTAssertEqual(child.children.firstObject, leaf);
        XCTAssertEqual(child.parent, root);
        XCTAssertEqual(leaf.parent, child);
        XCTAssertEqual(leaf.parent.parent, root);
        XCTAssertNil(root.parent);

        releasedRoot = root;
        releasedChild = child;
        releasedLeaf = leaf;
        releasedRawRoot = rawRoot;
        releasedRawChild = rawChild;
        releasedRawLeaf = rawLeaf;
    }

    XCTAssertNil(releasedRoot);
    XCTAssertNil(releasedChild);
    XCTAssertNil(releasedLeaf);
    XCTAssertNil(releasedRawRoot);
    XCTAssertNil(releasedRawChild);
    XCTAssertNil(releasedRawLeaf);
}

- (void)testStandaloneRawParentSurvivesPoolAndReleasesAfterDescendant {
    SafeSnapshot *leaf;
    __weak SafeSnapshot *releasedParent;
    __weak SafeSnapshot *releasedGrandparent;
    __weak SafeSnapshot *releasedRewrappedLeaf;
    __weak LifetimeRawSnapshot *releasedRawRoot;
    __weak LifetimeRawSnapshot *releasedRawLeaf;

    @autoreleasepool {
        LifetimeRawSnapshot *rawLeaf = [[LifetimeRawSnapshot alloc] initWithChildren:@[]];
        LifetimeRawSnapshot *rawParent = [[LifetimeRawSnapshot alloc] initWithChildren:@[rawLeaf]];
        LifetimeRawSnapshot *rawRoot = [[LifetimeRawSnapshot alloc] initWithChildren:@[rawParent]];
        leaf = [[SafeSnapshot alloc] initWithRaw:rawLeaf appFrame:CGRectZero];
        releasedParent = leaf.parent;
        releasedGrandparent = leaf.parent.parent;
        XCTAssertEqual(leaf.parent.raw, rawParent);
        XCTAssertEqual(leaf.parent.parent.raw, rawRoot);

        // Traversing downward from a lazily owned ancestor must not add a cycle.
        SafeSnapshot *rewrappedLeaf = leaf.parent.children.firstObject;
        XCTAssertEqual(rewrappedLeaf.raw, leaf.raw);
        XCTAssertNotEqual(rewrappedLeaf, leaf);
        XCTAssertEqual(rewrappedLeaf.parent, leaf.parent);
        XCTAssertEqual(rewrappedLeaf.parent.parent, leaf.parent.parent);
        XCTAssertEqual(leaf.parent.parent.allDescendants.count, 2u);
        releasedRewrappedLeaf = rewrappedLeaf;
        releasedRawRoot = rawRoot;
        releasedRawLeaf = rawLeaf;
    }

    @autoreleasepool {
        XCTAssertNotNil(releasedParent);
        XCTAssertNotNil(releasedGrandparent);
        XCTAssertEqual(leaf.parent, releasedParent);
        XCTAssertEqual(leaf.parent.parent, releasedGrandparent);
        XCTAssertEqual(releasedRewrappedLeaf.parent, releasedParent);
        XCTAssertNil(leaf.parent.parent.parent);
        leaf = nil;
    }

    XCTAssertNil(releasedParent);
    XCTAssertNil(releasedGrandparent);
    XCTAssertNil(releasedRewrappedLeaf);
    XCTAssertNil(releasedRawRoot);
    XCTAssertNil(releasedRawLeaf);
}

@end
