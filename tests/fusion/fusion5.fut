-- Once failed in fusion.  Derived from tail2futhark output.
-- ==
-- input { [1, 2, -4, 1] [[1, 2], [-4, 1]] }
-- output {
--          [[true, false, false, false, false, false, false, false, false, false, false,
--            false, false, false, false, false, false, false, false, false, false, false,
--            false, false, false, false, false, false, false, false],
--           [false, false, false, false, false, false, false, false, false, false, false,
--            false, false, false, false, false, false, false, false, false, false, false,
--            false, false, false, false, false, false, false, false],
--           [true, false, false, false, false, false, false, false, false, false, false,
--            false, false, false, false, false, false, false, false, false, false, false,
--            false, false, false, false, false, false, false, false]]
-- }
-- structure { Map 3 Map/Map 1 }
fun main(t_v1: []int, t_v3: [][]int): [][]bool =
  let n = 3
  let t_v6 = map (\(x: int): int  -> (x + 1)) (iota(n))
  let t_v12 = map (\(x: int): int  -> (x + 1)) (iota(30))
  let t_v18 = rearrange (1,0) (replicate 30 t_v6)
  let t_v19 = replicate n t_v12
  let t_v27 = map (\(x: []int,y: []int): []int  ->
                    map (^) x y) (
                  zip (t_v18) (
                      map (\(x: []int): []int  -> map (<<1) x) (t_v18)))
  let t_v33 = map (\(x: []int): []bool  ->
                    map (\(t_v32: int): bool  ->
                          ((0 != t_v32))) x) (
                    map (\(x: []int,y: []int): []int  ->
                          map (&) x y) (
                        zip (t_v27) (
                            map (\(x: []int): []int  ->
                                  map (\(t_v29: int): int  ->
                                        (1 >> t_v29)) x) (
                                  map (\(x: []int): []int  ->
                                        map (\(t_v28: int): int  ->
                                              (t_v28 - 1)) x) (
                                        t_v19))))) in
  t_v33
