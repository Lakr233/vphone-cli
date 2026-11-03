; iOS 26.6.2 (23G90), 2026-11-02: extracted from captured pipeline 2's
; vertex metallib after argument metadata completion.
; ModuleID = '/tmp/vphone-native-fixes/point-coordinate-metallibs/2-vertex.metallib'
source_filename = "Vertex_State_Program"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

; Function Attrs: nounwind
define { <4 x float>, <4 x float>, <4 x float>, float } @"#main"(<4 x float> %0, <4 x float> %1, <4 x float> %2, <4 x float> addrspace(2)* %3) #0 {
allocaBlock:
  %4 = alloca <4 x float>, align 16
  store <4 x float> undef, <4 x float>* %4, align 16
  %5 = alloca <4 x float>, align 16
  store <4 x float> undef, <4 x float>* %5, align 16
  %6 = alloca <4 x float>, align 16
  store <4 x float> undef, <4 x float>* %6, align 16
  %7 = alloca <4 x float>, align 16
  store <4 x float> undef, <4 x float>* %7, align 16
  br label %entry

entry:                                            ; preds = %allocaBlock
  store <4 x float> %0, <4 x float>* %4, align 16
  store <4 x float> %1, <4 x float>* %5, align 16
  %8 = getelementptr <4 x float>, <4 x float> addrspace(2)* %3, i32 0
  %9 = load <4 x float>, <4 x float> addrspace(2)* %8, align 16
  %10 = load <4 x float>, <4 x float>* %6, align 16
  %11 = extractelement <4 x float> %9, i32 0
  %12 = insertelement <4 x float> %10, float %11, i32 0
  store <4 x float> %12, <4 x float>* %6, align 16
  store <4 x float> %2, <4 x float>* %7, align 16
  %13 = load <4 x float>, <4 x float>* %5, align 16
  %14 = call nsz arcp <4 x float> @air.clamp.v4f32(<4 x float> %13, <4 x float> zeroinitializer, <4 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>)
  %returnValue = insertvalue { <4 x float>, <4 x float>, <4 x float>, float } undef, <4 x float> %14, 0
  %15 = load <4 x float>, <4 x float>* %7, align 16
  %returnValue1 = insertvalue { <4 x float>, <4 x float>, <4 x float>, float } %returnValue, <4 x float> %15, 1
  %16 = load <4 x float>, <4 x float>* %4, align 16
  %returnValue2 = insertvalue { <4 x float>, <4 x float>, <4 x float>, float } %returnValue1, <4 x float> %16, 2
  %17 = load <4 x float>, <4 x float>* %6, align 16
  %18 = extractelement <4 x float> %17, i32 0
  %returnValue3 = insertvalue { <4 x float>, <4 x float>, <4 x float>, float } %returnValue2, float %18, 3
  ret { <4 x float>, <4 x float>, <4 x float>, float } %returnValue3
}

; Function Attrs: nounwind readonly
declare <4 x float> @air.clamp.v4f32(<4 x float>, <4 x float>, <4 x float>) #1

define { <4 x float>, <4 x float>, <4 x float>, float } @air.vertexFetchFunction(<4 x float> addrspace(2)* %0, <{ [32 x i8] }> addrspace(2)* %1, <{ [8 x i8] }> addrspace(1)* %2, i32 zeroext %3) {
Body:
  %4 = zext i32 %3 to i64
  %5 = getelementptr <{ [8 x i8] }>, <{ [8 x i8] }> addrspace(1)* %2, i64 %4, i32 0, i64 0
  %6 = bitcast i8 addrspace(1)* %5 to <2 x float> addrspace(1)*
  %7 = load <2 x float>, <2 x float> addrspace(1)* %6, align 4
  %8 = shufflevector <2 x float> %7, <2 x float> <float 1.000000e+00, float 0.000000e+00>, <4 x i32> <i32 0, i32 1, i32 3, i32 2>
  %9 = getelementptr <{ [32 x i8] }>, <{ [32 x i8] }> addrspace(2)* %1, i64 0, i32 0, i64 0
  %10 = bitcast i8 addrspace(2)* %9 to <4 x float> addrspace(2)*
  %11 = load <4 x float>, <4 x float> addrspace(2)* %10, align 4
  %12 = getelementptr <{ [32 x i8] }>, <{ [32 x i8] }> addrspace(2)* %1, i64 0, i32 0, i64 16
  %13 = bitcast i8 addrspace(2)* %12 to <4 x float> addrspace(2)*
  %14 = load <4 x float>, <4 x float> addrspace(2)* %13, align 4
  %15 = call { <4 x float>, <4 x float>, <4 x float>, float } @"#main"(<4 x float> %8, <4 x float> %11, <4 x float> %14, <4 x float> addrspace(2)* %0)
  ret { <4 x float>, <4 x float>, <4 x float>, float } %15
}

attributes #0 = { nounwind }
attributes #1 = { nounwind readonly }

!air.compile_options = !{!0, !1, !2, !3}
!air.language_version = !{!4}
!air.vertex = !{!5}
!air.version = !{!16}

!0 = !{!"air.compile.fast_math_disable"}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{!"OpenGL ES Program", i32 1, i32 0, i32 0}
!5 = !{{ <4 x float>, <4 x float>, <4 x float>, float } (<4 x float> addrspace(2)*, <{ [32 x i8] }> addrspace(2)*, <{ [8 x i8] }> addrspace(1)*, i32)* @air.vertexFetchFunction, !6, !11}
!6 = !{!7, !8, !9, !10}
!7 = !{!"air.vertex_output", !"user(front_color)", !"air.perspective", !"air.center", !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_out0"}
!8 = !{!"air.vertex_output", !"user(tex_coord0)", !"air.perspective", !"air.center", !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_out1"}
!9 = !{!"air.position", !"air.perspective", !"air.center", !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_out2"}
!10 = !{!"air.point_size", !"air.perspective", !"air.center", !"air.arg_type_name", !"float", !"air.arg_name", !"_gles_out3"}
!11 = !{!12, !13, !14, !15}
!12 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 12, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"_gles_arg0"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 14, i32 1, !"air.read", !"air.arg_type_name", !"void", !"air.arg_name", !".hidden", !"air.address_space", i32 2, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 1}
!14 = !{i32 2, !"air.buffer", !"air.location_index", i32 15, i32 1, !"air.read", !"air.arg_type_name", !"void", !"air.arg_name", !".hidden", !"air.address_space", i32 1, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 1}
!15 = !{i32 3, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"_gles_arg3"}
!16 = !{i32 2, i32 7, i32 0}
