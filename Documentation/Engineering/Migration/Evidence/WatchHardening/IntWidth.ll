; ModuleID = '/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public/Documentation/Engineering/Migration/Evidence/WatchHardening/IntWidth.ll'
source_filename = "/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public/Documentation/Engineering/Migration/Evidence/WatchHardening/IntWidth.ll"
target datalayout = "e-m:o-p:32:32-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64_32-apple-watchos26.0.0"

@"\01l_entry_point" = private constant { i32, i32 } { i32 sub (i32 ptrtoint (ptr @main to i32), i32 ptrtoint (ptr @"\01l_entry_point" to i32)), i32 0 }, section "__TEXT, __swift5_entry, regular, no_dead_strip", align 4
@__swift_reflection_version = linkonce_odr hidden constant i16 3
@llvm.used = appending global [4 x ptr] [ptr @"\01l_entry_point", ptr @"$s8IntWidth015swiftIntegerBitB0SiyF", ptr @__swift_reflection_version, ptr @main], section "llvm.metadata"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define noundef i32 @main(i32 %0, ptr readnone captures(none) %1) #0 {
entry:
  ret i32 0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define swiftcc noundef i32 @"$s8IntWidth015swiftIntegerBitB0SiyF"() #0 {
entry:
  ret i32 32
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) "frame-pointer"="non-leaf" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="apple-s6" "target-features"="+aes,+ccidx,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+ras,+rcpc,+rdm,+sha2,+sha3,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8a" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8, !9, !10, !11, !12}
!swift.module.flags = !{!13}
!llvm.linker.options = !{!14, !15, !16, !17}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 27, i32 0]}
!1 = !{i32 1, !"Objective-C Version", i32 2}
!2 = !{i32 1, !"Objective-C Image Info Version", i32 0}
!3 = !{i32 1, !"Objective-C Image Info Section", !"__DATA,__objc_imageinfo,regular,no_dead_strip"}
!4 = !{i32 4, !"Objective-C Garbage Collection", i32 100927232}
!5 = !{i32 1, !"Objective-C Class Properties", i32 64}
!6 = !{i32 1, !"Objective-C Enforce ClassRO Pointer Signing", i8 0}
!7 = !{i32 1, !"wchar_size", i32 4}
!8 = !{i32 8, !"PIC Level", i32 2}
!9 = !{i32 7, !"uwtable", i32 1}
!10 = !{i32 7, !"frame-pointer", i32 1}
!11 = !{i32 1, !"Swift Version", i32 7}
!12 = !{i32 1, !"Swift DirectReg Version", i32 1}
!13 = !{!"standard-library", i1 false}
!14 = !{!"-lswift_Concurrency"}
!15 = !{!"-lswiftCore"}
!16 = !{!"-lswift_StringProcessing"}
!17 = !{!"-lobjc"}
