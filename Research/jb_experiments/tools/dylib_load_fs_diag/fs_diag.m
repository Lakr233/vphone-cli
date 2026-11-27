// Диагностический стенд: два фрагмента из треда thr_itairhc6yq (18_dylib_load_fs_diag.md).
// Log(NSString*) — функция приложения: одна строка в UITextView + NSLog.
// Статус: НЕ собиралось и НЕ запускалось. В ScanInodePaths есть известные ошибки, см. раздел 2 заметки.

#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/fcntl.h>
#import <errno.h>
#import <dlfcn.h>

// ---- Фрагмент 1. inode -> путь (fsgetpath) ----

// fsgetpath(2) в iOS SDK не объявлён публично, берём через dlsym.
typedef char *(*fsgetpath_fn)(char *buf, uint32_t buflen, const fsid_t *fsid, uint64_t objid);

void ScanInodePaths(NSString *dir) {
    struct statfs sb;
    if (statfs(dir.fileSystemRepresentation, &sb) != 0) {
        Log([NSString stringWithFormat:@"statfs %@ failed: errno=%d (%s)", dir, errno, strerror(errno)]);
        return;
    }
    fsgetpath_fn fsgetpath = (fsgetpath_fn)dlsym(RTLD_DEFAULT, "fsgetpath");
    if (!fsgetpath) { Log(@"fsgetpath: symbol not found"); return; }

    Log([NSString stringWithFormat:@"fsid=%d fs=%s", sb.f_fsid.val[0], sb.f_mntfromname]);

    char buf[MAXPATHLEN];
    NSUInteger hits = 0;
    for (uint64_t ino = 1; ino <= 3000000 && hits < 40; ino++) {
        // ядро пишет путь в конец буфера и возвращает смещение — берём именно возвращённый указатель
        const char *p = fsgetpath(buf, sizeof buf, &sb.f_fsid, ino);
        if (!p) continue;
        NSString *path = [NSString stringWithUTF8String:p];
        if ([path containsString:@"Containers"] || [path containsString:@"mobile"]) {
            hits++;
            Log([NSString stringWithFormat:@"ino=%llu → %@", ino, path]);
        }
    }
    Log([NSString stringWithFormat:@"done, hits=%lu", (unsigned long)hits]);
}

// ---- Фрагмент 2. Матрица доступа stat / open(O_RDONLY) / opendir ----

static NSString *ErrnoStr(int r) { return r == 0 ? @"ok" : @(errno).description; }

void ProbePaths(NSArray<NSString *> *paths) {
    for (NSString *path in paths) {
        const char *c = path.fileSystemRepresentation;
        struct stat st;
        int r = stat(c, &st);
        NSString *statRes = ErrnoStr(r);
        BOOL isDir = (r == 0 && S_ISDIR(st.st_mode));

        int fd = open(c, O_RDONLY);
        NSString *openRes = ErrnoStr(fd >= 0 ? 0 : -1);
        if (fd >= 0) close(fd);

        NSString *dirRes = @"-";
        if (isDir) {
            DIR *d = opendir(c);
            dirRes = d ? @"ok" : @(errno).description;
            if (d) closedir(d);
        }
        Log([NSString stringWithFormat:@"%@ → stat=%@ open=%@ opendir=%@", path, statRes, openRes, dirRes]);
    }
}
