//
//  WVDDownloader.h
//  微博视频下载器 - 后台下载并保存到系统相册
//

#import <Foundation/Foundation.h>
#import "WVDVideoURLStore.h"

@interface WVDDownloader : NSObject

+ (instancetype)shared;

/// 开始下载。candidate 为 nil 时弹出“未获取到视频直链”的失败提示。
/// 会依次弹出：开始下载 → 下载成功 / 下载失败
- (void)startDownloadWithCandidate:(WVDVideoCandidate *)candidate;

@end
