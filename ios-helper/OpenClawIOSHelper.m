#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <math.h>

static void WriteJSON(id value, NSFileHandle *handle) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!data) {
        NSString *fallback = [NSString stringWithFormat:
            @"{\"ok\":false,\"error\":{\"code\":\"SERIALIZATION_FAILED\",\"message\":\"%@\"}}\n",
            error.localizedDescription ?: @"unknown serialization error"];
        [handle writeData:[fallback dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    [handle writeData:data];
    [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSDictionary *Failure(NSString *code, NSString *message) {
    return @{
        @"ok": @NO,
        @"error": @{
            @"code": code ?: @"UNAVAILABLE",
            @"message": message ?: @"unknown error",
        },
    };
}

static NSString *PositionName(AVCaptureDevicePosition position) {
    switch (position) {
        case AVCaptureDevicePositionFront:
            return @"front";
        case AVCaptureDevicePositionBack:
            return @"back";
        default:
            return @"unspecified";
    }
}

static NSArray<AVCaptureDevice *> *VideoDevices(void) {
    AVCaptureDeviceDiscoverySession *session =
        [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[
                AVCaptureDeviceTypeBuiltInWideAngleCamera,
                AVCaptureDeviceTypeBuiltInTelephotoCamera,
                AVCaptureDeviceTypeBuiltInDualCamera,
            ]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionUnspecified];
    return session.devices ?: @[];
}

static NSDictionary *CameraList(void) {
    NSMutableArray *devices = [NSMutableArray array];
    for (AVCaptureDevice *device in VideoDevices()) {
        [devices addObject:@{
            @"id": device.uniqueID ?: @"",
            @"name": device.localizedName ?: @"Camera",
            @"position": PositionName(device.position),
            @"deviceType": device.deviceType ?: @"unknown",
        }];
    }
    return @{@"ok": @YES, @"payload": @{@"devices": devices}};
}

static BOOL EnsureMediaPermission(AVMediaType mediaType,
                                  NSString **failureCode,
                                  NSString **failureMessage) {
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    if (status == AVAuthorizationStatusAuthorized) {
        return YES;
    }
    if (status == AVAuthorizationStatusDenied ||
        status == AVAuthorizationStatusRestricted) {
        if (failureCode) {
            *failureCode = [mediaType isEqualToString:AVMediaTypeAudio]
                ? @"MIC_PERMISSION_REQUIRED"
                : @"CAMERA_PERMISSION_REQUIRED";
        }
        if (failureMessage) {
            *failureMessage = @"iOS denied media access for the helper";
        }
        return NO;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:mediaType
                             completionHandler:^(BOOL allowed) {
        granted = allowed;
        dispatch_semaphore_signal(semaphore);
    }];
    long waitResult = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (waitResult != 0 || !granted) {
        if (failureCode) {
            *failureCode = [mediaType isEqualToString:AVMediaTypeAudio]
                ? @"MIC_PERMISSION_REQUIRED"
                : @"CAMERA_PERMISSION_REQUIRED";
        }
        if (failureMessage) {
            *failureMessage = waitResult != 0
                ? @"iOS media permission request timed out"
                : @"iOS media permission was not granted";
        }
        return NO;
    }
    return YES;
}

@interface PhotoCaptureDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property(nonatomic, strong) NSData *photoData;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@end

@implementation PhotoCaptureDelegate
- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {
    (void)output;
    self.error = error;
    if (!error) {
        self.photoData = [photo fileDataRepresentation];
    }
    dispatch_semaphore_signal(self.semaphore);
}
@end

static AVCaptureDevice *ResolveCamera(NSDictionary *params) {
    NSString *deviceID =
        [params[@"deviceId"] isKindOfClass:[NSString class]]
            ? params[@"deviceId"]
            : nil;
    NSString *facing =
        [params[@"facing"] isKindOfClass:[NSString class]]
            ? [params[@"facing"] lowercaseString]
            : @"back";
    AVCaptureDevicePosition wanted =
        [facing isEqualToString:@"front"]
            ? AVCaptureDevicePositionFront
            : AVCaptureDevicePositionBack;

    AVCaptureDevice *fallback = nil;
    for (AVCaptureDevice *device in VideoDevices()) {
        if (deviceID.length > 0 && [device.uniqueID isEqualToString:deviceID]) {
            return device;
        }
        if (!fallback && device.position == wanted) {
            fallback = device;
        }
    }
    return deviceID.length > 0 ? nil : fallback;
}

static NSData *ReencodeJPEG(NSData *source,
                            NSNumber *maxWidthValue,
                            NSNumber *qualityValue,
                            NSUInteger *width,
                            NSUInteger *height) {
    UIImage *image = [UIImage imageWithData:source];
    if (!image) {
        return nil;
    }

    CGFloat maxWidth = maxWidthValue.doubleValue;
    if (!(maxWidth > 0)) {
        maxWidth = 1600;
    }
    CGSize targetSize = image.size;
    if (targetSize.width > maxWidth) {
        CGFloat scale = maxWidth / targetSize.width;
        targetSize = CGSizeMake(floor(targetSize.width * scale),
                                floor(targetSize.height * scale));
        UIGraphicsImageRendererFormat *format =
            [UIGraphicsImageRendererFormat defaultFormat];
        format.opaque = YES;
        format.scale = 1.0;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:targetSize
                                                   format:format];
        UIImage *sourceImage = image;
        UIImage *resized = [renderer
            imageWithActions:^(UIGraphicsImageRendererContext *context) {
                (void)context;
                [sourceImage
                    drawInRect:CGRectMake(0, 0, targetSize.width,
                                          targetSize.height)];
            }];
        image = resized;
    }

    CGFloat quality = qualityValue.doubleValue;
    if (!(quality > 0 && quality <= 1)) {
        quality = 0.9;
    }
    NSData *encoded = UIImageJPEGRepresentation(image, quality);
    if (width) {
        *width = (NSUInteger)llround(image.size.width);
    }
    if (height) {
        *height = (NSUInteger)llround(image.size.height);
    }
    return encoded;
}

static NSDictionary *CameraSnap(NSDictionary *params) {
    NSString *permissionCode = nil;
    NSString *permissionMessage = nil;
    if (!EnsureMediaPermission(
            AVMediaTypeVideo, &permissionCode, &permissionMessage)) {
        return Failure(permissionCode, permissionMessage);
    }

    AVCaptureDevice *device = ResolveCamera(params);
    if (!device) {
        return Failure(@"CAMERA_UNAVAILABLE",
                       @"requested camera was not found");
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input =
        [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
        return Failure(@"CAMERA_UNAVAILABLE",
                       error.localizedDescription ?: @"could not open camera");
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCapturePhotoOutput *output = [[AVCapturePhotoOutput alloc] init];
    if ([session canAddInput:input]) {
        [session addInput:input];
    } else {
        return Failure(@"CAMERA_UNAVAILABLE",
                       @"capture session rejected camera input");
    }
    if ([session canAddOutput:output]) {
        [session addOutput:output];
    } else {
        return Failure(@"CAMERA_UNAVAILABLE",
                       @"capture session rejected photo output");
    }

    [session startRunning];
    if (!session.isRunning) {
        return Failure(@"NODE_BACKGROUND_UNAVAILABLE",
                       @"iOS did not start the headless capture session");
    }

    NSNumber *delayValue =
        [params[@"delayMs"] isKindOfClass:[NSNumber class]]
            ? params[@"delayMs"]
            : @200;
    double delayMs = MIN(MAX(delayValue.doubleValue, 0), 5000);
    if (delayMs > 0) {
        [NSThread sleepForTimeInterval:delayMs / 1000.0];
    }

    PhotoCaptureDelegate *delegate = [[PhotoCaptureDelegate alloc] init];
    delegate.semaphore = dispatch_semaphore_create(0);
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    [output capturePhotoWithSettings:settings delegate:delegate];
    long waitResult = dispatch_semaphore_wait(
        delegate.semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    [session stopRunning];

    if (waitResult != 0) {
        return Failure(@"TIMEOUT", @"camera capture timed out");
    }
    if (delegate.error || !delegate.photoData) {
        return Failure(@"CAMERA_CAPTURE_FAILED",
                       delegate.error.localizedDescription
                           ?: @"camera returned no image data");
    }

    NSUInteger width = 0;
    NSUInteger height = 0;
    NSData *jpeg = ReencodeJPEG(
        delegate.photoData,
        [params[@"maxWidth"] isKindOfClass:[NSNumber class]]
            ? params[@"maxWidth"]
            : @1600,
        [params[@"quality"] isKindOfClass:[NSNumber class]]
            ? params[@"quality"]
            : @0.9,
        &width,
        &height);
    if (!jpeg) {
        return Failure(@"CAMERA_ENCODING_FAILED",
                       @"could not encode captured image");
    }

    return @{
        @"ok": @YES,
        @"payload": @{
            @"format": @"jpeg",
            @"base64": [jpeg base64EncodedStringWithOptions:0],
            @"width": @(width),
            @"height": @(height),
            @"deviceId": device.uniqueID ?: @"",
            @"position": PositionName(device.position),
        },
    };
}

static NSDictionary *ReadRequest(void) {
    NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    if (data.length == 0) {
        return @{};
    }
    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return value;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            WriteJSON(Failure(@"INVALID_REQUEST", @"exactly one command is required"),
                      [NSFileHandle fileHandleWithStandardOutput]);
            return 2;
        }
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        NSDictionary *params = ReadRequest();
        if (!params) {
            WriteJSON(Failure(@"INVALID_REQUEST", @"stdin must contain a JSON object"),
                      [NSFileHandle fileHandleWithStandardOutput]);
            return 2;
        }

        NSDictionary *result = nil;
        if ([command isEqualToString:@"camera.list"]) {
            result = CameraList();
        } else if ([command isEqualToString:@"camera.snap"]) {
            result = CameraSnap(params);
        } else {
            result = Failure(@"UNAVAILABLE", @"command not supported by helper");
        }
        WriteJSON(result, [NSFileHandle fileHandleWithStandardOutput]);
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
