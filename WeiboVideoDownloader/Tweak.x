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

#pragma mark - 调试探针（0.0.3 诊断版，定位“没按钮 / 打开图片卡死”）

static NSObject *gWVDDebugLock = nil;
static NSString *gWVDLastEvent = @"-";
static int32_t gWVDResumeCount = 0;
static int32_t gWVDJSONCount = 0;
static int32_t gWVDAssetCount = 0;
static int32_t gWVDLayoutCount = 0;
static UILabel *gWVDBadge = nil;

static void WVDSetupDebug(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gWVDDebugLock = [[NSObject alloc] init];
    });
}

/// 记录最近一次触发的 hook，屏幕上直接可见，卡住时截图就能看到卡在哪一步
static void WVDMarkEvent(NSString *event) {
    WVDSetupDebug();
    @synchronized (gWVDDebugLock) {
        gWVDLastEvent = [event copy];
    }
}

static UIWindow *WVDKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

/// 屏幕左上角的状态条：证明 dylib 是否真的加载，以及各类 hook 的触发次数
static void WVDUpdateDebugBadge(void) {
    if (gWVDBadge == nil) {
        UIWindow *window = WVDKeyWindow();
        if (window == nil) return;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(6, 44, 360, 20)];
        label.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightMedium];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        label.userInteractionEnabled = NO;
        label.text = @"WVD 0.0.3 loading";
        [window addSubview:label];
        gWVDBadge = label;
    }

    NSString *event = @"-";
    @synchronized (gWVDDebugLock) {
        event = gWVDLastEvent;
    }
    gWVDBadge.text = [NSString stringWithFormat:@"WVD 0.0.3 net%d json%d asset%d lay%d %@",
                      gWVDResumeCount, gWVDJSONCount, gWVDAssetCount, gWVDLayoutCount, event];
}

#pragma mark - 播放器悬浮下载按钮

@interface WVDPlayerOverlay : NSObject

+ (void)attachToHostViewIfNeeded:(UIView *)hostView;
+ (CGRect)frameForButtonInHostView:(UIView *)hostView;

@end

/// 全局只保留一个按钮，播放器切换/复用时不会越挂越多
static __weak UIButton *gWVDOverlayButton = nil;

@implementation WVDPlayerOverlay

+ (void)attachToHostViewIfNeeded:(UIView *)hostView {
    if (hostView == nil) return;

    // 总开关关闭：清理已存在的按钮
    if (!WVDIsEnabled()) {
        [gWVDOverlayButton removeFromSuperview];
        gWVDOverlayButton = nil;
        return;
    }

    // 只在“较大的播放器视图”上挂按钮（全屏播放器 / 视频详情页），
    // 避免在信息流里的小视频卡片上到处出现按钮。
    // 如果发现按钮出现的场景不合适，调整这两个阈值即可。
    CGSize size = hostView.bounds.size;
    if (size.width < 240.0 || size.height < 180.0) return;

    UIButton *button = gWVDOverlayButton;

    if (button == nil) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = kWVDDownButtonTag;
        button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        [button setTitle:@"下载" forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
        button.layer.cornerRadius = 6.0;
        button.layer.masksToBounds = YES;
        [button addTarget:[WVDPlayerOverlay class]
                   action:@selector(handleTap:)
         forControlEvents:UIControlEventTouchUpInside];
    } else if (button.superview != hostView) {
        // 换到新的播放器视图上
        [button removeFromSuperview];
    } else {
        // 已经挂在这个视图上：只在位置真的变化时才改 frame。
        // 这里不能每次都改 frame / bringSubviewToFront，否则会在 layoutSublayers
        // 里反复触发重新布局，主线程卡在 CA 提交里出不来（表现为界面卡死）。
        CGRect targetFrame = [self frameForButtonInHostView:hostView];
        if (!CGRectEqualToRect(button.frame, targetFrame)) {
            button.frame = targetFrame;
            [hostView bringSubviewToFront:button];
        }
        return;
    }

    button.frame = [self frameForButtonInHostView:hostView];
    [hostView addSubview:button];
    [hostView bringSubviewToFront:button];
    gWVDOverlayButton = button;
}

+ (CGRect)frameForButtonInHostView:(UIView *)hostView {
    // 按钮放在右上角；若与微博自身控件冲突，可改这里的 inset / 坐标
    CGFloat width = 64.0;
    CGFloat height = 30.0;
    CGFloat inset = 12.0;

    CGFloat top = inset;
    if (@available(iOS 11.0, *)) {
        top += hostView.safeAreaInsets.top;
    }

    CGRect bounds = hostView.bounds;
    return CGRectMake(CGRectGetMaxX(bounds) - width - inset, top, width, height);
}

/// 点击【下载】：取最近 120 秒内、与本次播放同一批抓到的最高画质 MP4
+ (void)handleTap:(UIButton *)sender {
    WVDVideoCandidate *candidate = [[WVDVideoURLStore sharedStore] bestCandidateWithin:120];
    [[WVDDownloader shared] startDownloadWithCandidate:candidate];
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
    if (WVDIsEnabled()) {
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    if (WVDIsEnabled()) {
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    if (WVDIsEnabled()) {
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                    completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler {
    if (WVDIsEnabled()) {
        [[WVDVideoURLStore sharedStore] considerRequest:request];
    }
    return %orig;
}

%end

%hook NSURLSessionTask

// 所有网络任务启动时也能拿到原始请求；只读 URL，不做任何修改
- (void)resume {
    gWVDResumeCount++;
    if (WVDIsEnabled()) {
        [[WVDVideoURLStore sharedStore] considerRequest:[self originalRequest]];
    }
    %orig;
}

%end

%hook AVURLAsset

// 播放器创建资源时会走到这里，可以拿到 m3u8 / mp4 的地址
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    gWVDAssetCount++;
    if (WVDIsEnabled()) {
        NSDictionary *headerFields = options[@"AVURLAssetHTTPHeaderFieldsKey"];
        [[WVDVideoURLStore sharedStore] considerURL:URL headerFields:headerFields];
    }
    WVDMarkEvent([NSString stringWithFormat:@"asset %@", URL.absoluteString.pathExtension ?: @"?"]);
    return %orig;
}

%end

%hook NSJSONSerialization

// 微博视频信息接口（playback_list 等）里的 MP4 地址，兜底从 JSON 响应中提取。
// 只遍历返回对象里的字符串，不会改动 JSON 内容。
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error {
    id object = %orig;
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
    %orig;

    // CALayer 布局理论上在主线程，但为稳妥起见仍然做一次检查，避免后台线程动 UI
    if (![NSThread isMainThread]) return;

    // 加一层重入保护：挂按钮会触发新的布局，避免 layout 互相触发形成死循环
    static BOOL isAttaching = NO;
    if (isAttaching) return;
    isAttaching = YES;

    UIView *hostView = WVDHostViewForPlayerLayer(self);
    if (hostView != nil) {
        gWVDLayoutCount++;
        CGSize size = hostView.bounds.size;
        WVDMarkEvent([NSString stringWithFormat:@"layer %.0fx%.0f", size.width, size.height]);
        // 内部会检查总开关，关闭时会移除已挂的按钮
        [WVDPlayerOverlay attachToHostViewIfNeeded:hostView];
    }

    isAttaching = NO;
}

%end

#pragma mark - Hook：分享菜单追加【下载视频】

%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(NSArray<UIActivity *> *)applicationActivities {
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

    dispatch_async(dispatch_get_main_queue(), ^{
        WVDUpdateDebugBadge();
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                       repeats:YES
                                         block:^(NSTimer *timer) {
            WVDUpdateDebugBadge();
        }];
    });
}
