(** @synduce --no-lifting *)

type 'a tree =
  | Leaf of 'a
  | Node of 'a * 'a tree * 'a tree

let reference x t =
  let rec f t = g x t
  and g y = function
    | Leaf a -> y > a, a
    | Node (a, l, r) ->
      let lh, la = g a l in
      let rh, ra = g la r in
      lh && rh && y > ra, a
  in
  f t
;;

let target x t =
  let rec h0 t = h x t
  and h y = function
    | Leaf a -> [%synt f0] a y
    | Node (a, l, r) -> [%synt join] a y (h a l) (h a r)
  in
  h0 t
;;

assert (target = reference)
