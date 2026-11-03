; iOS 26.6.2 (23G90), 2026-11-02: captured before argument metadata
; completion as 409-2-before.ll; vertex partner for the ES3 point-coordinate test.
; ModuleID = 'glsl shader'
source_filename = "glsl shader"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

; Function Attrs: nounwind
define { float, <4 x float> } @"#main"(<2 x float> %0, <4 x float> addrspace(2)* %1) #0 {
allocaBlock:
  %2 = alloca <2 x float>, align 8
  %3 = alloca <2 x float>, align 8
  %4 = alloca <4 x float>, align 16
  %5 = alloca <4 x float>, align 16
  %6 = alloca float, align 4
  %7 = alloca <4 x float>, align 16
  %8 = alloca float, align 4
  br label %globalBlock

globalBlock:                                      ; preds = %allocaBlock
  %9 = getelementptr <4 x float>, <4 x float> addrspace(2)* %1, i32 0
  br label %block

block:                                            ; preds = %globalBlock
  store <2 x float> %0, <2 x float>* %2, align 8
  %10 = load <2 x float>, <2 x float>* %2, align 8
  store <2 x float> %10, <2 x float>* %3, align 8
  %11 = load <2 x float>, <2 x float>* %3, align 8
  %12 = shufflevector <2 x float> %11, <2 x float> <float 0.000000e+00, float 1.000000e+00>, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  store <4 x float> %12, <4 x float>* %4, align 16
  %13 = load <4 x float>, <4 x float>* %4, align 16
  store <4 x float> %13, <4 x float>* %5, align 16
  %14 = bitcast <4 x float> addrspace(2)* %9 to float addrspace(2)*
  %15 = load float, float addrspace(2)* %14, align 4
  store float %15, float* %6, align 4
  %16 = load <4 x float>, <4 x float>* %5, align 16
  store <4 x float> %16, <4 x float>* %7, align 16
  %17 = load float, float* %6, align 4
  %18 = load float, float* %8, align 4
  store float %17, float* %8, align 4
  %19 = load <4 x float>, <4 x float>* %7, align 16
  %20 = insertvalue { float, <4 x float> } undef, <4 x float> %19, 1
  %21 = load float, float* %8, align 4
  %22 = insertvalue { float, <4 x float> } %20, float %21, 0
  ret { float, <4 x float> } %22
}

define { float, <4 x float> } @air.vertexFetchFunction(<4 x float> addrspace(2)* %0, <{ [8 x i8] }> addrspace(1)* %1, i32 zeroext %2) {
Body:
  %3 = zext i32 %2 to i64
  %4 = getelementptr <{ [8 x i8] }>, <{ [8 x i8] }> addrspace(1)* %1, i64 %3, i32 0, i64 0
  %5 = bitcast i8 addrspace(1)* %4 to <2 x float> addrspace(1)*
  %6 = load <2 x float>, <2 x float> addrspace(1)* %5, align 4
  %7 = call { float, <4 x float> } @"#main"(<2 x float> %6, <4 x float> addrspace(2)* %0)
  ret { float, <4 x float> } %7
}

attributes #0 = { nounwind }

!air.language_version = !{!0}
!air.compile_options = !{!1, !2, !3}
!air.vertex = !{!4}

!0 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{{ float, <4 x float> } (<4 x float> addrspace(2)*, <{ [8 x i8] }> addrspace(1)*, i32)* @air.vertexFetchFunction, !5, !8}
!5 = !{!6, !7}
!6 = !{!"air.point_size"}
!7 = !{!"air.position"}
!8 = !{!9, !10, !11}
!9 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 12, i32 1, !"air.read"}
!10 = !{i32 1, !"air.buffer", !"air.location_index", i32 15, i32 1, !"air.read", !"air.arg_type_name", !"void", !"air.arg_name", !".hidden"}
!11 = !{i32 2, !"air.vertex_id", !"air.arg_type_name", !"uint"}
