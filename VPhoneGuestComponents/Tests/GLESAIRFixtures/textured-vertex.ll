; ModuleID = 'glsl shader'
source_filename = "glsl shader"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios"

; Function Attrs: nounwind
define { <2 x half>, <4 x float>, half } @"#main"(<2 x float> %0, <2 x float> %1, <4 x float> addrspace(2)* %2) #0 {
allocaBlock:
  %3 = alloca <2 x float>, align 8
  %4 = alloca <2 x float>, align 8
  %5 = alloca <2 x float>, align 8
  %6 = alloca <2 x float>, align 8
  %7 = alloca <4 x float>, align 16
  %8 = alloca <2 x float>, align 8
  %9 = alloca <4 x float>, align 16
  %10 = alloca <4 x float>, align 16
  %11 = alloca <4 x float>, align 16
  %12 = alloca <2 x float>, align 8
  %13 = alloca float, align 4
  %14 = alloca <4 x float>, align 16
  %15 = alloca half, align 2
  %16 = alloca <2 x half>, align 4
  br label %globalBlock

globalBlock:                                      ; preds = %allocaBlock
  %17 = getelementptr <4 x float>, <4 x float> addrspace(2)* %2, i32 4
  %18 = getelementptr <4 x float>, <4 x float> addrspace(2)* %2, i32 3
  %19 = getelementptr <4 x float>, <4 x float> addrspace(2)* %2, i32 2
  %20 = getelementptr <4 x float>, <4 x float> addrspace(2)* %2, i32 1
  %21 = getelementptr <4 x float>, <4 x float> addrspace(2)* %2, i32 0
  br label %block

block:                                            ; preds = %globalBlock
  store <2 x float> %0, <2 x float>* %3, align 8
  store <2 x float> %1, <2 x float>* %4, align 8
  %22 = load <2 x float>, <2 x float>* %3, align 8
  store <2 x float> %22, <2 x float>* %5, align 8
  %23 = load <2 x float>, <2 x float>* %4, align 8
  store <2 x float> %23, <2 x float>* %6, align 8
  %24 = load <2 x float>, <2 x float>* %6, align 8
  %25 = bitcast <4 x float> addrspace(2)* %17 to float addrspace(2)*
  %26 = load float, float addrspace(2)* %25, align 4
  %27 = insertelement <2 x float> undef, float %26, i32 0
  %28 = shufflevector <2 x float> %27, <2 x float> %27, <2 x i32> zeroinitializer
  %29 = fmul reassoc nsz arcp contract afn <2 x float> %24, %28
  store <2 x float> %29, <2 x float>* %8, align 8
  %30 = load <2 x float>, <2 x float>* %8, align 8
  %31 = shufflevector <2 x float> %30, <2 x float> <float 0.000000e+00, float 1.000000e+00>, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  store <4 x float> %31, <4 x float>* %9, align 16
  %32 = load <4 x float>, <4 x float>* %9, align 16
  store <4 x float> %32, <4 x float>* %7, align 16
  %33 = load <4 x float>, <4 x float> addrspace(2)* %18, align 16
  %34 = load <4 x float>, <4 x float>* %7, align 16
  %35 = shufflevector <4 x float> %34, <4 x float> %34, <4 x i32> <i32 3, i32 3, i32 3, i32 3>
  %36 = load <4 x float>, <4 x float> addrspace(2)* %19, align 16
  %37 = load <4 x float>, <4 x float>* %7, align 16
  %38 = shufflevector <4 x float> %37, <4 x float> %37, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %39 = load <4 x float>, <4 x float> addrspace(2)* %20, align 16
  %40 = load <4 x float>, <4 x float>* %7, align 16
  %41 = shufflevector <4 x float> %40, <4 x float> %40, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %42 = load <4 x float>, <4 x float> addrspace(2)* %21, align 16
  %43 = load <4 x float>, <4 x float>* %7, align 16
  %44 = shufflevector <4 x float> %43, <4 x float> %43, <4 x i32> zeroinitializer
  %45 = fmul reassoc nsz arcp contract afn <4 x float> %42, %44
  %46 = call reassoc nsz arcp contract afn <4 x float> @air.mad.v4f32(<4 x float> %39, <4 x float> %41, <4 x float> %45)
  %47 = call reassoc nsz arcp contract afn <4 x float> @air.mad.v4f32(<4 x float> %36, <4 x float> %38, <4 x float> %46)
  %48 = call reassoc nsz arcp contract afn <4 x float> @air.mad.v4f32(<4 x float> %33, <4 x float> %35, <4 x float> %47)
  store <4 x float> %48, <4 x float>* %10, align 16
  %49 = load <4 x float>, <4 x float>* %10, align 16
  store <4 x float> %49, <4 x float>* %11, align 16
  %50 = load <2 x float>, <2 x float>* %5, align 8
  store <2 x float> %50, <2 x float>* %12, align 8
  store float 1.000000e+00, float* %13, align 4
  %51 = load <4 x float>, <4 x float>* %11, align 16
  store <4 x float> %51, <4 x float>* %14, align 16
  %52 = load float, float* %13, align 4
  %53 = fptrunc float %52 to half
  %54 = load half, half* %15, align 2
  store half %53, half* %15, align 2
  %55 = load <2 x float>, <2 x float>* %12, align 8
  %56 = extractelement <2 x float> %55, i32 0
  %57 = fptrunc float %56 to half
  %58 = load <2 x half>, <2 x half>* %16, align 4
  %59 = insertelement <2 x half> %58, half %57, i32 0
  store <2 x half> %59, <2 x half>* %16, align 4
  %60 = load <2 x float>, <2 x float>* %12, align 8
  %61 = extractelement <2 x float> %60, i32 1
  %62 = fptrunc float %61 to half
  %63 = load <2 x half>, <2 x half>* %16, align 4
  %64 = insertelement <2 x half> %63, half %62, i32 1
  store <2 x half> %64, <2 x half>* %16, align 4
  %65 = load half, half* %15, align 2
  %66 = insertvalue { <2 x half>, <4 x float>, half } undef, half %65, 2
  %67 = load <4 x float>, <4 x float>* %14, align 16
  %68 = insertvalue { <2 x half>, <4 x float>, half } %66, <4 x float> %67, 1
  %69 = load <2 x half>, <2 x half>* %16, align 4
  %70 = insertvalue { <2 x half>, <4 x float>, half } %68, <2 x half> %69, 0
  ret { <2 x half>, <4 x float>, half } %70
}

; Function Attrs: nounwind readnone
declare <4 x float> @air.mad.v4f32(<4 x float>, <4 x float>, <4 x float>) #1

define { <2 x half>, <4 x float>, half } @air.vertexFetchFunction(<4 x float> addrspace(2)* %0, <{ [16 x i8] }> addrspace(1)* %1, i32 zeroext %2) {
Body:
  %3 = zext i32 %2 to i64
  %4 = getelementptr <{ [16 x i8] }>, <{ [16 x i8] }> addrspace(1)* %1, i64 %3, i32 0, i64 0
  %5 = bitcast i8 addrspace(1)* %4 to <2 x float> addrspace(1)*
  %6 = load <2 x float>, <2 x float> addrspace(1)* %5, align 4
  %7 = zext i32 %2 to i64
  %8 = getelementptr <{ [16 x i8] }>, <{ [16 x i8] }> addrspace(1)* %1, i64 %7, i32 0, i64 8
  %9 = bitcast i8 addrspace(1)* %8 to <2 x float> addrspace(1)*
  %10 = load <2 x float>, <2 x float> addrspace(1)* %9, align 4
  %11 = call { <2 x half>, <4 x float>, half } @"#main"(<2 x float> %6, <2 x float> %10, <4 x float> addrspace(2)* %0)
  ret { <2 x half>, <4 x float>, half } %11
}

attributes #0 = { nounwind }
attributes #1 = { nounwind readnone }

!air.language_version = !{!0}
!air.compile_options = !{!1, !2, !3}
!air.vertex = !{!4}

!0 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!1 = !{!"air.compile.fast_math_enable"}
!2 = !{!"air.compile.denorms_disable"}
!3 = !{!"air.compile.native_double_disable"}
!4 = !{{ <2 x half>, <4 x float>, half } (<4 x float> addrspace(2)*, <{ [16 x i8] }> addrspace(1)*, i32)* @air.vertexFetchFunction, !5, !9}
!5 = !{!6, !7, !8}
!6 = !{!"air.vertex_output", !"user(slot9)"}
!7 = !{!"air.position"}
!8 = !{!"air.vertex_output", !"user(slot8)"}
!9 = !{!10, !11, !12}
!10 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 12, i32 1, !"air.read"}
!11 = !{i32 1, !"air.buffer", !"air.location_index", i32 15, i32 1, !"air.read", !"air.arg_type_name", !"void", !"air.arg_name", !".hidden"}
!12 = !{i32 2, !"air.vertex_id", !"air.arg_type_name", !"uint"}
