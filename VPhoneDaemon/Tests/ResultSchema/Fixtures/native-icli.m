// Stands in for a file of the icli checkout. Parsed only, never compiled.
char *icli_remote_json(void) {
    return icli_json_or_empty(@{@"total": @(5L), @"remote": @"x"});
}
