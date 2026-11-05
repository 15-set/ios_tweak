//
//  Tweak.x
//  微博视频下载器 (WeiboVideoDownloader)
//
//  适配：arm64 / arm64e · iOS 15.x · Dopamine 无根越狱 · 注入 com.sina.weibo
//
//  功能：
//   1. 只读地收集微博发起的视频 MP4 直链（不修改、不拦截任何网络请求）
//   2. 在 AVPlayerLayer 所在的播放器视图右上角挂一个【下载】按钮
//   3. 在系统分享菜单（UIActivityViewController）中追加【下载视频】选项
//   4. 点击后交给 WVDDownloader 后台下载，并保存到系统相册
//
//  说明：
//   * 这里 hook 的都是系统类（AVPlayerLayer / AVURLAsset / NSURLSessionTask /
//     NSJSONSerialization / UIActivityViewController），不依赖微博的私有类名，
//     所以微博小版本更新一般不会失效。
//   * 视频直链的参数规则（label=mp4_1080p 等）是通用 CDN 形态，
//     若微博更换 CDN 参数，只需要调整 WVDVideoURLStore.m 中的解析规则。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#import "WVDPrefs.h"
#import "WVDVideoURLStore.h"
#import "WVDActivity.h"
#import "WVDDownloader.h"

/// 下载按钮 tag，用于去重（'WVD1'）
static const NSInteger kWVDDownButtonTag = 0x57564431;

#pragma mark - 工具函数

/// 取 AVPlayerLayer 所属的 UIView：
/// 向上遍历 layer 树，第一个 delegate 是 UIView 的 layer 就是宿主视图。
static UIView *WVDHostViewForPlayerLayer(CALayer *layer) {
    for (CALayer *current = layer; current != nil; current = current.superlayer) {
        id delegate = current.delegate;
        if (delegate != nil && [delegate isKindOfClass:[UIView class]]) {
            return (UIView *)delegate;
        }
    }
    return nil;
}

#pragma mark - 调试探针（0.0.4 诊断版：可点悬浮条切换 hook 模式来定位卡死）

/// 0=全开 1=关 JSON 扫描 2=关所有网络 hook 3=全关（只留悬浮条）
typedef NS_ENUM(NSInteger, WVDHookMode) {
    WVDHookModeFull = 0,
    WVDHookModeNoJSON = 1,
    WVDHookModeNoNetwork = 2,
    WVDHookModeOff = 3,
};

static NSObject *gWVDDebugLock = nil;
static NSString *gWVDLastEvent = @"-";
static NSMutableArray<NSString *> *gWVDEventLog = nil;
static volatile int32_t gWVDResumeCount = 0;
static volatile int32_t gWVDJSONCount = 0;
static volatile int32_t gWVDAssetCount = 0;
static volatile int32_t gWVDLayoutCount = 0;
static volatile NSInteger gWVDHookMode = WVDHookModeFull;

/// 独立浮窗 + 按钮，不依赖微博的 keyWindow，所以全屏播放/看图时也不会被盖住
static UIWindow *gWVDDebugWindow = nil;
static UIButton *gWVDBadge = nil;

@class WVDPlayerOverlay;

/// 下载按钮与调试条共用同一个全屏透明窗口
static UIWindow *gWVDOverlayWindow = nil;
static UIButton *gWVDOverlayButton = nil;
static CFAbsoluteTime gWVDOverlayStamp = 0;
static NSTimer *gWVDOverlayTimer = nil;
/// 最近一次布局的播放器，按钮兜底时直接从它的 currentItem 取 AVAsset
static __weak AVPlayer *gWVDLastPlayer = nil;

static void WVDSetupDebug(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gWVDDebugLock = [[NSObject alloc] init];
        gWVDEventLog = [NSMutableArray array];
    });
}

static UIWindowScene *WVDActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

/// 事件写文件，路径：微博沙盒 tmp/wvd.log（Filza 里 应用数据 → 微博 → tmp 可看）
/// 只记录“和上一条不同”的事件，避免刷屏；即使界面卡死，文件里也能看到最后一步
static void WVDAppendLogLine(NSString *line) {
    if (line.length == 0) return;

    static dispatch_queue_t logQueue = nil;
    static NSString *lastLine = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("com.wvd.weibovideo.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
        if (lastLine != nil && [lastLine isEqualToString:line]) return;
        lastLine = [line copy];

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wvd.log"];
        NSString *content = [NSString stringWithFormat:@"%.1f %@\n", CFAbsoluteTimeGetCurrent(), line];
        NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
            return;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @finally {
            [handle closeFile];
        }
    });
}

/// 记录事件（内存 + 文件）
static void WVDMarkEvent(NSString *event) {
    WVDSetupDebug();
    @synchronized (gWVDDebugLock) {
        gWVDLastEvent = [event copy];
        if (gWVDEventLog.lastObject == nil || ![gWVDEventLog.lastObject isEqualToString:event]) {
            [gWVDEventLog addObject:event];
            while (gWVDEventLog.count > 5) [gWVDEventLog removeObjectAtIndex:0];
        }
    }
    WVDAppendLogLine(event);
}

@interface WVDDebugBadge : NSObject
@end

@implementation WVDDebugBadge

/// 点一下切换模式：FULL → NOJSON → NONET → OFF → FULL
+ (void)toggleMode:(UIButton *)sender {
    gWVDHookMode = (gWVDHookMode + 1) % 4;
    WVDMarkEvent([NSString stringWithFormat:@"MODE %ld", (long)gWVDHookMode]);
}

@end

static void WVDUpdateDebugBadge(void);

/// 调试条放在屏幕底部，避免和右上角的下载按钮重叠
static void WVDEnsureDebugWindow(void) {
    if (gWVDDebugWindow != nil) return;
    // 启动阶段（dyld 刚加载完）不建窗口，等 App 真正进入前台再建，避免卡启动
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    UIWindowScene *scene = WVDActiveWindowScene();
    if (scene == nil) return;

    CGRect bounds = scene.coordinateSpace.bounds;
    CGFloat badgeWidth = bounds.size.width - 12.0;
    CGFloat bottomInset = 0;
    for (UIWindow *candidate in scene.windows) {
        if (candidate.isKeyWindow) {
            bottomInset = candidate.safeAreaInsets.bottom;
            break;
        }
    }
    CGFloat y = bounds.size.height - bottomInset - 30.0;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = CGRectMake(6, y, badgeWidth, 22);
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = [UIColor clearColor];

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = root;

    UIButton *badge = [UIButton buttonWithType:UIButtonTypeCustom];
    badge.frame = CGRectMake(0, 0, badgeWidth, 22);
    badge.titleLabel.font = [UIFont systemFontOfSize:8.0 weight:UIFontWeightMedium];
    badge.titleLabel.adjustsFontSizeToFitWidth = YES;
    badge.titleLabel.minimumScaleFactor = 0.6;
    badge.titleLabel.lineBreakMode = NSLineBreakByClipping;
    badge.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [badge setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    badge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    [badge addTarget:[WVDDebugBadge class]
               action:@selector(toggleMode:)
     forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:badge];

    window.hidden = NO;

    gWVDDebugWindow = window;
    gWVDBadge = badge;

    WVDUpdateDebugBadge();
}

static void WVDUpdateDebugBadge(void) {
    WVDEnsureDebugWindow();
    if (gWVDBadge == nil) return;

    static NSString * const modeNames[] = { @"FULL", @"NOJSON", @"NONET", @"OFF" };
    NSString *events = @"-";
    @synchronized (gWVDDebugLock) {
        events = [gWVDEventLog componentsJoinedByString:@" | "];
        if (events.length == 0) events = @"-";
    }

    NSString *title = [NSString stringWithFormat:@"WVD %@ net%d json%d asset%d lay%d  %@",
                       modeNames[gWVDHookMode], gWVDResumeCount, gWVDJSONCount,
                       gWVDAssetCount, gWVDLayoutCount, events];
    [gWVDBadge setTitle:title forState:UIControlStateNormal];
}

/// 供其它 .m 文件打调试点（同一个 dylib 内可见）
void WVDDebugNote(NSString *note) {
    WVDMarkEvent(note);
}

/// 只记录“看起来像视频”的微博 URL，用来确认真实直链长什么样
static void WVDLogInterestingURL(NSURL *url) {
    if (url == nil) return;

    NSString *host = url.host.lowercaseString;
    if (![host containsString:@"weibo"] && ![host containsString:@"weibocdn"]) return;

    NSString *absolute = url.absoluteString;
    NSString *lower = absolute.lowercaseString;
    if (![lower containsString:@"video"] && ![lower containsString:@"mp4"] &&
        ![lower containsString:@"m3u8"] && ![lower containsString:@"play"]) return;

    NSString *trimmed = absolute.length > 100
        ? [[absolute substringToIndex:100] stringByAppendingString:@"…"]
        : absolute;
    WVDMarkEvent([NSString stringWithFormat:@"url %@", trimmed]);
}

#pragma mark - 播放器悬浮下载按钮

@interface WVDPlayerOverlay : NSObject

+ (void)showOverlay;
+ (void)hideOverlay;
+ (void)handleTap:(UIButton *)sender;

@end

@implementation WVDPlayerOverlay

/// 播放器页面出现时调用（AVPlayerLayer 每次布局都会调）
+ (void)showOverlay {
    if (!WVDIsEnabled()) {
        WVDMarkEvent(@"overlay disabled");
        [self hideOverlay];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (gWVDOverlayWindow == nil) {
            UIWindowScene *scene = WVDActiveWindowScene();
            if (scene == nil) return;

            CGRect bounds = scene.coordinateSpace.bounds;
            CGFloat width = 52.0;
            CGFloat height = 26.0;
            CGFloat top = 10.0;
            for (UIWindow *candidate in scene.windows) {
                if (candidate.isKeyWindow) {
                    top += candidate.safeAreaInsets.top;
                    break;
                }
            }

            UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
            window.windowLevel = UIWindowLevelAlert + 1;
            window.backgroundColor = [UIColor clearColor];

            UIViewController *root = [[UIViewController alloc] init];
            root.view.backgroundColor = [UIColor clearColor];
            root.view.frame = CGRectMake(0, 0, width, height);
            window.rootViewController = root;

            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.tag = kWVDDownButtonTag;
            button.frame = CGRectMake(0, 0, width, height);
            button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
            [button setTitle:@"下载" forState:UIControlStateNormal];
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
            button.layer.cornerRadius = 13.0;
            button.layer.masksToBounds = YES;
            [button addTarget:[WVDPlayerOverlay class]
                       action:@selector(handleTap:)
             forControlEvents:UIControlEventTouchUpInside];
            [root.view addSubview:button];

            window.frame = CGRectMake(bounds.size.width - width - 10.0, top, width, height);
            window.hidden = NO;

            gWVDOverlayWindow = window;
            gWVDOverlayButton = button;
        }

        if (gWVDOverlayButton.hidden) {
            gWVDOverlayButton.hidden = NO;
            WVDMarkEvent(@"overlay on");
        }
        gWVDOverlayStamp = CFAbsoluteTimeGetCurrent();

        // 播放中一直保留按钮；暂停且 6 秒内没有新的布局才隐藏
        if (gWVDOverlayTimer == nil) {
            gWVDOverlayTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
                BOOL playing = gWVDLastPlayer.rate > 0.1f;
                if (!playing &&
                    CFAbsoluteTimeGetCurrent() - gWVDOverlayStamp > 6.0) {
                    gWVDOverlayButton.hidden = YES;
                }
            }];
        }
    });
}

+ (void)hideOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        gWVDOverlayButton.hidden = YES;
    });
}

/// 点击【下载】：
/// 1. 优先用抓到的 CDN 直链（画质可控）
/// 2. 抓不到就直接导出播放器正在播的 AVAsset（微博不暴露 URL 时这条兜底）
+ (void)handleTap:(UIButton *)sender {
    WVDVideoCandidate *candidate = [[WVDVideoURLStore sharedStore] bestCandidateWithin:120];
    if (candidate != nil) {
        [[WVDDownloader shared] startDownloadWithCandidate:candidate];
        return;
    }

    AVAsset *asset = gWVDLastPlayer.currentItem.asset;
    WVDMarkEvent([NSString stringWithFormat:@"tap asset %@",
                  asset != nil ? NSStringFromClass([asset class]) : @"nil"]);
    [[WVDDownloader shared] startDownloadWithAsset:asset];
}

@end

#pragma mark - Hook：收集视频直链（全部为只读操作）

/// 快速预检：JSON 原文里连 ".mp4" 都没有就不做深度遍历。
/// 微博的图片/信息流接口会频繁返回大 JSON，逐节点扫描会拖慢主线程（表现为卡住）。
static BOOL WVDJSONDataContainsMP4(NSData *data) {
    if (data.length == 0 || data.length > 512 * 1024) return NO;

    static NSData *lowerNeedle = nil;
    static NSData *upperNeedle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lowerNeedle = [@".mp4" dataUsingEncoding:NSUTF8StringEncoding];
        upperNeedle = [@".MP4" dataUsingEncoding:NSUTF8StringEncoding];
    });

    NSRange fullRange = NSMakeRange(0, data.length);
    if ([data rangeOfData:lowerNeedle options:0 range:fullRange].location != NSNotFound) return YES;
    return [data rangeOfData:upperNeedle options:0 range:fullRange].location != NSNotFound;
}

// NSURLSession 的任务创建入口也记录一份（和下面的 -resume 互为兜底，
// 有些版本的 NSURLSessionTask 是类簇，只 hook resume 可能漏掉）
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (gWVDHookMode >= WVDHookModeNoNetwork) return %orig;
    if (WVDIsEnabled()) {
        WVDLogInterestingURL(request.URL);
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    if (gWVDHookMode >= WVDHookModeNoNetwork) return %orig;
    if (WVDIsEnabled()) {
        WVDLogInterestingURL(request.URL);
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    if (gWVDHookMode >= WVDHookModeNoNetwork) return %orig;
    if (WVDIsEnabled()) {
        WVDLogInterestingURL(request.URL);
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                    completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler {
    if (gWVDHookMode >= WVDHookModeNoNetwork) return %orig;
    if (WVDIsEnabled()) {
        WVDLogInterestingURL(request.URL);
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

%end

%hook NSURLSessionTask

// 所有网络任务启动时也能拿到原始请求；只读 URL，不做任何修改
- (void)resume {
    if (gWVDHookMode >= WVDHookModeNoNetwork) {
        %orig;
        return;
    }
    gWVDResumeCount++;
    if (WVDIsEnabled()) {
        WVDLogInterestingURL([self originalRequest].URL);
        [[WVDVideoURLStore sharedStore] considerRequest:[self originalRequest]];
    }
    %orig;
}

%end

%hook AVURLAsset

// 播放器创建资源时会走到这里，可以拿到 m3u8 / mp4 的地址
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    if (gWVDHookMode == WVDHookModeOff) return %orig;
    gWVDAssetCount++;
    if (WVDIsEnabled()) {
        NSDictionary *headerFields = options[@"AVURLAssetHTTPHeaderFieldsKey"];
        [[WVDVideoURLStore sharedStore] considerURL:URL headerFields:headerFields];
    }
    WVDMarkEvent([NSString stringWithFormat:@"asset %@", URL.absoluteString.pathExtension ?: @"?"]);
    return %orig;
}

%end

static void WVDShowOverlayIfFullScreen(void);

// 老 API 入口：+[AVAsset assetWithURL:] 以及直接拿 asset 建播放项
%hook AVAsset

+ (instancetype)assetWithURL:(NSURL *)URL {
    if (gWVDHookMode != WVDHookModeOff && WVDIsEnabled()) {
        NSString *extension = URL.pathExtension.lowercaseString;
        WVDMarkEvent([NSString stringWithFormat:@"assetW %@", extension.length ? extension : @"?"]);
        [[WVDVideoURLStore sharedStore] considerAssetURL:URL];
    }
    return %orig;
}

%end

%hook AVPlayerItem

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    if (gWVDHookMode != WVDHookModeOff && WVDIsEnabled()) {
        if ([asset isKindOfClass:[AVURLAsset class]]) {
            NSURL *URL = ((AVURLAsset *)asset).URL;
            NSString *extension = URL.pathExtension.lowercaseString;
            WVDMarkEvent([NSString stringWithFormat:@"itemA %@", extension.length ? extension : @"?"]);
            [[WVDVideoURLStore sharedStore] considerAssetURL:URL];
        }
        WVDShowOverlayIfFullScreen();
    }
    return %orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    if (gWVDHookMode != WVDHookModeOff && WVDIsEnabled()) {
        if ([asset isKindOfClass:[AVURLAsset class]]) {
            NSURL *URL = ((AVURLAsset *)asset).URL;
            NSString *extension = URL.pathExtension.lowercaseString;
            WVDMarkEvent([NSString stringWithFormat:@"itemA %@", extension.length ? extension : @"?"]);
            [[WVDVideoURLStore sharedStore] considerAssetURL:URL];
        }
        WVDShowOverlayIfFullScreen();
    }
    return %orig;
}

%end

%hook NSJSONSerialization

// 微博视频信息接口（playback_list 等）里的 MP4 地址，兜底从 JSON 响应中提取。
// 只遍历返回对象里的字符串，不会改动 JSON 内容。
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error {
    id object = %orig;
    if (gWVDHookMode == WVDHookModeNoJSON || gWVDHookMode == WVDHookModeOff) return object;
    if (object != nil && WVDIsEnabled() && WVDJSONDataContainsMP4(data)) {
        // 扫描放到后台串行队列，绝不在解析 JSON 的线程（常常是主线程）上做遍历，
        // 否则图片/信息流页会明显卡顿甚至假死。
        static dispatch_queue_t scanQueue = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            scanQueue = dispatch_queue_create("com.wvd.weibovideo.jsonscan", DISPATCH_QUEUE_SERIAL);
        });
        gWVDJSONCount++;
        WVDMarkEvent(@"json");
        dispatch_async(scanQueue, ^{
            [[WVDVideoURLStore sharedStore] considerJSONObject:object];
        });
    }
    return object;
}

%end

#pragma mark - Hook：播放器界面上的【下载】按钮

%hook AVPlayerLayer

// 播放器每次布局（首次显示、旋转、全屏切换）都会调用，用来挂按钮和纠正位置
- (void)layoutSublayers {
    if (gWVDHookMode == WVDHookModeOff) {
        %orig;
        return;
    }
    %orig;

    // CALayer 布局理论上在主线程，但为稳妥起见仍然做一次检查，避免后台线程动 UI
    if (![NSThread isMainThread]) return;

    // 加一层重入保护：挂按钮会触发新的布局，避免 layout 互相触发形成死循环
    static BOOL isAttaching = NO;
    if (isAttaching) return;
    isAttaching = YES;

    if (self.player != nil) {
        gWVDLastPlayer = self.player;
    }

    UIView *hostView = WVDHostViewForPlayerLayer(self);
    if (hostView != nil) {
        CGSize size = hostView.bounds.size;
        // 只认“较大的播放器视图”（全屏播放器 / 视频详情页），
        // 避免信息流里的小视频卡片也弹出按钮
        if (size.width >= 240.0 && size.height >= 180.0) {
            gWVDLayoutCount++;
            WVDMarkEvent([NSString stringWithFormat:@"layer %.0fx%.0f", size.width, size.height]);
            [WVDPlayerOverlay showOverlay];
        }
    }

    isAttaching = NO;
}

%end

#pragma mark - Hook：AVPlayer 开始播放时挂按钮（不依赖 AVPlayerLayer）

/// 当前最上层 VC 的 view，用于把按钮挂到全屏播放页上
static UIView *WVDTopPresentedView(void) {
    UIWindowScene *scene = WVDActiveWindowScene();
    UIWindow *window = nil;
    if (scene != nil) {
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    if (window == nil) return nil;

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller.view;
}

/// 只在“接近全屏的播放页”显示按钮，信息流小窗不弹
static void WVDShowOverlayIfFullScreen(void) {
    if (gWVDHookMode == WVDHookModeOff) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = WVDTopPresentedView();
        if (view == nil) return;

        CGSize viewSize = view.bounds.size;
        CGRect screen = UIScreen.mainScreen.bounds;
        if (viewSize.width < screen.size.width * 0.9 ||
            viewSize.height < screen.size.height * 0.5) return;

        [WVDPlayerOverlay showOverlay];
    });
}

%hook AVPlayer

- (void)play {
    %orig;
    WVDShowOverlayIfFullScreen();
}

- (void)playImmediatelyAtRate:(float)rate {
    %orig;
    WVDShowOverlayIfFullScreen();
}

- (void)setRate:(float)rate {
    %orig;
    if (rate > 0.0f) {
        WVDShowOverlayIfFullScreen();
    }
}

%end

#pragma mark - Hook：播放器资源地址（AVURLAsset / AVPlayerItem 类方法）

// 微博部分版本不走 -initWithURL:options:，而是走类方法，这里补上，顺便拿到真正的播放地址
%hook AVURLAsset

+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    if (gWVDHookMode != WVDHookModeOff && WVDIsEnabled()) {
        NSString *extension = URL.pathExtension.lowercaseString;
        WVDMarkEvent([NSString stringWithFormat:@"asset+ %@", extension.length ? extension : @"?"]);
        [[WVDVideoURLStore sharedStore] considerAssetURL:URL];
    }
    return %orig;
}

%end

%hook AVPlayerItem

+ (instancetype)playerItemWithURL:(NSURL *)URL {
    if (gWVDHookMode != WVDHookModeOff && WVDIsEnabled()) {
        NSString *extension = URL.pathExtension.lowercaseString;
        WVDMarkEvent([NSString stringWithFormat:@"item %@", extension.length ? extension : @"?"]);
        [[WVDVideoURLStore sharedStore] considerAssetURL:URL];
        WVDShowOverlayIfFullScreen();
    }
    return %orig;
}

- (instancetype)initWithURL:(NSURL *)URL
   automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    if (gWVDHookMode != WVDHookModeOff && WVDIsEnabled()) {
        NSString *extension = URL.pathExtension.lowercaseString;
        WVDMarkEvent([NSString stringWithFormat:@"item %@", extension.length ? extension : @"?"]);
        [[WVDVideoURLStore sharedStore] considerAssetURL:URL];
        WVDShowOverlayIfFullScreen();
    }
    return %orig;
}

%end

#pragma mark - Hook：分享菜单追加【下载视频】

%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(NSArray<UIActivity *> *)applicationActivities {
    if (gWVDHookMode == WVDHookModeOff) return %orig;
    if (WVDIsEnabled()) {
        // 判断分享内容里是否直接带有微博视频地址
        BOOL itemsContainVideo = NO;
        for (id item in activityItems) {
            NSURL *url = [WVDVideoURLStore videoURLFromActivityItem:item];
            if ([[WVDVideoURLStore sharedStore] isWeiboVideoURL:url]) {
                itemsContainVideo = YES;
                break;
            }
        }

        // 没有视频内容时，只有“刚刚播放过视频”才会追加，避免污染图片/文字分享
        WVDVideoCandidate *recent = itemsContainVideo
            ? nil
            : [[WVDVideoURLStore sharedStore] bestCandidateWithin:10];

        if (itemsContainVideo || recent != nil) {
            NSMutableArray<UIActivity *> *activities = applicationActivities
                ? [applicationActivities mutableCopy]
                : [NSMutableArray array];

            BOOL alreadyAdded = NO;
            for (UIActivity *activity in activities) {
                if ([activity isKindOfClass:[WVDVideoShareActivity class]]) {
                    alreadyAdded = YES;
                    break;
                }
            }

            if (!alreadyAdded) {
                [activities addObject:[[WVDVideoShareActivity alloc] init]];
                applicationActivities = activities;
            }
        }
    }

    return %orig(activityItems, applicationActivities);
}

%end

#pragma mark - 加载标记

// 注入后可用控制台/`log stream` 搜索 WVD 确认 dylib 是否真的被加载；
// 同时启动左上角状态条，没条件看日志时直接看屏幕也能判断
%ctor {
    WVDSetupDebug();
    NSLog(@"[WVD] WeiboVideoDownloader loaded");
    WVDMarkEvent(@"loaded");

    dispatch_async(dispatch_get_main_queue(), ^{
        WVDUpdateDebugBadge();
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                       repeats:YES
                                         block:^(NSTimer *timer) {
            WVDUpdateDebugBadge();
        }];
    });
}
