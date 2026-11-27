//
//  pathleak.m
//  worse_query
//
//  Created by Taj C on 9/2/26.
//

/*
     pathleak - The dumbest arbitrary path enumeration.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>

// This is just a rewrite of bad_query_list to return an NSString array and run faster
// The way this works is literally just brute-forcing inodes and doing fsgetpath until it gets a matching path, lol.
// Which is still, obviously, dramatically faster than brute-forcing UUIDs.

// It might be possible to derive a sane inode value automagically by just creating a file, doing stat() on it, getting *that* file's inode, then using that for the max_inode count.

NSArray<NSString *> *pathleak(NSString *path, uint64_t max_inode) {
    // Sanity checks
    if (path.length == 0 || max_inode < 1) return nil;
    NSString *dir = path;
    while (dir.length > 1 && [dir hasSuffix: @"/"]) { // Trim trailing slash (if present)
        dir = [dir substringToIndex: dir.length - 1];
    }
    
    // Set everything up
    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;
    
    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation: prefix maxLength: sizeof(prefix)]) return nil;
    size_t prefix_length = strlen(prefix);
    if (prefix_length == 1 && prefix[0] == '/') prefix_length = 0;
    
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];
    
    // Brute-force inodes to their corresponding paths
    // I'd like to make this multithreaded at some point, but I don't think it'll help.
    for (uint64_t inode = 1; inode <= max_inode; inode++) {
        ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (n <= 0) continue;
        
        if (strncmp(buffer, prefix, prefix_length) != 0) continue;
        if (buffer[prefix_length] != '/') continue;
        if (strchr(buffer + prefix_length + 1, '/')) continue;
        
        NSString *string = [files stringWithFileSystemRepresentation: buffer length: strlen(buffer)];
        if (string) [result addObject: string];
    }
    return result;
}
