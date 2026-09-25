#ifndef VPHONE_ROOT_HIDE_LOADER_LINKS_H
#define VPHONE_ROOT_HIDE_LOADER_LINKS_H

// Ensure @loader_path/.jbroot can resolve before dyld starts the child.
// Returns zero on success or when no change is needed, otherwise an errno.
int vpEnsureRootHideLoaderLink(const char *executable, const char *root);

#endif
