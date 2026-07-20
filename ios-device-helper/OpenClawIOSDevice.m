#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const OpenClawDeviceSocketPath =
    @"/var/mobile/Documents/OpenClawDevice.sock";
static const NSUInteger OpenClawMaxRequestBytes = 16 * 1024;
static UIWindow *OpenClawDeviceWindow;
static AVSpeechSynthesizer *OpenClawSpeechSynthesizer;

static NSDictionary *Failure(NSString *code, NSString *message) {
    return @{
        @"ok": @NO,
        @"error": @{
            @"code": code ?: @"UNAVAILABLE",
            @"message": message ?: @"operation unavailable",
        },
    };
}

static NSDictionary *Success(NSDictionary *payload) {
    return @{@"ok": @YES, @"payload": payload ?: @{}};
}

static void WriteJSON(id value, NSFileHandle *handle) {
    NSError *error = nil;
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!data) {
        data = [NSJSONSerialization
            dataWithJSONObject:Failure(@"SERIALIZATION_FAILED",
                                       error.localizedDescription)
                       options:0
                         error:nil];
    }
    [handle writeData:data];
    [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static double BoundedNumber(id value, double fallback, double low, double high) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return fallback;
    }
    return MIN(MAX([value doubleValue], low), high);
}

static NSString *BoundedString(id value, NSUInteger maximum) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *text = [(NSString *)value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0 || text.length > maximum) {
        return nil;
    }
    return text;
}

static BOOL AppIsActive(void) {
    return UIApplication.sharedApplication.applicationState ==
           UIApplicationStateActive;
}

static NSDictionary *DeviceState(void) {
    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;
    UIScreen *screen = UIScreen.mainScreen;
    NSString *batteryState = @"unknown";
    switch (device.batteryState) {
        case UIDeviceBatteryStateUnplugged:
            batteryState = @"unplugged";
            break;
        case UIDeviceBatteryStateCharging:
            batteryState = @"charging";
            break;
        case UIDeviceBatteryStateFull:
            batteryState = @"full";
            break;
        default:
            break;
    }
    NSString *thermal = @"unknown";
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal:
            thermal = @"nominal";
            break;
        case NSProcessInfoThermalStateFair:
            thermal = @"fair";
            break;
        case NSProcessInfoThermalStateSerious:
            thermal = @"serious";
            break;
        case NSProcessInfoThermalStateCritical:
            thermal = @"critical";
            break;
    }
    float level = device.batteryLevel;
    return Success(@{
        @"systemName": device.systemName ?: @"iOS",
        @"systemVersion": device.systemVersion ?: @"",
        @"model": device.model ?: @"iPhone",
        @"batteryLevel": level >= 0 ? @(level) : [NSNull null],
        @"batteryState": batteryState,
        @"lowPowerMode": @(NSProcessInfo.processInfo.lowPowerModeEnabled),
        @"thermalState": thermal,
        @"brightness": @(screen.brightness),
        @"outputVolume": @(AVAudioSession.sharedInstance.outputVolume),
        @"screenScale": @(screen.scale),
        @"screenWidth": @(screen.bounds.size.width),
        @"screenHeight": @(screen.bounds.size.height),
        @"appActive": @(AppIsActive()),
    });
}

static NSDictionary *ClipboardGet(void) {
    if (!AppIsActive()) {
        return Failure(@"FOREGROUND_REQUIRED",
                       @"OpenClaw Device must be visible");
    }
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (!text) {
        return Success(@{@"text": [NSNull null], @"length": @0});
    }
    if (text.length > 32768) {
        text = [text substringToIndex:32768];
    }
    return Success(@{@"text": text, @"length": @(text.length)});
}

@interface OpenClawLocationDelegate : NSObject <CLLocationManagerDelegate>
@property(nonatomic, strong) CLLocation *location;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@end

@implementation OpenClawLocationDelegate
- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
    self.location = locations.lastObject;
    [manager stopUpdatingLocation];
    dispatch_semaphore_signal(self.semaphore);
}
- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
    (void)manager;
    self.error = error;
    dispatch_semaphore_signal(self.semaphore);
}
@end

static NSDictionary *LocationGet(NSDictionary *params) {
    if (!AppIsActive()) {
        return Failure(@"FOREGROUND_REQUIRED",
                       @"OpenClaw Device must be visible");
    }
    __block CLLocationManager *manager = nil;
    OpenClawLocationDelegate *delegate =
        [[OpenClawLocationDelegate alloc] init];
    delegate.semaphore = dispatch_semaphore_create(0);
    double accuracy = BoundedNumber(params[@"accuracyMeters"], 100.0, 10.0, 3000.0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        manager = [[CLLocationManager alloc] init];
        manager.delegate = delegate;
        manager.desiredAccuracy = accuracy;
        [manager requestWhenInUseAuthorization];
        [manager startUpdatingLocation];
    });
    long waited = dispatch_semaphore_wait(
        delegate.semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    dispatch_sync(dispatch_get_main_queue(), ^{
        [manager stopUpdatingLocation];
        manager.delegate = nil;
    });
    if (waited != 0) {
        return Failure(@"LOCATION_TIMEOUT", @"location request timed out");
    }
    if (!delegate.location) {
        return Failure(@"LOCATION_UNAVAILABLE",
                       delegate.error.localizedDescription);
    }
    CLLocation *location = delegate.location;
    return Success(@{
        @"latitude": @(location.coordinate.latitude),
        @"longitude": @(location.coordinate.longitude),
        @"horizontalAccuracy": @(location.horizontalAccuracy),
        @"altitude": @(location.altitude),
        @"speed": @(location.speed),
        @"course": @(location.course),
        @"timestamp":
            @([location.timestamp timeIntervalSince1970] * 1000.0),
    });
}

static NSDictionary *MotionSample(NSDictionary *params) {
    double seconds = BoundedNumber(params[@"durationSeconds"], 1.0, 0.25, 5.0);
    CMMotionManager *manager = [[CMMotionManager alloc] init];
    if (!manager.deviceMotionAvailable) {
        return Failure(@"MOTION_UNAVAILABLE", @"device motion is unavailable");
    }
    manager.deviceMotionUpdateInterval = MIN(seconds, 0.1);
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block CMDeviceMotion *last = nil;
    __block NSUInteger samples = 0;
    [manager startDeviceMotionUpdatesToQueue:queue
                                withHandler:^(CMDeviceMotion *motion,
                                              NSError *error) {
        (void)error;
        last = motion;
        samples += 1;
        if (samples >= 2 && motion.timestamp >= seconds) {
            dispatch_semaphore_signal(semaphore);
        }
    }];
    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 1.0) * NSEC_PER_SEC)));
    [manager stopDeviceMotionUpdates];
    [queue cancelAllOperations];
    if (!last) {
        return Failure(@"MOTION_TIMEOUT", @"no motion sample was returned");
    }
    CMAcceleration acceleration = last.userAcceleration;
    CMRotationRate rotation = last.rotationRate;
    CMQuaternion quaternion = last.attitude.quaternion;
    return Success(@{
        @"sampleCount": @(samples),
        @"acceleration": @{
            @"x": @(acceleration.x),
            @"y": @(acceleration.y),
            @"z": @(acceleration.z),
        },
        @"rotationRate": @{
            @"x": @(rotation.x),
            @"y": @(rotation.y),
            @"z": @(rotation.z),
        },
        @"attitude": @{
            @"roll": @(last.attitude.roll),
            @"pitch": @(last.attitude.pitch),
            @"yaw": @(last.attitude.yaw),
            @"quaternion": @{
                @"x": @(quaternion.x),
                @"y": @(quaternion.y),
                @"z": @(quaternion.z),
                @"w": @(quaternion.w),
            },
        },
    });
}

static NSDictionary *PedometerGet(NSDictionary *params) {
    if (![CMPedometer isStepCountingAvailable]) {
        return Failure(@"PEDOMETER_UNAVAILABLE",
                       @"step counting is unavailable");
    }
    double hours = BoundedNumber(params[@"hours"], 24.0, 1.0, 168.0);
    NSDate *end = NSDate.date;
    NSDate *start = [end dateByAddingTimeInterval:-hours * 3600.0];
    CMPedometer *pedometer = [[CMPedometer alloc] init];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block CMPedometerData *data = nil;
    __block NSError *queryError = nil;
    [pedometer queryPedometerDataFromDate:start
                                  toDate:end
                             withHandler:^(CMPedometerData *result,
                                           NSError *error) {
        data = result;
        queryError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    long waited = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
    if (waited != 0 || !data) {
        return Failure(@"PEDOMETER_UNAVAILABLE",
                       queryError.localizedDescription ?: @"query timed out");
    }
    NSMutableDictionary *payload = [@{
        @"start": @([data.startDate timeIntervalSince1970] * 1000.0),
        @"end": @([data.endDate timeIntervalSince1970] * 1000.0),
        @"steps": data.numberOfSteps ?: @0,
    } mutableCopy];
    if (data.distance) {
        payload[@"distanceMeters"] = data.distance;
    }
    if (data.floorsAscended) {
        payload[@"floorsAscended"] = data.floorsAscended;
    }
    if (data.floorsDescended) {
        payload[@"floorsDescended"] = data.floorsDescended;
    }
    return Success(payload);
}

static BOOL EnsureMicrophonePermission(void) {
    AVAudioSessionRecordPermission permission =
        AVAudioSession.sharedInstance.recordPermission;
    if (permission == AVAudioSessionRecordPermissionGranted) {
        return YES;
    }
    if (permission == AVAudioSessionRecordPermissionDenied) {
        return NO;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL allowed) {
        granted = allowed;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return granted;
}

static NSDictionary *AudioCapture(NSDictionary *params, BOOL includeData) {
    if (!AppIsActive()) {
        return Failure(@"FOREGROUND_REQUIRED",
                       @"OpenClaw Device must be visible");
    }
    if (!EnsureMicrophonePermission()) {
        return Failure(@"MIC_PERMISSION_REQUIRED",
                       @"microphone permission was not granted");
    }
    double seconds =
        BoundedNumber(params[@"durationSeconds"], includeData ? 3.0 : 2.0,
                      0.5, includeData ? 10.0 : 5.0);
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryRecord
                         mode:AVAudioSessionModeMeasurement
                      options:0
                        error:&error] ||
        ![session setActive:YES error:&error]) {
        return Failure(@"AUDIO_SESSION_FAILED", error.localizedDescription);
    }
    NSString *path = [@"/var/tmp"
        stringByAppendingPathComponent:[NSString
            stringWithFormat:@"openclaw-audio-%@.m4a",
                             NSUUID.UUID.UUIDString]];
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @16000,
        AVNumberOfChannelsKey: @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityMedium),
        AVEncoderBitRateKey: @32000,
    };
    AVAudioRecorder *recorder =
        [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
    recorder.meteringEnabled = YES;
    if (!recorder || ![recorder prepareToRecord] || ![recorder record]) {
        [session setActive:NO error:nil];
        return Failure(@"AUDIO_RECORD_FAILED", error.localizedDescription);
    }
    float peak = -160.0f;
    float average = -160.0f;
    NSUInteger samples = 0;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        [NSThread sleepForTimeInterval:0.1];
        [recorder updateMeters];
        peak = MAX(peak, [recorder peakPowerForChannel:0]);
        average = MAX(average, [recorder averagePowerForChannel:0]);
        samples += 1;
    }
    [recorder stop];
    [session setActive:NO error:nil];
    NSMutableDictionary *payload = [@{
        @"durationSeconds": @(seconds),
        @"peakDbFS": @(peak),
        @"averageDbFS": @(average),
        @"meterSamples": @(samples),
    } mutableCopy];
    if (includeData) {
        NSData *audio = [NSData dataWithContentsOfURL:url];
        if (!audio || audio.length > 2 * 1024 * 1024) {
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            return Failure(@"AUDIO_TOO_LARGE",
                           @"recording exceeded the two-megabyte limit");
        }
        payload[@"format"] = @"m4a";
        payload[@"base64"] = [audio base64EncodedStringWithOptions:0];
        payload[@"bytes"] = @(audio.length);
    }
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    return Success(payload);
}

static NSDictionary *FlashlightSet(NSDictionary *params) {
    if (![params[@"enabled"] isKindOfClass:[NSNumber class]]) {
        return Failure(@"INVALID_PARAMS", @"enabled must be a boolean");
    }
    BOOL enabled = [params[@"enabled"] boolValue];
    AVCaptureDevice *device =
        [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device.hasTorch) {
        return Failure(@"FLASHLIGHT_UNAVAILABLE", @"torch is unavailable");
    }
    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        return Failure(@"FLASHLIGHT_FAILED", error.localizedDescription);
    }
    BOOL ok = YES;
    if (enabled) {
        float level =
            (float)BoundedNumber(params[@"level"], 1.0, 0.01, 1.0);
        ok = [device setTorchModeOnWithLevel:level error:&error];
    } else {
        device.torchMode = AVCaptureTorchModeOff;
    }
    [device unlockForConfiguration];
    if (!ok) {
        return Failure(@"FLASHLIGHT_FAILED", error.localizedDescription);
    }
    return Success(@{@"enabled": @(enabled)});
}

static NSDictionary *DisplaySet(NSDictionary *params) {
    if (![params[@"brightness"] isKindOfClass:[NSNumber class]]) {
        return Failure(@"INVALID_PARAMS", @"brightness must be a number");
    }
    CGFloat value =
        BoundedNumber(params[@"brightness"], 0.5, 0.0, 1.0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIScreen.mainScreen.brightness = value;
    });
    return Success(@{@"brightness": @(UIScreen.mainScreen.brightness)});
}

static NSDictionary *Vibrate(void) {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    return Success(@{@"triggered": @YES});
}

static NSDictionary *SpeechSpeak(NSDictionary *params) {
    NSString *text = BoundedString(params[@"text"], 500);
    if (!text) {
        return Failure(@"INVALID_PARAMS",
                       @"text must contain one to 500 characters");
    }
    double rate = BoundedNumber(params[@"rate"], 0.5, 0.1, 0.65);
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!OpenClawSpeechSynthesizer) {
            OpenClawSpeechSynthesizer = [[AVSpeechSynthesizer alloc] init];
        }
        AVSpeechUtterance *utterance =
            [AVSpeechUtterance speechUtteranceWithString:text];
        utterance.rate = rate;
        [OpenClawSpeechSynthesizer speakUtterance:utterance];
    });
    return Success(@{@"queued": @YES, @"characters": @(text.length)});
}

static NSDictionary *SystemNotify(NSDictionary *params) {
    NSString *title = BoundedString(params[@"title"], 80);
    NSString *body = BoundedString(params[@"body"], 240);
    if (!title || !body) {
        return Failure(@"INVALID_PARAMS",
                       @"title and body are required and bounded");
    }
    UNUserNotificationCenter *center =
        UNUserNotificationCenter.currentNotificationCenter;
    dispatch_semaphore_t permissionSemaphore =
        dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                              UNAuthorizationOptionSound)
                          completionHandler:^(BOOL allowed, NSError *error) {
        (void)error;
        granted = allowed;
        dispatch_semaphore_signal(permissionSemaphore);
    }];
    dispatch_semaphore_wait(
        permissionSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (!granted) {
        return Failure(@"NOTIFICATION_PERMISSION_REQUIRED",
                       @"notification permission was not granted");
    }
    UNMutableNotificationContent *content =
        [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = UNNotificationSound.defaultSound;
    UNTimeIntervalNotificationTrigger *trigger =
        [UNTimeIntervalNotificationTrigger
            triggerWithTimeInterval:1.0
                            repeats:NO];
    UNNotificationRequest *request =
        [UNNotificationRequest
            requestWithIdentifier:[NSString
                stringWithFormat:@"openclaw-%@", NSUUID.UUID.UUIDString]
                          content:content
                          trigger:trigger];
    dispatch_semaphore_t addSemaphore = dispatch_semaphore_create(0);
    __block NSError *addError = nil;
    [center addNotificationRequest:request
            withCompletionHandler:^(NSError *error) {
        addError = error;
        dispatch_semaphore_signal(addSemaphore);
    }];
    dispatch_semaphore_wait(
        addSemaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (addError) {
        return Failure(@"NOTIFICATION_FAILED", addError.localizedDescription);
    }
    return Success(@{@"scheduled": @YES});
}

@interface OpenClawBluetoothDelegate : NSObject <CBCentralManagerDelegate>
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *devices;
@property(nonatomic, strong) dispatch_semaphore_t stateSemaphore;
@end

@implementation OpenClawBluetoothDelegate
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    (void)central;
    dispatch_semaphore_signal(self.stateSemaphore);
}
- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    (void)central;
    NSString *identifier = peripheral.identifier.UUIDString;
    if (!identifier || self.devices.count >= 32) {
        return;
    }
    NSString *name =
        BoundedString(advertisementData[CBAdvertisementDataLocalNameKey], 128)
            ?: BoundedString(peripheral.name, 128);
    self.devices[identifier] = @{
        @"id": identifier,
        @"name": name ?: [NSNull null],
        @"rssi": RSSI ?: @0,
        @"connectable":
            advertisementData[CBAdvertisementDataIsConnectable] ?: @NO,
    };
}
@end

static NSDictionary *BluetoothScan(NSDictionary *params) {
    if (!AppIsActive()) {
        return Failure(@"FOREGROUND_REQUIRED",
                       @"OpenClaw Device must be visible");
    }
    double seconds =
        BoundedNumber(params[@"durationSeconds"], 3.0, 1.0, 8.0);
    OpenClawBluetoothDelegate *delegate =
        [[OpenClawBluetoothDelegate alloc] init];
    delegate.devices = [NSMutableDictionary dictionary];
    delegate.stateSemaphore = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        delegate.manager =
            [[CBCentralManager alloc] initWithDelegate:delegate
                                                 queue:dispatch_get_main_queue()];
    });
    dispatch_semaphore_wait(
        delegate.stateSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (delegate.manager.state != CBManagerStatePoweredOn) {
        return Failure(@"BLUETOOTH_UNAVAILABLE",
                       @"Bluetooth is not powered on or permission is denied");
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        [delegate.manager
            scanForPeripheralsWithServices:nil
                                  options:@{
                                      CBCentralManagerScanOptionAllowDuplicatesKey:
                                          @NO
                                  }];
    });
    [NSThread sleepForTimeInterval:seconds];
    dispatch_sync(dispatch_get_main_queue(), ^{
        [delegate.manager stopScan];
        delegate.manager.delegate = nil;
    });
    NSArray *devices = [delegate.devices.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                        NSDictionary *b) {
        return [b[@"rssi"] compare:a[@"rssi"]];
    }];
    return Success(@{@"devices": devices, @"durationSeconds": @(seconds)});
}

static NSDictionary *ScreenSnapshot(NSDictionary *params) {
    if (!AppIsActive()) {
        return Failure(@"FOREGROUND_REQUIRED",
                       @"OpenClaw Device must be visible");
    }
    typedef CGImageRef (*ScreenImageFunction)(void);
    ScreenImageFunction function =
        (ScreenImageFunction)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    if (!function) {
        return Failure(@"SCREEN_CAPTURE_UNAVAILABLE",
                       @"UIGetScreenImage is not available");
    }
    CGImageRef imageRef = function();
    if (!imageRef) {
        return Failure(@"SCREEN_CAPTURE_FAILED",
                       @"screen image was not returned");
    }
    UIImage *image = [UIImage imageWithCGImage:imageRef];
    CGFloat quality =
        BoundedNumber(params[@"quality"], 0.75, 0.2, 0.9);
    NSData *jpeg = UIImageJPEGRepresentation(image, quality);
    CGImageRelease(imageRef);
    if (!jpeg || jpeg.length > 8 * 1024 * 1024) {
        return Failure(@"SCREEN_CAPTURE_TOO_LARGE",
                       @"screen image exceeded the size limit");
    }
    return Success(@{
        @"format": @"jpeg",
        @"base64": [jpeg base64EncodedStringWithOptions:0],
        @"bytes": @(jpeg.length),
        @"width": @(image.size.width),
        @"height": @(image.size.height),
    });
}

static NSDictionary *DispatchCommand(NSString *command,
                                     NSDictionary *params) {
    if ([command isEqualToString:@"device.nativeStatus"]) {
        return DeviceState();
    }
    if ([command isEqualToString:@"clipboard.get"]) {
        return ClipboardGet();
    }
    if ([command isEqualToString:@"location.get"]) {
        return LocationGet(params);
    }
    if ([command isEqualToString:@"motion.sample"]) {
        return MotionSample(params);
    }
    if ([command isEqualToString:@"pedometer.get"]) {
        return PedometerGet(params);
    }
    if ([command isEqualToString:@"audio.record"]) {
        return AudioCapture(params, YES);
    }
    if ([command isEqualToString:@"audio.level"]) {
        return AudioCapture(params, NO);
    }
    if ([command isEqualToString:@"flashlight.set"]) {
        return FlashlightSet(params);
    }
    if ([command isEqualToString:@"display.setBrightness"]) {
        return DisplaySet(params);
    }
    if ([command isEqualToString:@"haptics.vibrate"]) {
        return Vibrate();
    }
    if ([command isEqualToString:@"speech.speak"]) {
        return SpeechSpeak(params);
    }
    if ([command isEqualToString:@"system.notify"]) {
        return SystemNotify(params);
    }
    if ([command isEqualToString:@"bluetooth.scan"]) {
        return BluetoothScan(params);
    }
    if ([command isEqualToString:@"screen.snapshot"]) {
        return ScreenSnapshot(params);
    }
    return Failure(@"UNAVAILABLE", @"command is not supported");
}

static NSData *ReadBoundedRequest(int clientFD, BOOL *tooLarge) {
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[2048];
    *tooLarge = NO;
    for (;;) {
        ssize_t count = recv(clientFD, buffer, sizeof(buffer), 0);
        if (count == 0) {
            return data;
        }
        if (count < 0) {
            return nil;
        }
        if (data.length + (NSUInteger)count > OpenClawMaxRequestBytes) {
            *tooLarge = YES;
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
}

static void HandleSocketConnection(int clientFD) {
    @autoreleasepool {
        struct timeval timeout = {.tv_sec = 20, .tv_usec = 0};
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout));
        NSFileHandle *handle =
            [[NSFileHandle alloc] initWithFileDescriptor:clientFD
                                          closeOnDealloc:YES];
        BOOL tooLarge = NO;
        NSData *data = ReadBoundedRequest(clientFD, &tooLarge);
        if (!data) {
            WriteJSON(
                Failure(tooLarge ? @"REQUEST_TOO_LARGE" : @"INVALID_REQUEST",
                        tooLarge ? @"request exceeded 16 KiB"
                                 : @"request could not be read"),
                handle);
            return;
        }
        NSError *error = nil;
        id value =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![value isKindOfClass:[NSDictionary class]]) {
            WriteJSON(Failure(@"INVALID_REQUEST",
                              error.localizedDescription),
                      handle);
            return;
        }
        NSString *command =
            [value[@"command"] isKindOfClass:[NSString class]]
                ? value[@"command"]
                : nil;
        NSDictionary *params =
            [value[@"params"] isKindOfClass:[NSDictionary class]]
                ? value[@"params"]
                : @{};
        if (!command) {
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
        const char *path = OpenClawDeviceSocketPath.fileSystemRepresentation;
        unlink(path);
        int serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
        if (serverFD < 0) {
            return;
        }
        struct sockaddr_un address;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        memcpy(address.sun_path, path, strlen(path) + 1);
        if (bind(serverFD, (struct sockaddr *)&address, sizeof(address)) != 0 ||
            chmod(path, S_IRUSR | S_IWUSR) != 0 ||
            listen(serverFD, 4) != 0) {
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
                break;
            }
            HandleSocketConnection(clientFD);
        }
        close(serverFD);
        unlink(path);
    });
}

@interface OpenClawDeviceAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation OpenClawDeviceAppDelegate
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
    title.text = @"OpenClaw Device";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:28.0];
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text =
        @"Ready for explicit device requests.\n"
         "Sensitive sensors run only while this screen is visible.";
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
    OpenClawDeviceWindow = self.window;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    StartSocketServer();
    return YES;
}
- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    unlink(OpenClawDeviceSocketPath.fileSystemRepresentation);
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc, argv, nil,
            NSStringFromClass([OpenClawDeviceAppDelegate class]));
    }
}
