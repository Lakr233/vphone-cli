#include "VPhoneIOS16LabPolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    struct stat valid = {0};
    valid.st_mode = S_IFREG | 0644;
    valid.st_uid = 0;
    valid.st_nlink = 1;
    valid.st_size = sizeof(VP_IOS16_KEYBAGLESS_MAGIC) - 1;
    valid.st_mtime = 100;
    assert(vp_ios16_lab_lease_valid(&valid, 100));
    assert(vp_ios16_lab_lease_valid(&valid, 103));
    assert(!vp_ios16_lab_lease_valid(&valid, 104));
    assert(!vp_ios16_lab_lease_valid(&valid, 99));
    struct stat bad = valid; bad.st_uid = 501;
    assert(!vp_ios16_lab_lease_valid(&bad, 101));
    bad = valid; bad.st_nlink = 2;
    assert(!vp_ios16_lab_lease_valid(&bad, 101));
    bad = valid; bad.st_mode = S_IFLNK | 0644;
    assert(!vp_ios16_lab_lease_valid(&bad, 101));
    bad = valid; bad.st_mode |= 0020;
    assert(!vp_ios16_lab_lease_valid(&bad, 101));
    bad = valid; bad.st_mode |= 0002;
    assert(!vp_ios16_lab_lease_valid(&bad, 101));
    bad = valid; bad.st_size--;
    assert(!vp_ios16_lab_lease_valid(&bad, 101));
    puts("iOS 16 lab lease policy: passed");
}
