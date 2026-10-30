// themeboard-helper: 以 root 身份执行少量文件操作
// 用法：
//   themeboard-helper --test <输出文件>          写一份身份/路径报告
//   themeboard-helper --copy <源> <目标>         复制文件（覆盖）
//   themeboard-helper --rm <路径>                删除
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <limits.h>
#include <libgen.h>

static void mkdirs(const char *path) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

static int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    char tmppath[PATH_MAX];
    snprintf(tmppath, sizeof(tmppath), "%s.tmp", dst);
    FILE *out = fopen(tmppath, "wb");
    if (!out) { fclose(in); return -2; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
    fclose(in);
    fflush(out);
    fclose(out);
    chmod(tmppath, 0755);
    if (rename(tmppath, dst) != 0) { unlink(tmppath); return -3; }
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "--test") == 0) {
        const char *out = argv[2];
        char dir[PATH_MAX];
        snprintf(dir, sizeof(dir), "%s", out);
        mkdirs(dirname(dir));

        char jb[PATH_MAX];
        ssize_t r = readlink("/var/jb", jb, sizeof(jb) - 1);
        if (r > 0) jb[r] = 0; else snprintf(jb, sizeof(jb), "(no link)");

        struct stat st;
        int can = (stat("/var/jb/Library/MobileSubstrate/DynamicLibraries", &st) == 0) ? 1 : 0;

        FILE *f = fopen(out, "w");
        if (!f) return 2;
        fprintf(f, "uid=%d euid=%d gid=%d egid=%d\n", getuid(), geteuid(), getgid(), getegid());
        fprintf(f, "jbroot=%s\n", jb);
        fprintf(f, "dylibdir=%s mode=%o uid=%d\n", can ? "可见" : "不可见",
                can ? (unsigned)st.st_mode : 0, can ? (int)st.st_uid : -1);
        fprintf(f, "can_write=%d\n", can ? (access("/var/jb/Library/MobileSubstrate/DynamicLibraries", W_OK) == 0) : 0);
        fclose(f);
        return 0;
    }

    if (argc >= 4 && strcmp(argv[1], "--copy") == 0) {
        return copy_file(argv[2], argv[3]) == 0 ? 0 : 3;
    }
    if (argc >= 3 && strcmp(argv[1], "--rm") == 0) {
        return unlink(argv[2]) == 0 ? 0 : 4;
    }
    fprintf(stderr, "usage: %s --test <out> | --copy <src> <dst> | --rm <path>\n", argv[0]);
    return 1;
}
