-- Does the asin32 function work?
-- ==
-- input { 0f32 } output { 0f32 }
-- input { -0.84147096f32 } output { -1f32 }
-- input { -8.742278e-8f32 } output { -8.742278e-8f32 }
-- input { 8.742278e-8f32 } output { 8.742278e-8f32 }

include futlib.numeric

fun main(x: f32): f32 = F32.asin(x)
