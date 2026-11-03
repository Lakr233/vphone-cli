; iOS 26.6.2 (23G90), 2026-11-02: extracted from captured pipeline 6's
; fragment metallib with complete argument metadata and no point-coordinate flip.
; ModuleID = '/tmp/vphone-native-fixes/point-coordinate-metallibs/6-fragment.metallib'
source_filename = "glsl shader"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

; Function Attrs: nounwind
define { <4 x float> } @"#main"(<2 x half> %0, <4 x float> addrspace(2)* %1) #0 {
allocaBlock:
  %2 = alloca <2 x half>, align 4
  %3 = alloca <2 x half>, align 4
  %4 = alloca <4 x half>, align 8
  %5 = alloca <4 x float>, align 16
  %6 = alloca <4 x float>, align 16
  br label %globalBlock

globalBlock:                                      ; preds = %allocaBlock
  br label %block

block:                                            ; preds = %globalBlock
  store <2 x half> %0, <2 x half>* %2, align 4
  %7 = load <2 x half>, <2 x half>* %2, align 4
  store <2 x half> %7, <2 x half>* %3, align 4
  %8 = load <2 x half>, <2 x half>* %3, align 4
  %9 = shufflevector <2 x half> %8, <2 x half> <half 0xH3C00, half 0xH3C00>, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  store <4 x half> %9, <4 x half>* %4, align 8
  %10 = load <4 x half>, <4 x half>* %4, align 8
  %11 = fpext <4 x half> %10 to <4 x float>
  store <4 x float> %11, <4 x float>* %5, align 16
  %12 = load <4 x float>, <4 x float>* %5, align 16
  store <4 x float> %12, <4 x float>* %6, align 16
  %13 = load <4 x float>, <4 x float>* %6, align 16
  %14 = insertvalue { <4 x float> } undef, <4 x float> %13, 0
  ret { <4 x float> } %14
}

attributes #0 = { nounwind }

!air.language_version = !{!0}
!air.compile_options = !{!1, !2, !3}
!air.fragment = !{!4}
!air.version = !{!10}

!0 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{{ <4 x float> } (<2 x half>, <4 x float> addrspace(2)*)* @"#main", !5, !7}
!5 = !{!6}
!6 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!7 = !{!8, !9}
!8 = !{i32 0, !"air.point_coord", !"air.arg_type_name", !"half2", !"air.arg_name", !"_gles_arg0"}
!9 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 12, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_arg1"}
!10 = !{i32 2, i32 7, i32 0}
