; iOS 26.6.2 (23G90), 2026-11-02: extracted from captured pipeline 2's
; fragment metallib with complete argument metadata and no point-coordinate flip.
; ModuleID = '/tmp/vphone-native-fixes/point-coordinate-metallibs/2-fragment.metallib'
source_filename = "Fragment_State_Program"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

%struct._texture_2d_t.0 = type opaque
%struct._sampler_t.1 = type opaque

; Function Attrs: nounwind
define { <4 x float> } @"#main"(<4 x float> %0, <4 x float> %1, <2 x float> %2, <4 x float> addrspace(2)* %3, %struct._texture_2d_t.0 addrspace(1)* %4, %struct._sampler_t.1 addrspace(2)* %5) #0 {
allocaBlock:
  %6 = alloca <4 x float>, align 16
  store <4 x float> undef, <4 x float>* %6, align 16
  br label %entry

entry:                                            ; preds = %allocaBlock
  %7 = shufflevector <2 x float> %2, <2 x float> %2, <4 x i32> <i32 0, i32 1, i32 0, i32 0>
  %8 = getelementptr <4 x float>, <4 x float> addrspace(2)* %3, i32 0
  %9 = load <4 x float>, <4 x float> addrspace(2)* %8, align 16
  %10 = extractelement <4 x float> %7, i32 0
  %11 = insertelement <2 x float> undef, float %10, i32 0
  %12 = extractelement <4 x float> %7, i32 1
  %13 = insertelement <2 x float> %11, float %12, i32 1
  %14 = extractelement <4 x float> %9, i32 0
  %15 = call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t.0 addrspace(1)* %4, %struct._sampler_t.1 addrspace(2)* %5, <2 x float> %13, i1 false, <2 x i32> zeroinitializer, i1 false, float %14, float 0.000000e+00, i32 0)
  %texVal = extractvalue { <4 x float>, i8 } %15, 0
  %16 = call reassoc nsz arcp contract afn <4 x float> @air.clamp.v4f32(<4 x float> %texVal, <4 x float> zeroinitializer, <4 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>)
  store <4 x float> %16, <4 x float>* %6, align 16
  %17 = load <4 x float>, <4 x float>* %6, align 16
  %returnValue = insertvalue { <4 x float> } undef, <4 x float> %17, 0
  ret { <4 x float> } %returnValue
}

; Function Attrs: nounwind readonly
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t.0 addrspace(1)*, %struct._sampler_t.1 addrspace(2)*, <2 x float>, i1, <2 x i32>, i1, float, float, i32) #1

; Function Attrs: nounwind readonly
declare <4 x float> @air.clamp.v4f32(<4 x float>, <4 x float>, <4 x float>) #1

attributes #0 = { nounwind }
attributes #1 = { nounwind readonly }

!air.language_version = !{!0}
!air.compile_options = !{!1, !2, !3}
!air.fragment = !{!4}
!air.version = !{!14}

!0 = !{!"OpenGL ES Program", i32 1, i32 0, i32 0}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{{ <4 x float> } (<4 x float>, <4 x float>, <2 x float>, <4 x float> addrspace(2)*, %struct._texture_2d_t.0 addrspace(1)*, %struct._sampler_t.1 addrspace(2)*)* @"#main", !5, !7}
!5 = !{!6}
!6 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!7 = !{!8, !9, !10, !11, !12, !13}
!8 = !{i32 0, !"air.fragment_input", !"user(front_color)", !"air.perspective", !"air.center", !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_arg0"}
!9 = !{i32 1, !"air.fragment_input", !"user(tex_coord0)", !"air.perspective", !"air.center", !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_arg1"}
!10 = !{i32 2, !"air.point_coord", !"air.arg_type_name", !"float2", !"air.arg_name", !"_gles_arg2"}
!11 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 12, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_arg3"}
!12 = !{i32 4, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"_gles_arg4"}
!13 = !{i32 5, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"_gles_arg5"}
!14 = !{i32 2, i32 7, i32 0}
