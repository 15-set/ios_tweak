//
//  WVDDownloader.m
//  微博视频下载器 - 后台下载并保存到系统相册
//
//  流程：
//    1. 复用抓到的原始请求（保留微博自己的 Referer / Cookie），只删除 Range 头，保证下到完整文件
//    2. NSURLSession 后台下载到 App 沙盒的临时目录
//    3. 通过 PhotoKit（AddOnly 权限）写入系统相册
//    4. 按开关弹出“开始下载 / 下载成功 / 下载失败”提示
//
//  安全兜底：
//    微博的 Info.plist 不一定有 NSPhotoLibraryAddUsageDescription。
//    缺少该键时直接调用 PhotoKit 会导致微博被系统杀掉，所以这里先检查，
//    缺键就提示失败并放弃保存，绝不让宿主闪退。
//

#import "WVDDownloader.h"
#import "WVDPrefs.h"

#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - UI 小工具

/// 取当前最上层的 ViewController（兼容 iOS 13+ 多 Scene）
static UIViewController *WVDTopViewController(void) {
    UIWindow *keyWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;

            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
            if (keyWindow) break;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!keyWindow) {
        keyWindow = UIApplication.sharedApplication.keyWindow;
    }
#pragma clang diagnostic pop

    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

/// 弹窗。autoDismiss = YES 时约 1.2 秒后自动消失（用于“开始下载”提示）
/// 延迟 0.5 秒再弹，是为了等分享菜单关闭动画结束，避免 present 失败
static void WVDShowAlert(NSString *title, NSString *message, BOOL autoDismiss) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *top = WVDTopViewController();
        if (top == nil) return;
        // 微博自己已经有弹窗时不再叠加，避免互相干扰
        if ([top isKindOfClass:[UIAlertController class]]) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        if (!autoDismiss) {
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
        }

        [top presentViewController:alert animated:YES completion:nil];

        if (autoDismiss) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
        }
    });
}

/// 画质描述，仅用于提示文案
static NSString *WVDQualityDescription(NSInteger quality) {
    if (quality >= 1080) return @"1080P";
    if (quality >= 720)  return @"720P";
    if (quality >= 480)  return @"480P";
    if (quality >= 360)  return @"360P";
    return @"未知画质";
}

#pragma mark - WVDDownloader

@interface WVDDownloader ()

- (void)_beginDownloadWithCandidate:(WVDVideoCandidate *)candidate;
- (void)_beginHLSExportWithCandidate:(WVDVideoCandidate *)candidate;
- (void)_exportAsset:(AVAsset *)asset;
- (void)_saveVideoToPhotoLibrary:(NSURL *)fileURL;
- (void)_handleAuthorizationStatus:(PHAuthorizationStatus)status fileURL:(NSURL *)fileURL;
- (void)_showInfoWithTitle:(NSString *)title detail:(NSString *)detail autoDismiss:(BOOL)autoDismiss;
- (void)_showSuccess;
- (void)_showFailureWithDetail:(NSString *)detail;

@end

@implementation WVDDownloader {
    NSURLSession *_session;
}

+ (instancetype)shared {
    static WVDDownloader *downloader = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        downloader = [[WVDDownloader alloc] init];
    });
    return downloader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 600.0;   // 大视频允许下载 10 分钟
        configuration.allowsCellularAccess = YES;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)startDownloadWithCandidate:(WVDVideoCandidate *)candidate {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 总开关关闭时不做事（也不弹提示）
        if (!WVDIsEnabled()) return;

        if (candidate == nil || candidate.url.absoluteString.length == 0) {
            [self _showFailureWithDetail:@"没抓到视频直链，请先播放视频再点下载。"];
            return;
        }

        [self _showInfoWithTitle:@"开始下载"
                           detail:[NSString stringWithFormat:@"%@ · 完成后自动存入相册",
                                   WVDQualityDescription(candidate.quality)]
                      autoDismiss:YES];

        [self _beginDownloadWithCandidate:candidate];
    });
}

- (void)startDownloadWithAsset:(AVAsset *)asset {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!WVDIsEnabled()) return;

        if (asset == nil) {
            [self _showFailureWithDetail:@"没拿到播放器资源，请先播放视频。"];
            return;
        }

        [self _showInfoWithTitle:@"开始下载" detail:@"正在导出视频…" autoDismiss:YES];
        [self _exportAsset:asset];
    });
}

#pragma mark - 下载

- (void)_beginDownloadWithCandidate:(WVDVideoCandidate *)candidate {
    // HLS（.m3u8）不能直接当文件下载，先交给系统导出成 mp4
    if (candidate.isHLS) {
        [self _beginHLSExportWithCandidate:candidate];
        return;
    }

    // 复用原始请求：微博 CDN 一般会校验 Referer / Cookie
    NSMutableURLRequest *request = candidate.request
        ? [candidate.request mutableCopy]
        : [NSMutableURLRequest requestWithURL:candidate.url];

    if (request.URL == nil) {
        request.URL = candidate.url;
    }

    // 去掉 Range，防止服务器只返回分段内容导致相册里视频不完整
    [request setValue:nil forHTTPHeaderField:@"Range"];
    // 没有 Referer 时补一个微博站内 Referer
    if ([request valueForHTTPHeaderField:@"Referer"].length == 0) {
        [request setValue:@"https://m.weibo.cn/" forHTTPHeaderField:@"Referer"];
    }
    request.timeoutInterval = 60.0;

    __weak typeof(self) weakSelf = self;

    NSURLSessionDownloadTask *task =
        [_session downloadTaskWithRequest:request
                        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;

            if (error) {
                [strongSelf _showFailureWithDetail:error.localizedDescription ?: @"网络错误"];
                return;
            }

            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                if (statusCode < 200 || statusCode >= 300) {
                    [strongSelf _showFailureWithDetail:[NSString stringWithFormat:@"服务器返回 HTTP %ld", (long)statusCode]];
                    return;
                }
            }

            if (location == nil) {
                [strongSelf _showFailureWithDetail:@"下载完成但没有拿到临时文件"];
                return;
            }

            // 移到沙盒临时目录，并强制使用 .mp4 后缀（PhotoKit 需要能识别的视频类型）
            NSString *fileName = [NSString stringWithFormat:@"wvd_%@.mp4", [NSUUID UUID].UUIDString];
            NSURL *tmpURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];

            NSError *moveError = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:tmpURL error:&moveError];
            if (moveError) {
                [strongSelf _showFailureWithDetail:moveError.localizedDescription ?: @"临时文件写入失败"];
                return;
            }

            [strongSelf _saveVideoToPhotoLibrary:tmpURL];
        }];

    [task resume];
}

/// HLS 下载：让系统把 m3u8 拉下来并导出为本地 mp4
- (void)_beginHLSExportWithCandidate:(WVDVideoCandidate *)candidate {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    NSDictionary *headers = candidate.request.allHTTPHeaderFields;
    if (headers.count > 0) {
        // 微博 CDN 会校验 Referer，把抓到的头原样带上
        options[@"AVURLAssetHTTPHeaderFieldsKey"] = headers;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:candidate.url options:options];
    [self _exportAsset:asset];
}

/// 把任意 AVAsset（含播放器正在播的 HLS/自定义资源）导出为本地 mp4
- (void)_exportAsset:(AVAsset *)asset {
    if (asset == nil) {
        [self _showFailureWithDetail:@"没有拿到视频资源"];
        return;
    }

    NSString *fileName = [NSString stringWithFormat:@"wvd_%@.mp4", [NSUUID UUID].UUIDString];
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];

    NSString *preset = AVAssetExportPresetHighestQuality;
    NSArray<NSString *> *presets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    if (![presets containsObject:preset]) {
        preset = AVAssetExportPresetMediumQuality;
    }

    AVAssetExportSession *session = [AVAssetExportSession exportSessionWithAsset:asset
                                                                     presetName:preset];
    if (session == nil) {
        [self _showFailureWithDetail:@"无法导出该视频"];
        return;
    }
    session.outputURL = outputURL;
    session.outputFileType = AVFileTypeMPEG4;
    session.shouldOptimizeForNetworkUse = NO;

    __weak typeof(self) weakSelf = self;
    [session exportAsynchronouslyWithCompletionHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (session.status == AVAssetExportSessionStatusCompleted) {
                [strongSelf _saveVideoToPhotoLibrary:outputURL];
            } else {
                [strongSelf _showFailureWithDetail:[NSString stringWithFormat:@"导出失败（code=%ld）",
                                                     (long)session.status]];
            }
        });
    }];
}

#pragma mark - 保存到相册

- (void)_saveVideoToPhotoLibrary:(NSURL *)fileURL {
    // 先确认微博 Info.plist 里有相册权限说明，缺少时直接拒绝，避免微博闪退
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *usageDescription =
        [mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryAddUsageDescription"] ?:
        [mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"];

    if (usageDescription.length == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        [self _showFailureWithDetail:@"微博的 Info.plist 缺少相册写入权限说明（NSPhotoLibraryAddUsageDescription），为避免微博闪退，已取消保存。"];
        return;
    }

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];

    if (status == PHAuthorizationStatusNotDetermined) {
        __weak typeof(self) weakSelf = self;
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                  handler:^(PHAuthorizationStatus newStatus) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf _handleAuthorizationStatus:newStatus fileURL:fileURL];
        }];
        return;
    }

    [self _handleAuthorizationStatus:status fileURL:fileURL];
}

- (void)_handleAuthorizationStatus:(PHAuthorizationStatus)status fileURL:(NSURL *)fileURL {
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        [self _showFailureWithDetail:@"相册写入权限被拒绝。\n可在 设置 → 微博 → 照片 中允许“添加照片”。"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        // 从本地文件创建视频资源，微博自己的相册里就会多一条视频
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        if (strongSelf == nil) return;

        if (success) {
            [strongSelf _showSuccess];
        } else {
            [strongSelf _showFailureWithDetail:error.localizedDescription ?: @"写入相册失败"];
        }
    }];
}

#pragma mark - 提示

- (void)_showInfoWithTitle:(NSString *)title detail:(NSString *)detail autoDismiss:(BOOL)autoDismiss {
    NSLog(@"[WeiboVideoDownloader] %@ - %@", title, detail);
    if (!WVDShouldShowAlerts()) return;
    WVDShowAlert(title, detail, autoDismiss);
}

- (void)_showSuccess {
    [self _showInfoWithTitle:@"下载成功" detail:@"视频已保存到系统相册。" autoDismiss:NO];
}

- (void)_showFailureWithDetail:(NSString *)detail {
    [self _showInfoWithTitle:@"下载失败" detail:detail autoDismiss:NO];
}

@end
