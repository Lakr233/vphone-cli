; ModuleID = 'glsl shader'
source_filename = "glsl shader"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

%struct._texture_2d_t = type opaque
%struct._sampler_t = type opaque

; Function Attrs: nounwind
define { <4 x half> } @"#main"(<2 x half> %0, half %1, <4 x float> addrspace(2)* %2, %struct._texture_2d_t addrspace(1)* %3, %struct._sampler_t addrspace(2)* %4) #0 {
allocaBlock:
  %5 = alloca <2 x half>, align 4
  %6 = alloca half, align 2
  %7 = alloca half, align 2
  %8 = alloca <2 x half>, align 4
  %9 = alloca <4 x half>, align 8
  %10 = alloca <4 x half>, align 8
  %11 = alloca <4 x half>, align 8
  br label %globalBlock

globalBlock:                                      ; preds = %allocaBlock
  %12 = getelementptr <4 x float>, <4 x float> addrspace(2)* %2, i32 5
  br label %block

block:                                            ; preds = %globalBlock
  store <2 x half> %0, <2 x half>* %5, align 4
  store half %1, half* %6, align 2
  %13 = load half, half* %6, align 2
  %14 = load half, half* %7, align 2
  store half %13, half* %7, align 2
  %15 = load <2 x half>, <2 x half>* %5, align 4
  store <2 x half> %15, <2 x half>* %8, align 4
  %16 = load <2 x half>, <2 x half>* %8, align 4
  %17 = shufflevector <2 x half> %16, <2 x half> %16, <4 x i32> <i32 0, i32 1, i32 1, i32 1>
  %18 = shufflevector <4 x half> %17, <4 x half> undef, <2 x i32> <i32 0, i32 1>
  %19 = fpext <2 x half> %18 to <2 x float>
  %20 = call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(%struct._texture_2d_t addrspace(1)* %3, %struct._sampler_t addrspace(2)* %4, <2 x float> %19, i1 false, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0)
  %21 = extractvalue { <4 x half>, i8 } %20, 0
  store <4 x half> %21, <4 x half>* %9, align 8
  %22 = load <4 x half>, <4 x half>* %9, align 8
  %23 = load <4 x float>, <4 x float> addrspace(2)* %12, align 16
  %24 = fptrunc <4 x float> %23 to <4 x half>
  %25 = fmul reassoc nsz arcp contract afn <4 x half> %22, %24
  %26 = load half, half* %7, align 2
  %27 = insertelement <4 x half> undef, half %26, i32 0
  %28 = shufflevector <4 x half> %27, <4 x half> %27, <4 x i32> zeroinitializer
  %29 = fmul reassoc nsz arcp contract afn <4 x half> %25, %28
  store <4 x half> %29, <4 x half>* %10, align 8
  %30 = load <4 x half>, <4 x half>* %10, align 8
  store <4 x half> %30, <4 x half>* %11, align 8
  %31 = load <4 x half>, <4 x half>* %11, align 8
  %32 = insertvalue { <4 x half> } undef, <4 x half> %31, 0
  ret { <4 x half> } %32
}

; Function Attrs: nounwind readonly
declare { <4 x half>, i8 } @air.sample_texture_2d.v4f16(%struct._texture_2d_t addrspace(1)*, %struct._sampler_t addrspace(2)*, <2 x float>, i1, <2 x i32>, i1, float, float, i32) #1

attributes #0 = { nounwind }
attributes #1 = { nounwind readonly }

!air.language_version = !{!0}
!air.compile_options = !{!1, !2, !3}
!air.fragment = !{!4}

!0 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{{ <4 x half> } (<2 x half>, half, <4 x float> addrspace(2)*, %struct._texture_2d_t addrspace(1)*, %struct._sampler_t addrspace(2)*)* @"#main", !5, !7}
!5 = !{!6}
!6 = !{!"air.render_target", i32 0, i32 0}
!7 = !{!8, !9, !10, !11, !12}
!8 = !{i32 0, !"air.fragment_input", !"user(slot9)", !"air.perspective", !"air.center", !"air.arg_type_name", !"half2"}
!9 = !{i32 1, !"air.fragment_input", !"user(slot8)", !"air.perspective", !"air.center", !"air.arg_type_name", !"half"}
!10 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 12, i32 1, !"air.read"}
!11 = !{i32 3, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>"}
!12 = !{i32 4, !"air.sampler", !"air.location_index", i32 0, i32 1}
