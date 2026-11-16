#import <Foundation/Foundation.h>

/// ---- 统一的目录结构（全项目只有这里写死路径）----
///   /var/mobile/Documents/ThemeBoard/
///   ├── Themes/   主题包（IconBundles/<反向域名>.png …）
///   └── Assets/   素材包（遮罩 / 边框 / 阴影）
/// 若 /var/mobile/Documents 不可写（没越狱 / 被沙盒限制），自动回退到
/// App 容器里的 Documents/ThemeBoard，保证功能可用。

NSString *TBThemeBoardRoot(void);
NSString *TBThemesRoot(void);
NSString *TBAssetsRoot(void);

/// 建立 Themes / Assets（幂等）。返回 Themes 根是否可写。
BOOL TBEnsureThemeBoardDirs(void);

/// 旧版本用过的主题根目录（迁移来源，顺序即优先级）
NSArray<NSString *> *TBLegacyThemeRoots(void);

/// 启动迁移：把旧目录里的子目录**复制**到 ThemeBoard/Themes/
/// （重名跳过，失败跳过并写日志，绝不删源、绝不丢用户主题）。
/// 返回一行摘要，供 App 日志 / 状态页显示。
NSString *TBMigrateLegacyThemeDirectories(void);

/// 用外部 App 打开一个目录：filza://view → shareddocuments:// → filza://
/// 返回 YES 表示已交给系统处理（不一定真装了这个 App）。
BOOL TBOpenPathExternally(NSString *path);

/// 给路径加 / 去掉结尾斜杠后的比较
BOOL TBPathEqualToPath(NSString *a, NSString *b);
