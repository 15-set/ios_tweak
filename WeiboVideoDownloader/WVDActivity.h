//
//  WVDActivity.h
//  微博视频下载器 - 分享菜单里的【下载视频】入口
//
//  继承系统的 UIActivity，把自己追加到 UIActivityViewController 的
//  applicationActivities 数组里，不会覆盖/干扰微博原有的分享项。
//

#import <UIKit/UIKit.h>
#import "WVDVideoURLStore.h"

@interface WVDVideoShareActivity : UIActivity

/// 当前视频候选；prepareWithActivityItems: 时会尝试从分享内容里重新解析
@property (nonatomic, strong) WVDVideoCandidate *candidate;

@end
