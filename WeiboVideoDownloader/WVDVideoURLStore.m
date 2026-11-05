//
//  WVDVideoURLStore.m
//  微博视频下载器 - 视频直链收集与画质排序
//
//  注意：
//   1. 微博是闭源 App，视频 CDN 的参数格式可能随版本变化，
//      画质解析规则集中在 WVDQualityScoreForURL() 里，后续修改只改这一处即可。
//   2. 这里的“抓取”全部是只读操作：不替换请求、不修改响应、不注册 URLProtocol。
//

#import "WVDVideoURLStore.h"

/// 最多缓存多少条候选
static const NSUInteger kWVDMaxCandidates = 5;
/// 候选的过期时间（秒）
static const NSTimeInterval kWVDCandidateLifetime = 180.0;

#pragma mark - URL 判断与画质评分

/// 是否为微博视频资源：MP4 直链或 HLS 播放列表
static BOOL WVDURLIsWeiboVideo(NSURL *url) {
    if (url == nil) return NO;

    NSString *absolute = url.absoluteString.lowercaseString;
    if (absolute.length == 0) return NO;
    if (![absolute containsString:@".mp4"] && ![absolute containsString:@".m3u8"]) return NO;

    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    // 微博视频 CDN：video.weibo.com / f.video.weibocdn.com 等
    return ([host containsString:@"weibo"] || [host containsString:@"weibocdn"]);
}

/// 从 URL 推断画质评分（越大越清晰）
/// 微博常见形态：
///   https://f.video.weibocdn.com/o0/xxxx.mp4?label=mp4_1080p&template=1920x1080.25.0
static NSInteger WVDQualityScoreForURL(NSURL *url) {
    if (url == nil) return 0;

    NSString *lower = url.absoluteString.lowercaseString;
    NSInteger best = 0;

    static NSRegularExpression *labelRegex = nil;
    static NSRegularExpression *sizeRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // label=mp4_1080p / mp4_720p / mp4_480p ...
        labelRegex = [NSRegularExpression regularExpressionWithPattern:@"mp4_(\\d{3,4})p"
                                                              options:0
                                                                error:nil];
        // template=1920x1080 / 1280x720 ...
        sizeRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{3,4})x(\\d{3,4})"
                                                             options:0
                                                               error:nil];
    });

    NSRange fullRange = NSMakeRange(0, lower.length);

    NSTextCheckingResult *result = [labelRegex firstMatchInString:lower options:0 range:fullRange];
    if (result && result.numberOfRanges > 1) {
        best = MAX(best, [[lower substringWithRange:[result rangeAtIndex:1]] integerValue]);
    }

    result = [sizeRegex firstMatchInString:lower options:0 range:fullRange];
    if (result && result.numberOfRanges > 2) {
        // 第二个分组是高度
        best = MAX(best, [[lower substringWithRange:[result rangeAtIndex:2]] integerValue]);
    }

    // 兼容部分旧版本使用的画质标记
    if ([lower containsString:@"mp4_ld"]) best = MAX(best, 360);
    if ([lower containsString:@"mp4_sd"]) best = MAX(best, 480);
    if ([lower containsString:@"mp4_hd"]) best = MAX(best, 720);

    // 完全识别不到画质时给一个最低分，保证仍然可下载
    return best <= 0 ? 1 : best;
}

#pragma mark - WVDVideoCandidate

@implementation WVDVideoCandidate

+ (instancetype)candidateWithURL:(NSURL *)url request:(NSURLRequest *)request {
    WVDVideoCandidate *candidate = [[self alloc] init];
    candidate.url = url;
    candidate.request = request;
    candidate.capturedAt = [NSDate date];
    candidate.isHLS = [url.absoluteString.lowercaseString containsString:@".m3u8"];
    candidate.quality = WVDQualityScoreForURL(url);
    // HLS 地址里通常没有画质参数，给一个中等分值，避免被判成最差
    if (candidate.isHLS && candidate.quality <= 1) {
        candidate.quality = 720;
    }
    return candidate;
}

@end

#pragma mark - WVDVideoURLStore

@interface WVDVideoURLStore ()

- (void)_addRequest:(NSURLRequest *)request;
- (void)_scanJSONObject:(id)object depth:(NSInteger)depth budget:(NSUInteger *)budget;

@end

@implementation WVDVideoURLStore {
    NSMutableArray<WVDVideoCandidate *> *_candidates;
}

+ (instancetype)sharedStore {
    static WVDVideoURLStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[WVDVideoURLStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _candidates = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isWeiboVideoURL:(NSURL *)url {
    return WVDURLIsWeiboVideo(url);
}

- (void)considerRequest:(NSURLRequest *)request {
    if (request == nil) return;
    if (!WVDURLIsWeiboVideo(request.URL)) return;
    [self _addRequest:request];
}

- (void)considerURL:(NSURL *)url headerFields:(NSDictionary *)headerFields {
    if (!WVDURLIsWeiboVideo(url)) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // AVURLAsset 可能通过 AVURLAssetHTTPHeaderFieldsKey 传入自定义请求头，一并保留
    if ([headerFields isKindOfClass:[NSDictionary class]] && headerFields.count > 0) {
        [headerFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
                [request setValue:value forHTTPHeaderField:key];
            }
        }];
    }
    [self _addRequest:request];
}

- (void)considerAssetURL:(NSURL *)url {
    if (!WVDURLIsWeiboVideo(url)) return;
    [self _addRequest:[NSURLRequest requestWithURL:url]];
}

- (void)considerJSONObject:(id)object {
    // 每次最多检查 2000 个节点，防止超大 JSON 影响微博流畅度
    NSUInteger budget = 2000;
    [self _scanJSONObject:object depth:0 budget:&budget];
}

/// 只递归扫描容器里的字符串值，深度和节点数量都做了限制，避免影响微博性能
- (void)_scanJSONObject:(id)object depth:(NSInteger)depth budget:(NSUInteger *)budget {
    if (object == nil || depth > 6 || budget == NULL || *budget == 0) return;
    (*budget)--;

    if ([object isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)object;
        NSString *lower = string.lowercaseString;
        if (string.length < 2048 &&
            [lower containsString:@".mp4"] &&
            [lower containsString:@"weibo"] &&
            ([string hasPrefix:@"http://"] || [string hasPrefix:@"https://"])) {
            NSURL *url = [NSURL URLWithString:string];
            if (WVDURLIsWeiboVideo(url)) {
                [self considerURL:url headerFields:nil];
            }
        }
        return;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)object;
        NSUInteger count = MIN(array.count, (NSUInteger)200);
        for (NSUInteger i = 0; i < count; i++) {
            if (*budget == 0) break;
            [self _scanJSONObject:array[i] depth:depth + 1 budget:budget];
        }
        return;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        NSUInteger visited = 0;
        for (id key in dictionary) {
            if (visited++ > 200 || *budget == 0) break;
            [self _scanJSONObject:dictionary[key] depth:depth + 1 budget:budget];
        }
    }
}

/// 真正写入候选列表（线程安全）
- (void)_addRequest:(NSURLRequest *)request {
    WVDVideoCandidate *candidate = [WVDVideoCandidate candidateWithURL:request.URL request:request];

    @synchronized (self) {
        // 同一 URL 只保留一条，同时刷新请求头与抓取时间
        NSUInteger index = NSNotFound;
        for (NSUInteger i = 0; i < _candidates.count; i++) {
            if ([_candidates[i].url.absoluteString isEqualToString:candidate.url.absoluteString]) {
                index = i;
                break;
            }
        }
        if (index != NSNotFound) {
            [_candidates removeObjectAtIndex:index];
        }

        [_candidates addObject:candidate];

        // 控制数量上限
        while (_candidates.count > kWVDMaxCandidates) {
            [_candidates removeObjectAtIndex:0];
        }

        // 清理过期候选
        NSDate *expireLine = [NSDate dateWithTimeIntervalSinceNow:-kWVDCandidateLifetime];
        NSMutableArray<WVDVideoCandidate *> *expired = [NSMutableArray array];
        for (WVDVideoCandidate *item in _candidates) {
            if ([item.capturedAt compare:expireLine] == NSOrderedAscending) {
                [expired addObject:item];
            }
        }
        [_candidates removeObjectsInArray:expired];
    }
}

- (WVDVideoCandidate *)bestCandidateWithin:(NSTimeInterval)seconds {
    NSDate *timeLine = [NSDate dateWithTimeIntervalSinceNow:-seconds];

    @synchronized (self) {
        // 先找到“最新的那条直链”，再只在它前后 8 秒内的候选里挑画质最高的。
        // 这样可以避免信息流里连续刷过多个视频时，把别的视频的地址选进来。
        WVDVideoCandidate *newest = nil;
        for (WVDVideoCandidate *candidate in _candidates) {
            if ([candidate.capturedAt compare:timeLine] == NSOrderedAscending) continue;
            if (newest == nil ||
                [candidate.capturedAt compare:newest.capturedAt] == NSOrderedDescending) {
                newest = candidate;
            }
        }
        if (newest == nil) return nil;

        NSDate *groupLine = [newest.capturedAt dateByAddingTimeInterval:-8.0];
        WVDVideoCandidate *best = newest;
        for (WVDVideoCandidate *candidate in _candidates) {
            if ([candidate.capturedAt compare:groupLine] == NSOrderedAscending) continue;
            if (candidate.quality > best.quality) {
                best = candidate;
            }
        }
        return best;
    }
}

#pragma mark - 分享菜单 item 解析

+ (NSURL *)videoURLFromActivityItem:(id)item {
    if ([item isKindOfClass:[NSURL class]]) {
        return (NSURL *)item;
    }

    if (![item isKindOfClass:[NSString class]]) return nil;

    NSString *string = (NSString *)item;
    if (string.length == 0 || string.length > 4000) return nil;

    // 分享出来的可能是一段带链接的文案，这里用正则抠出第一个 http(s) 链接
    static NSRegularExpression *urlRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        urlRegex = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>]+"
                                                            options:NSRegularExpressionCaseInsensitive
                                                              error:nil];
    });

    NSTextCheckingResult *result = [urlRegex firstMatchInString:string
                                                       options:0
                                                         range:NSMakeRange(0, string.length)];
    if (result == nil) return nil;

    NSString *link = [string substringWithRange:result.range];
    return [NSURL URLWithString:link];
}

@end
