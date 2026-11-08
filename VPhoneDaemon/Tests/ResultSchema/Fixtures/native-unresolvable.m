// Native forms no rule covers; the extractor must exit 2 on each. Parsed only.

NSDictionary *objectsForKeys(NSArray *values, NSArray *keys) {
    return [NSDictionary dictionaryWithObjects:values forKeys:keys];
}
