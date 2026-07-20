#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <math.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const OpenClawCameraSocketPath =
    @"/var/mobile/Documents/OpenClawCamera.sock";

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

@interface VideoFrameCaptureDelegate
    : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) NSData *frameData;
@property(nonatomic, copy) NSString *errorMessage;
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@property(nonatomic) CFAbsoluteTime notBefore;
@property(nonatomic) BOOL captured;
@end

@implementation VideoFrameCaptureDelegate
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    if (self.captured || CFAbsoluteTimeGetCurrent() < self.notBefore) {
        return;
    }
    @synchronized(self) {
        if (self.captured) {
            return;
        }
        self.captured = YES;
    }

    CVImageBufferRef imageBuffer =
        CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        self.errorMessage = @"camera returned no video frame";
        dispatch_semaphore_signal(self.semaphore);
        return;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage =
        [context createCGImage:image fromRect:image.extent];
    if (!cgImage) {
        self.errorMessage = @"could not render camera video frame";
        dispatch_semaphore_signal(self.semaphore);
        return;
    }
    UIImage *uiImage = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    self.frameData = UIImageJPEGRepresentation(uiImage, 0.95);
    if (!self.frameData) {
        self.errorMessage = @"could not encode camera video frame";
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
    UIApplication *application = [UIApplication sharedApplication];
    for (NSUInteger attempt = 0;
         application.applicationState != UIApplicationStateActive &&
         attempt < 50;
         attempt += 1) {
        [NSThread sleepForTimeInterval:0.1];
    }
    if (application.applicationState != UIApplicationStateActive) {
        return Failure(@"NODE_BACKGROUND_UNAVAILABLE",
                       @"OpenClaw Camera must be visible in the foreground");
    }

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

    NSNumber *delayValue =
        [params[@"delayMs"] isKindOfClass:[NSNumber class]]
            ? params[@"delayMs"]
            : @200;
    double delayMs = MIN(MAX(delayValue.doubleValue, 0), 5000);
    VideoFrameCaptureDelegate *delegate =
        [[VideoFrameCaptureDelegate alloc] init];
    delegate.semaphore = dispatch_semaphore_create(0);
    delegate.notBefore =
        CFAbsoluteTimeGetCurrent() + (delayMs / 1000.0);

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureVideoDataOutput *output =
        [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_32BGRA),
    };
    dispatch_queue_t frameQueue = dispatch_queue_create(
        "ai.openclaw.camera.frames", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:delegate queue:frameQueue];

    [session beginConfiguration];
    if ([session canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
        session.sessionPreset = AVCaptureSessionPresetPhoto;
    }
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
                       @"capture session rejected video frame output");
    }
    [session commitConfiguration];

    [session startRunning];
    if (!session.isRunning) {
        return Failure(@"NODE_BACKGROUND_UNAVAILABLE",
                       @"iOS did not start the headless capture session");
    }

    long waitResult = dispatch_semaphore_wait(
        delegate.semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
    [output setSampleBufferDelegate:nil queue:NULL];
    [session stopRunning];

    if (waitResult != 0) {
        return Failure(@"TIMEOUT", @"camera video frame capture timed out");
    }
    if (delegate.errorMessage || !delegate.frameData) {
        return Failure(@"CAMERA_CAPTURE_FAILED",
                       delegate.errorMessage
                           ?: @"camera returned no image frame");
    }

    NSUInteger width = 0;
    NSUInteger height = 0;
    NSData *jpeg = ReencodeJPEG(
        delegate.frameData,
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

static NSDictionary *DispatchCommand(NSString *command,
                                     NSDictionary *params) {
    if ([command isEqualToString:@"camera.list"]) {
        return CameraList();
    }
    if ([command isEqualToString:@"camera.snap"]) {
        return CameraSnap(params);
    }
    return Failure(@"UNAVAILABLE", @"command not supported by helper");
}

static void HandleSocketConnection(int clientFD) {
    @autoreleasepool {
        NSFileHandle *handle =
            [[NSFileHandle alloc] initWithFileDescriptor:clientFD
                                          closeOnDealloc:YES];
        NSData *data = [handle readDataToEndOfFile];
        NSError *error = nil;
        id value = data.length > 0
            ? [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:&error]
            : nil;
        if (![value isKindOfClass:[NSDictionary class]]) {
            WriteJSON(
                Failure(@"INVALID_REQUEST",
                        error.localizedDescription
                            ?: @"socket request must be a JSON object"),
                handle);
            return;
        }

        NSDictionary *request = value;
        NSString *command =
            [request[@"command"] isKindOfClass:[NSString class]]
                ? request[@"command"]
                : nil;
        NSDictionary *params =
            [request[@"params"] isKindOfClass:[NSDictionary class]]
                ? request[@"params"]
                : @{};
        if (command.length == 0) {
            WriteJSON(Failure(@"INVALID_REQUEST", @"command is required"),
                      handle);
            return;
        }
        WriteJSON(DispatchCommand(command, params), handle);
    }
}

static void StartSocketServer(void) {
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const char *path = OpenClawCameraSocketPath.fileSystemRepresentation;
        if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
            fprintf(stderr, "OpenClaw camera socket path is too long\n");
            return;
        }

        unlink(path);
        int serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
        if (serverFD < 0) {
            fprintf(stderr, "OpenClaw camera socket failed: %s\n",
                    strerror(errno));
            return;
        }

        struct sockaddr_un address;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        memcpy(address.sun_path, path, strlen(path) + 1);
        if (bind(serverFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
            fprintf(stderr, "OpenClaw camera bind failed: %s\n",
                    strerror(errno));
            close(serverFD);
            return;
        }
        chmod(path, S_IRUSR | S_IWUSR);
        if (listen(serverFD, 4) != 0) {
            fprintf(stderr, "OpenClaw camera listen failed: %s\n",
                    strerror(errno));
            close(serverFD);
            unlink(path);
            return;
        }

        for (;;) {
            int clientFD = accept(serverFD, NULL, NULL);
            if (clientFD < 0) {
                if (errno == EINTR) {
                    continue;
                }
                fprintf(stderr, "OpenClaw camera accept failed: %s\n",
                        strerror(errno));
                break;
            }
            HandleSocketConnection(clientFD);
        }
        close(serverFD);
        unlink(path);
    });
}

@interface OpenClawCameraAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation OpenClawCameraAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    signal(SIGPIPE, SIG_IGN);

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor =
        [UIColor colorWithRed:0.04 green:0.07 blue:0.12 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"OpenClaw Camera";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:28.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text =
        @"Ready for an explicit camera request.\n"
         "Keep this screen visible while capturing.";
    status.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    status.font = [UIFont systemFontOfSize:17.0];
    status.numberOfLines = 0;
    status.textAlignment = NSTextAlignmentCenter;

    [controller.view addSubview:title];
    [controller.view addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor
            constraintEqualToAnchor:controller.view.centerXAnchor],
        [title.centerYAnchor
            constraintEqualToAnchor:controller.view.centerYAnchor
                           constant:-32.0],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                         constant:18.0],
        [status.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor
                                          constant:28.0],
        [status.trailingAnchor
            constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor
                                       constant:-28.0],
        [status.centerXAnchor
            constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    StartSocketServer();
    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    unlink(OpenClawCameraSocketPath.fileSystemRepresentation);
}
@end

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
        if (argc == 1) {
            return UIApplicationMain(
                argc, argv, nil,
                NSStringFromClass([OpenClawCameraAppDelegate class]));
        }
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

        NSDictionary *result = DispatchCommand(command, params);
        WriteJSON(result, [NSFileHandle fileHandleWithStandardOutput]);
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
