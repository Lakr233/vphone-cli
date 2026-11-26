#import <Foundation/Foundation.h>
#import <stdlib.h>

// Symbols already linked through IcliKit / IcliPrivate; both return a malloc'd
// JSON string, or NULL.
extern char *icli_ax_elements_json(int pid, int max_elements);
extern char *icli_ax_element_at_json(int pid, double x, double y);

static NSString *takeJSON(char *json) {
 if(!json) return nil;
 NSString *text=[NSString stringWithUTF8String:json];
 free(json);
 return text;
}

NSString *vp_icli_ax_elements(int pid, int maxElements) {
 return takeJSON(icli_ax_elements_json(pid,maxElements));
}

NSString *vp_icli_ax_element_at(int pid, double x, double y) {
 return takeJSON(icli_ax_element_at_json(pid,x,y));
}
