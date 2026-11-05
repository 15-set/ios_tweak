//
//  WVDActivity.m
//  微博视频下载器 - 分享菜单里的【下载视频】入口
//

#import "WVDActivity.h"
#import "WVDPrefs.h"
#import "WVDDownloader.h"

@interface WVDVideoShareActivity ()

- (WVDVideoCandidate *)_candidateFromActivityItems:(NSArray *)activityItems;

@end

@implementation WVDVideoShareActivity

#pragma mark - UIActivity 必要属性

// 唯一标识，避免和系统/微博自己的分享项冲突
- (NSString *)activityType {
    return @"com.wvd.weibovideo.download";
}

- (NSString *)activityTitle {
    return @"下载视频";
}

- (UIImage *)activityImage {
    if (@available(iOS 13.0, *)) {
        // 系统自带图标，无需额外图片资源
        return [UIImage systemImageNamed:@"square.and.arrow.down"];
    }
    return nil;
}

#pragma mark - 是否能对当前分享内容展示

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems {
    if (!WVDIsEnabled()) return NO;
    if (self.candidate != nil) return YES;

    // 分享内容里可能直接带视频地址，先尝试解析
    if ([self _candidateFromActivityItems:activityItems] != nil) return YES;

    // 否则用最近抓到的视频直链（播放器刚播放过视频的情况下可用）
    if ([[WVDVideoURLStore sharedStore] bestCandidateWithin:120] != nil) return YES;
    return NO;
}

#pragma mark - 准备与执行

- (void)prepareWithActivityItems:(NSArray *)activityItems {
    // 优先使用分享内容里的真实视频地址；没有就回退到全局最近抓到的地址
    if (self.candidate == nil) {
        self.candidate = [self _candidateFromActivityItems:activityItems];
    }
    if (self.candidate == nil) {
        self.candidate = [[WVDVideoURLStore sharedStore] bestCandidateWithin:120];
    }
}

- (void)performActivity {
    [[WVDDownloader shared] startDownloadWithCandidate:self.candidate];
    [self activityDidFinish:YES];
}

#pragma mark - 从分享内容解析视频地址

- (WVDVideoCandidate *)_candidateFromActivityItems:(NSArray *)activityItems {
    for (id item in activityItems) {
        NSURL *url = [WVDVideoURLStore videoURLFromActivityItem:item];
        if (url == nil) continue;

        WVDVideoURLStore *store = [WVDVideoURLStore sharedStore];
        if ([store isWeiboVideoURL:url]) {
            return [WVDVideoCandidate candidateWithURL:url request:nil];
        }
    }
    return nil;
}

@end
