#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

@class SWImageNode;
@class SWRecognizedText;
@class SWRecordingSession;
@class SWVideoModel;
@class SWImageHandle;

@protocol SWImageExports <JSExport>
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) double height;
@property (nonatomic, readonly) double scale;
@property (nonatomic, readonly) NSArray<NSNumber *> *frame;
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly) double timestamp;
@property (nonatomic, readonly) NSInteger pixelWidth;
@property (nonatomic, readonly) NSInteger pixelHeight;
- (JSValue *)crop:(double)x :(double)y :(double)width :(double)height;
- (SWImageHandle *)resize:(NSInteger)width :(NSInteger)height;
- (SWImageHandle *)rotate:(double)degrees;
- (SWImageHandle *)grayscale;
- (SWImageHandle *)threshold:(NSInteger)level;
- (SWImageHandle *)mask:(NSInteger)lowRed :(NSInteger)lowGreen :(NSInteger)lowBlue :(NSInteger)highRed :(NSInteger)highGreen :(NSInteger)highBlue;
- (SWImageHandle *)invert;
- (SWImageHandle *)dilate:(NSInteger)radius;
- (SWImageHandle *)erode:(NSInteger)radius;
- (JSValue *)showBytes;
@end

@interface SWImageHandle : NSObject <SWImageExports>
@property (nonatomic, readonly) SWImageNode *node;

- (instancetype)initWithNode:(SWImageNode *)node;
@end

@protocol SWRecordingExports <JSExport>
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) double start;
@end

@interface SWRecordingHandle : NSObject <SWRecordingExports>
@property (nonatomic, readonly) SWRecordingSession *session;

- (instancetype)initWithSession:(SWRecordingSession *)session;
@end

@protocol SWVideoExports <JSExport>
@property (nonatomic, readonly) NSString *info;
- (SWImageHandle *)frame:(double)time;
@end

@interface SWVideoHandle : NSObject <SWVideoExports>
@property (nonatomic, readonly) SWVideoModel *model;

- (instancetype)initWithModel:(SWVideoModel *)model;
@end

@protocol SWTextExports <JSExport>
- (JSValue *)boundingBox:(NSInteger)line :(NSInteger)candidate :(NSInteger)start :(NSInteger)end;
@end

@interface SWTextHandle : NSObject <SWTextExports>
- (instancetype)initWithText:(SWRecognizedText *)text;
@end
