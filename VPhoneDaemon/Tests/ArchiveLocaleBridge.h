#pragma once
#include <zlib.h>
#include <locale.h>
#include <langinfo.h>
#include <stdlib.h>

// Linked to the workspace's pinned IcliPrivate/Archive.m, without modification.
char *icli_extract_ipa_json(const char *source, const char *destination);
