//
//  WVDVideoURLStore.h
//  微博视频下载器 - 视频直链收集与画质排序
//
//  设计原则（对应需求“只处理微博视频、不干扰其它网络请求”）：
//   * 只“读取”微博发起的 URL / JSON 响应，绝不修改、绝不阻断任何请求；
//   * 只接受 host 属于微博 CDN（weibo / weibocdn）且路径为 .mp4 的地址；
//   * 同一 URL 只保留一条，最多缓存 5 条，避免内存增长。
//

#import <Foundation/Foundation.h>

/// 一条候选的视频直链
@interface WVDVideoCandidate : NSObject

/// 视频 URL
@property (nonatomic, strong) NSURL *url;
/// 抓到的原始请求（保留微博自己带的 Cookie / Referer 等头），下载时直接复用，兼容性最好
@property (nonatomic, strong) NSURLRequest *request;
/// 画质评分：数值越大越清晰（由 URL 中的 label=mp4_1080p 等参数推算）
@property (nonatomic, assign) NSInteger quality;
/// 抓取时间
@property (nonatomic, strong) NSDate *capturedAt;
/// 是否为 HLS（.m3u8）；是的话下载时用 AVAssetExportSession 导出成 mp4
@property (nonatomic, assign) BOOL isHLS;

+ (instancetype)candidateWithURL:(NSURL *)url request:(NSURLRequest *)request;

@end


@interface WVDVideoURLStore : NSObject

+ (instancetype)sharedStore;

/// 是否为微博视频 MP4 直链（host 含 weibo/weibocdn，且 URL 含 .mp4）
- (BOOL)isWeiboVideoURL:(NSURL *)url;

/// 记录一条网络请求（仅读取 URL）
- (void)considerRequest:(NSURLRequest *)request;

/// 记录 AVURLAsset / 播放器使用的资源地址
- (void)considerURL:(NSURL *)url headerFields:(NSDictionary *)headerFields;

/// 记录播放器真正加载的资源地址（mp4 或 m3u8），比网络层抓取更准确
- (void)considerAssetURL:(NSURL *)url;

/// 从 JSON 响应中兜底提取 MP4 直链（微博视频信息接口的 playback_list 等）
/// 只遍历字符串值，不改动任何 JSON 对象本身
- (void)considerJSONObject:(id)object;

/// 取最近 seconds 秒内画质最高的候选；没有则返回 nil
- (WVDVideoCandidate *)bestCandidateWithin:(NSTimeInterval)seconds;

/// 从分享菜单的 activityItems 里提取微博视频 URL（支持 NSURL 或带链接的字符串）
+ (NSURL *)videoURLFromActivityItem:(id)item;

@end
