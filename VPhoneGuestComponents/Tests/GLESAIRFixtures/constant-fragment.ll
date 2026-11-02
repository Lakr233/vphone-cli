; ModuleID = 'glsl shader'
source_filename = "glsl shader"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

; Function Attrs: nounwind
define { <4 x half> } @"#main"(<4 x float> addrspace(2)* %0) #0 {
allocaBlock:
  %1 = alloca <4 x half>, align 8
  %2 = alloca <4 x half>, align 8
  br label %globalBlock

globalBlock:                                      ; preds = %allocaBlock
  br label %block

block:                                            ; preds = %globalBlock
  store <4 x half> <half 0xH3C00, half 0xH0000, half 0xH3800, half 0xH3C00>, <4 x half>* %1, align 8
  %3 = load <4 x half>, <4 x half>* %1, align 8
  store <4 x half> %3, <4 x half>* %2, align 8
  %4 = load <4 x half>, <4 x half>* %2, align 8
  %5 = insertvalue { <4 x half> } undef, <4 x half> %4, 0
  ret { <4 x half> } %5
}

attributes #0 = { nounwind }

!air.language_version = !{!0}
!air.compile_options = !{!1, !2, !3}
!air.fragment = !{!4}

!0 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{{ <4 x half> } (<4 x float> addrspace(2)*)* @"#main", !5, !7}
!5 = !{!6}
!6 = !{!"air.render_target", i32 0, i32 0}
!7 = !{!8}
!8 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 0, !"air.location_index", i32 12, i32 1, !"air.read"}
