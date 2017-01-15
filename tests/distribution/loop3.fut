-- Simplified variant of loop2.fut with lower-rank arrays.
--
-- ==
--
-- structure distributed { Map/Loop 0 }

fun main(m: int, a: [n][k]int): [n][k]int =
  map (\(a_r: [k]int): [k]int  ->
        let acc = a_r in
        loop(acc) = for i < m do
          map (+) acc (a_r) in
        acc
     ) a
