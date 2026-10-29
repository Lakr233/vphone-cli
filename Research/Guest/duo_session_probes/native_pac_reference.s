.text
.globl _reference_sign
.globl _reference_pac_site
.p2align 2
_reference_sign:
 mov x9, x30
 mov x30, x0
_reference_pac_site:
 pacibsppc
 mov x0, x30
 mov x30, x9
 ret
